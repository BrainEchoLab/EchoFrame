//
// Created by petros on 26/03/2022.
//

#ifndef CUBE_STORAGE_WINDOWSFILEIO_H
#define CUBE_STORAGE_WINDOWSFILEIO_H

#include <Windows.h>

#include <deque>
#include <fstream>
#include <vector>

#include "../../utils/Timer.h"
#include "../write_stats.h"

namespace Storage {
// `overlapped` must stay first: completions come back as an LPOVERLAPPED and
// are reinterpret_cast back to this struct.
struct OVERLAPPED_BUFFER {
    OVERLAPPED overlapped;
    void *buffer;
    // Carried with the write so its completion can identify itself.
    StorageClock::time_point queuedAt{};
    uint64_t digest{0};
    size_t digestBytes{0};
    uint64_t recordIndex{0};
    bool inFlight{false};  ///< a write was issued and has not been accounted for
    bool settled{false};   ///< its completion has already been timed and checked
};

// Offset/length alignment (mSectorSize, via FileStorageInfo) and buffer-address
// alignment (mBufferAlignmentMask, via FileAlignmentInfo) are queried at open
// time in queryAlignment(); the constructor throws if either query fails.
template <typename bufferType_t>
class WindowsFileIO {
   private:
    HANDLE mFile;
    bool mFileOpened = false;
    HANDLE mIocp;
    bool mIocpCreated = false;
    LONG mMaxConcurrentWrites;
    LONG mWritesPerBuffer;
    std::vector<OVERLAPPED_BUFFER> mWorkers;
    std::vector<Timer> mWorkerTimers;
    ULONGLONG mBufferSize;
    std::vector<DWORD> mBlockSize;
    std::vector<ULONGLONG> mBlockOffset;
    volatile ULONG mActiveWorkerCount;

    // Write-worker selection strategy. Compile-time; rebuild to switch.
    //   false -> round-robin cursor (mNextWorker), the default.
    //   true  -> free-list (mFreeWorkers): tracks which slots are actually
    //            free rather than assuming they free in issue order, which
    //            IOCP completions do not guarantee.
    static constexpr bool kUseFreeListWorkerSelection = false;

    volatile ULONG mNextWorker;      // round-robin cursor (toggle == false)
    std::vector<LONG> mFreeWorkers;  // free-list stack (toggle == true)

    WriteStats mStats;                  // per-file, reset by switchFile()
    std::deque<PendingWrite> mPending;  // held by EF_STORAGE_DELAY_WRITE_MS
    std::string mStreamLabel;           // names this stream in reports
    // Completions are only noticed when one is dequeued. During the closing
    // drain that can be long after the write finished, by which time the
    // producer has legitimately reused the buffer, so the digest is stale.
    bool mFinalDrain{false};

    int verbose{1};

    /** header info (stored at the start of the file) */
    // the header size must be a multiple of mSectorSize because of the
    // FILE_FLAG_NO_BUFFERING flag during file creation
    uint64_t mVersion = 1;    // 1: buffer format version
    uint64_t mHeaderSize = 0;  // 2: header size in bytes; set by queryAlignment()/computeHeaderSize()
    // 3: number of frames stored, which equals mBuffersDequeued
    // 4: buffer size without padding
    uint64_t mPaddingBytes = 0;  // 5: buffer padding size in bytes, in case
    // it's not a multiple of mSectorSize
    uint64_t mDataTypeCode;  // 6: data type of the buffer

    // Required buffer-address alignment (DEVICE_OBJECT::AlignmentRequirement),
    // as the raw mask FILE_ALIGNMENT_INFO returns: alignment - 1, where 0 means
    // unaligned access is fine. Not consumed by any write call site.
    ULONG mBufferAlignmentMask = 0;

    // Offset/length alignment (FILE_STORAGE_INFO::LogicalBytesPerSector), set by
    // queryAlignment() early in the constructor.
    ULONGLONG mSectorSize = 0;

    /**
     * @brief Query mBufferAlignmentMask (FileAlignmentInfo) and mSectorSize
     * (FileStorageInfo) via GetFileInformationByHandleEx, and derive
     * mHeaderSize from both.
     */
    void queryAlignment();

    /**
     * @brief Header size that is a multiple of mSectorSize, so
     * writeToHeader() can satisfy FILE_FLAG_NO_BUFFERING's write-length
     * requirement. Buffer-address alignment (mBufferAlignmentMask) is
     * handled independently by _aligned_malloc.
     */
    ULONGLONG computeHeaderSize() const;

   public:
    uint64_t mBuffersQueued = 0;    // number of instances queued
    uint64_t mBuffersDequeued = 0;  // number of instances dequeued

