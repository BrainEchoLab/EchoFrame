//
// Linux async file I/O backend for EchoFrame Storage.
// Mirrors the public API of WindowsFileIO so Handler.t.hpp changes are minimal.
//
// The sector size used for offset/length rounding (adjustToSectorSize()) and
// the buffer-address alignment O_DIRECT requires are queried at runtime via
// statx(STATX_DIOALIGN) in queryAlignment(); the constructor throws if the
// kernel/filesystem can't report a real value. The file header
// (writeToHeader()) is allocated against these queried values.
//

#ifndef CUBE_STORAGE_LINUXFILEIO_H
#define CUBE_STORAGE_LINUXFILEIO_H

#include <aio.h>
#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "../write_stats.h"

namespace Storage {

template <typename bufferType_t>
class LinuxFileIO {
   private:
    int mFd{-1};
    bool mFileOpened{false};

    off_t getFileSize() const;
    void reserveFileSpace(off_t offset, off_t length);
    void syncFileData() const;
    void finalizeAndClose() noexcept;

    int mMaxConcurrentWrites{0};
    int mWritesPerBuffer{0};

    /**
     * @brief Query the file's actual O_DIRECT offset/length alignment
     * (mSectorSize) and buffer-address alignment (mMemAlign) via
     * statx(STATX_DIOALIGN). Throws if either value can't be determined.
     */
    void queryAlignment();

    /**
     * @brief Header size that is a multiple of mSectorSize, so
     * writeToHeader() can satisfy O_DIRECT's write-length requirement.
     * Buffer-address alignment (mMemAlign) is handled independently by
     * posix_memalign.
     */
    uint64_t computeHeaderSize() const;

    struct AioWorker {
        struct aiocb cb {};
        bool inUse{false};
        // Carried with the write so its completion can identify itself.
        StorageClock::time_point queuedAt{};
        uint64_t digest{0};
        size_t digestBytes{0};
        uint64_t recordIndex{0};
    };
    std::vector<AioWorker> mWorkers;

    WriteStats mStats;                  // per-file
    std::deque<PendingWrite> mPending;  // held by EF_STORAGE_DELAY_WRITE_MS
    std::string mStreamLabel;           // names this stream in reports
    // Completions are only noticed when one is reaped. During the closing
    // drain that can be long after the write finished, by which time the
    // producer has legitimately reused the buffer, so the digest is stale.
    bool mFinalDrain{false};

    uint64_t mBufferSize{0};             // bytes per full buffer (no padding)
    std::vector<uint64_t> mBlockSize;    // bytes per block (split across writes)
    std::vector<uint64_t> mBlockOffset;  // element offset into buffer for each block

    // O_DIRECT alignment requirements. Set by queryAlignment(), called
    // early in the constructor (which throws if either can't be
    // determined) -- never read at their zero-initialized value.
    uint64_t mSectorSize{0};  // required offset/length alignment
    uint64_t mMemAlign{0};    // required buffer-address alignment

    /** header fields */
    uint64_t mVersion{1};
    uint64_t mHeaderSize{0};  // set by queryAlignment()/computeHeaderSize()
    uint64_t mPaddingBytes{0};  // padding added by adjustToSectorSize (O_DIRECT)
    uint64_t mDataTypeCode{0};

    int verbose{1};

   public:
    uint64_t mBuffersQueued{0};
    uint64_t mBuffersDequeued{0};

    LinuxFileIO() = default;

    LinuxFileIO(std::string &pFilePath, uint64_t pBufferSize,
                int pWritesPerBuffer, int pNConcBuffers,
                uint64_t pDataTypeCode);

    ~LinuxFileIO();

    LinuxFileIO(LinuxFileIO &&x) noexcept;
    LinuxFileIO &operator=(LinuxFileIO &&x) noexcept;

    /**
     * @return Whether a file at path already exists.
     */
    static bool fileExists(const std::string &path);

    /**
     * @return Unique file path (appends ".dat", or "_N.dat" if already exists).
     */
    static std::string renameFile(std::string &pFilePath);

    /**
     * @brief Extend the file by nBuffers * mBufferSize bytes (data region).
     */
    void extendFile(int nBuffers);

    /**
     * @brief Extend the file by mHeaderSize bytes (header region).
     */
    void extendFileHeader();

    /**
     * @brief Pad mBufferSize and grow mWritesPerBuffer until buffer size and
     * every write block are sector-size multiples (required for O_DIRECT).
     */
    void adjustToSectorSize(size_t pSectorSize);

    /**
     * @brief Configure per-block sizes and element offsets.
     */
    void configureBlocksAndOffsets();

    /**
     * @brief Wait for the oldest in-flight buffer write to complete.
     */
    void waitForBufferWriteComplete();

    /**
     * @brief Queue an async write of buffer; timeout is ignored on Linux.
     */
    void writeOverlappedBuffer(bufferType_t *buffer, int timeout);

    /**
     * @brief Issue the aio_write calls for one buffer at a fixed record index.
     * The index is passed in so a deferred write still lands at the offset it
     * was given when the caller handed the buffer over.
     */
    void issueWrite(bufferType_t *buffer, uint64_t recordIndex, uint64_t digest,
                    size_t digestBytes, StorageClock::time_point queuedAt);

    /**
     * @brief Account for one completed write: latency, and whether the source
     * changed in flight when EF_STORAGE_VERIFY is on.
     */
    void onWriteCompleted(AioWorker &w);

    /**
     * @brief Issue writes held by EF_STORAGE_DELAY_WRITE_MS.
     * @param all release everything, ignoring deadlines
     */
    bool flushPending(bool all);

    /// Per-file write instrumentation.
    const WriteStats &stats() const { return mStats; }

    /// Name used for this stream in the summary line.
    void setStreamLabel(const std::string &label) { mStreamLabel = label; }

    /**
     * @brief Print the write summary for this file.
     */
    void reportStats() const;

    /**
     * @brief No-op on Linux (no SE_MANAGE_VOLUME_NAME equivalent).
     */
    static void assignPrivileges();

    /**
     * @brief Write the mHeaderSize-byte file header at offset 0.
     */
    void writeToHeader();

    /**
     * @brief Wait for all in-flight writes to finish.
     */
    void completeRemainingWrites();
};

}  // namespace Storage

#endif  // CUBE_STORAGE_LINUXFILEIO_H