    WindowsFileIO() = default;

    WindowsFileIO(std::string &pFilePath, ULONGLONG pBufferSize,
                  int pWritesPerBuffer, int pNConcBuffers,
                  uint64_t pDataTypeCode);

    ~WindowsFileIO();

    WindowsFileIO(WindowsFileIO &&x) noexcept;             // move-constructor
    WindowsFileIO &operator=(WindowsFileIO &&x) noexcept;  // move-assignment

    /**
     * @param szPath path of file
     * @return Whether file already exists
     */
    static BOOL FileExists(LPCTSTR szPath);

    /**
     * @param pFilePath file path
     * @return New file name (pFilePath + '_<number>')
     */
    static std::string renameFile(std::string &pFilePath);

    /**
     * @brief Extend a file
     * @param nBuffers number of buffers to extend file for
     */
    void extendFile(int nBuffers);

    /**
     * @brief extend the header of a file
     */
    void extendFileHeader();

    /**
     * @brief Adjust file size to be divisible by the sector size
     * @param pSectorSize volume's sector size
     */
    void adjustToSectorSize(size_t pSectorSize);

    /**
     * @brief Configure blocks' sizes and offsets for each buffer write (if
     * there are multiple writes/buffer)
     */
    void configureBlocksAndOffsets();

    /**
     * @brief Wait for I/O to complete
     */
    void waitForIoComplete();

    /**
     * @brief Dequeue N workers, i.e wait for N worker-threads to complete
     * storage
     * @param nworkers_to_remove number (N) of workers to dequeue
     * @param profile_file file for profiling purposes
     * @return number of workers actually dequeued
     */
    unsigned long dequeueNWorkers(
        unsigned long nworkers_to_remove,
        std::basic_ofstream<char, std::char_traits<char>> &profile_file);

    /**
     * @brief Wait for a buffer to complete writing
     */
    void waitForBufferWriteComplete();

    /**
     * @param timeout time to wait for a worker to become available
     * @param workerDequeued whether a worker was dequeued
     * @return An available worker
     */
    OVERLAPPED_BUFFER *getAvailableWorker(DWORD timeout, bool &workerDequeued);

    /**
     * @brief Write a buffer (in an overlapped manner)
     * @param buffer buffer to write
     * @param timeout time to wait for worker to become available
     */
    void writeOverlappedBuffer(bufferType_t *buffer, DWORD timeout);

    /**
     * @brief Issue the WriteFile calls for one buffer at a fixed record index.
     * The index is passed in so a deferred write still lands at the offset it
     * was given when the caller handed the buffer over.
     */
    void issueWrite(bufferType_t *buffer, uint64_t recordIndex,
                    uint64_t digest, size_t digestBytes,
                    StorageClock::time_point queuedAt, DWORD timeout);

    /**
     * @brief Account for one completed write: latency, outstanding count, and
     * whether the source changed in flight when EF_STORAGE_VERIFY is on.
     */
    void onWriteCompleted(OVERLAPPED_BUFFER *worker);

    /**
     * @brief Time and check every write that has finished but not yet been
     * dequeued.
     *
     * Completions are dequeued one per storeBuffer, so a write is not otherwise
     * noticed until a couple of frames after it finished -- long enough for the
     * producer to have refilled an unringed buffer, which then reads as
     * corruption and inflates the latency by the reaping lag. This polls the
     * OVERLAPPED status, which touches neither the port nor the accounting.
     */
    void settleFinishedWrites();

    /**
     * @brief Record one write's completion latency and, when EF_STORAGE_VERIFY
     * is on, re-check its source digest.
     */
    void settleWrite(OVERLAPPED_BUFFER &worker);

    /**
     * @brief Issue writes held by EF_STORAGE_DELAY_WRITE_MS.
     * @param all release everything, ignoring deadlines
     * @return whether anything was issued
     */
    bool flushPending(bool all, DWORD timeout);

    /// Per-file write instrumentation.
    const WriteStats &stats() const { return mStats; }

    /// Name used for this stream in the summary line.
    void setStreamLabel(const std::string &label) { mStreamLabel = label; }

    /**
     * @brief Print the write summary for this file.
     */
    void reportStats() const;

    /**
     * @brief Assign admin priviledges (for extending files more efficiently)
     */
    static void assignPrivileges();

    /**
     * @brief Write information to header
     */
    void writeToHeader();

    /**
     * @brief Complete any remaining writes
     */
    void completeRemainingWrites();
};
}  // namespace Storage

#endif  // CUBE_STORAGE_WINDOWSFILEIO_H
