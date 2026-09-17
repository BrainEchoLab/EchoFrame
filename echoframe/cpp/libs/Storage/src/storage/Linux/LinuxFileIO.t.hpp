//
// Linux async file I/O backend for EchoFrame Storage.
//
// Uses POSIX AIO (aio_write / aio_suspend) for async writes and ftruncate()
// for file extension.  Opened O_DIRECT | O_DSYNC to bypass the page cache
// (mirrors WindowsFileIO's FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH),
// so writes don't compete with the acquisition computer's page cache /
// memory pressure.  This requires every write's offset, length, and buffer
// address to be aligned to the sector size -- see adjustToSectorSize().
//

#include "LinuxFileIO.h"

#include <sys/syscall.h>

#include <cinttypes>
#include <cstdio>

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include "../error.h"

namespace Storage {

// The kernel's statx layout, transcribed. glibc's struct statx and
// <linux/stat.h> cannot be included together (same tag, different members),
// and neither reliably declares stx_dio_mem_align/stx_dio_offset_align. The
// raw syscall is used rather than glibc's wrapper, which is typed against
// glibc's own struct.
namespace {

struct EfStatxTimestamp {
    int64_t tv_sec;
    uint32_t tv_nsec;
    int32_t __reserved;
};

struct EfStatx {
    uint32_t stx_mask;
    uint32_t stx_blksize;
    uint64_t stx_attributes;
    uint32_t stx_nlink;
    uint32_t stx_uid;
    uint32_t stx_gid;
    uint16_t stx_mode;
    uint16_t __spare0[1];
    uint64_t stx_ino;
    uint64_t stx_size;
    uint64_t stx_blocks;
    uint64_t stx_attributes_mask;
    EfStatxTimestamp stx_atime;
    EfStatxTimestamp stx_btime;
    EfStatxTimestamp stx_ctime;
    EfStatxTimestamp stx_mtime;
    uint32_t stx_rdev_major;
    uint32_t stx_rdev_minor;
    uint32_t stx_dev_major;
    uint32_t stx_dev_minor;
    uint64_t stx_mnt_id;
    uint32_t stx_dio_mem_align;
    uint32_t stx_dio_offset_align;
    uint64_t __spare3[12];  // reserved space for fields added after these
};

// statx(2) takes no buffer-length argument: the kernel always writes a fixed
// 256-byte struct. A smaller struct here would be overflowed by the syscall.
static_assert(sizeof(EfStatx) == 256, "EfStatx must match the kernel's fixed statx(2) ABI size");

constexpr uint32_t kEfStatxDioalign = 0x00002000U;    // STATX_DIOALIGN
constexpr uint32_t kEfStatxBasicStats = 0x000007ffU;  // STATX_BASIC_STATS (covers stx_blksize)

}  // namespace

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

template <typename bufferType_t>
LinuxFileIO<bufferType_t>::LinuxFileIO(std::string &pFilePath,
                                       uint64_t pBufferSize,
                                       int pWritesPerBuffer, int pNConcBuffers,
                                       uint64_t pDataTypeCode) {
    if (pFilePath.empty())
        throw storageException(
            "LinuxFileIO constructor: file path is empty\n");
    if (pBufferSize == 0)
        throw storageException(
            "LinuxFileIO constructor: buffer size is 0\n");
    if (pWritesPerBuffer <= 0)
        throw storageException(
            "LinuxFileIO constructor: writes per buffer is invalid\n");
    if (static_cast<uint64_t>(pWritesPerBuffer) > pBufferSize)
        throw storageException(
            "LinuxFileIO constructor: writes per buffer exceeds buffer "
            "elements\n");
    if (pNConcBuffers <= 0)
        throw storageException(
            "LinuxFileIO constructor: concurrent buffers is invalid\n");

    // Rename if a file with the same name already exists.
    std::string filePath = renameFile(pFilePath);

    mFd = open(filePath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_DIRECT | O_DSYNC,
               0644);
    if (mFd < 0)
        throw storageException(
            std::string("LinuxFileIO constructor: open failed: ") +
            strerror(errno) + "\n");
    mFileOpened = true;

    mDataTypeCode = pDataTypeCode;

    // Names this stream in the write summary.
    const size_t slash = filePath.find_last_of('/');
    mStreamLabel = (slash == std::string::npos) ? filePath
                                                : filePath.substr(slash + 1);

    queryAlignment();

    // Buffer size in bytes, padded to a sector-size multiple for O_DIRECT.
    mBufferSize = pBufferSize * sizeof(bufferType_t);
    mWritesPerBuffer = pWritesPerBuffer;
    adjustToSectorSize(mSectorSize);
    configureBlocksAndOffsets();

    mBuffersQueued = 0;
    mBuffersDequeued = 0;

    // Workers: one per concurrent in-flight block write.
    mMaxConcurrentWrites = mWritesPerBuffer * pNConcBuffers;
    mWorkers.resize(mMaxConcurrentWrites);
}

// ---------------------------------------------------------------------------
// Destructor
// ---------------------------------------------------------------------------

template <typename bufferType_t>
LinuxFileIO<bufferType_t>::~LinuxFileIO() {
    if (verbose > 1) std::cout << "\nDestroying LinuxFileIO...\n";
    finalizeAndClose();
}

// ---------------------------------------------------------------------------
// Move constructor / assignment
// ---------------------------------------------------------------------------

template <typename bufferType_t>
LinuxFileIO<bufferType_t>::LinuxFileIO(LinuxFileIO &&x) noexcept {
    finalizeAndClose();
    mFd = x.mFd;
    x.mFd = -1;
    mFileOpened = x.mFileOpened;
    x.mFileOpened = false;

    mBufferSize = x.mBufferSize;
    mPaddingBytes = x.mPaddingBytes;
    mSectorSize = x.mSectorSize;
    mMemAlign = x.mMemAlign;
    mHeaderSize = x.mHeaderSize;
    mWritesPerBuffer = x.mWritesPerBuffer;
    mBlockSize = std::move(x.mBlockSize);
    mBlockOffset = std::move(x.mBlockOffset);

    mBuffersQueued = x.mBuffersQueued;
    mBuffersDequeued = x.mBuffersDequeued;
    mDataTypeCode = x.mDataTypeCode;

    mMaxConcurrentWrites = x.mMaxConcurrentWrites;
    mWorkers = std::move(x.mWorkers);

    mStats = x.mStats;
    mPending = std::move(x.mPending);
    mStreamLabel = std::move(x.mStreamLabel);
}

template <typename bufferType_t>
LinuxFileIO<bufferType_t> &LinuxFileIO<bufferType_t>::operator=(
    LinuxFileIO &&x) noexcept {
    finalizeAndClose();
    mFd = x.mFd;
    x.mFd = -1;
    mFileOpened = x.mFileOpened;
    x.mFileOpened = false;

    mBufferSize = x.mBufferSize;
    mPaddingBytes = x.mPaddingBytes;
    mSectorSize = x.mSectorSize;
    mMemAlign = x.mMemAlign;
    mHeaderSize = x.mHeaderSize;
    mWritesPerBuffer = x.mWritesPerBuffer;
    mBlockSize = std::move(x.mBlockSize);
    mBlockOffset = std::move(x.mBlockOffset);

    mBuffersQueued = x.mBuffersQueued;
    mBuffersDequeued = x.mBuffersDequeued;
    mDataTypeCode = x.mDataTypeCode;

    mMaxConcurrentWrites = x.mMaxConcurrentWrites;
    mWorkers = std::move(x.mWorkers);

    mStats = x.mStats;
    mPending = std::move(x.mPending);
    mStreamLabel = std::move(x.mStreamLabel);

    return *this;
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

template <typename bufferType_t>
off_t LinuxFileIO<bufferType_t>::getFileSize() const {
    off_t sz = lseek(mFd, 0, SEEK_END);
    if (sz < 0)
        throw storageException(std::string("getFileSize: lseek failed: ") +
                               strerror(errno) + "\n");
    return sz;
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::reserveFileSpace(off_t offset, off_t length) {
    if (length <= 0) return;

    const int err = posix_fallocate(mFd, offset, length);
    if (err == 0) return;

    if (err != EOPNOTSUPP && err != ENOSYS) {
        throw storageException(
            std::string("reserveFileSpace: posix_fallocate failed: ") +
            strerror(err) + "\n");
    }

    if (ftruncate(mFd, offset + length) != 0)
        throw storageException(
            std::string("reserveFileSpace: ftruncate failed: ") +
            strerror(errno) + "\n");
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::syncFileData() const {
    if (fdatasync(mFd) != 0)
        throw storageException(
            std::string("syncFileData: fdatasync failed: ") +
            strerror(errno) + "\n");
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::finalizeAndClose() noexcept {
    if (!mFileOpened) return;

    if (verbose > 0 && logAtLeast(kLogNormal))
        std::cout << "Completing remaining writes and writing header...\n";

    try {
        completeRemainingWrites();
        reportStats();
        writeToHeader();
        syncFileData();
    } catch (const std::exception &e) {
        std::cerr << e.what();
    } catch (...) {
        std::cerr << "LinuxFileIO finalization failed with unknown error\n";
    }

    if (close(mFd) != 0) {
        std::cerr << "finalizeAndClose: close failed: " << strerror(errno)
                  << "\n";
    }

    mFd = -1;
    mFileOpened = false;
}

template <typename bufferType_t>
bool LinuxFileIO<bufferType_t>::fileExists(const std::string &path) {
    return access(path.c_str(), F_OK) == 0;
}

template <typename bufferType_t>
std::string LinuxFileIO<bufferType_t>::renameFile(std::string &pFilePath) {
    std::string filePath = pFilePath + ".dat";
    if (fileExists(filePath)) {
        int n = 1;
        filePath = pFilePath + "_" + std::to_string(n) + ".dat";
        while (fileExists(filePath))
            filePath = pFilePath + "_" + std::to_string(++n) + ".dat";
    }
    return filePath;
}

// ---------------------------------------------------------------------------
// File extension
// ---------------------------------------------------------------------------

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::extendFileHeader() {
    reserveFileSpace(getFileSize(), static_cast<off_t>(mHeaderSize));
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::extendFile(int nBuffers) {
    off_t addBytes =
        static_cast<off_t>(nBuffers) * static_cast<off_t>(mBufferSize);
    reserveFileSpace(getFileSize(), addBytes);
}

// ---------------------------------------------------------------------------
// Block layout
// ---------------------------------------------------------------------------

// Query the file's O_DIRECT alignment via statx(STATX_DIOALIGN). Offset/length
// alignment (stx_dio_offset_align) and buffer-address alignment
// (stx_dio_mem_align) are reported separately and are not guaranteed equal.
// Throws if either is unavailable -- a kernel without STATX_DIOALIGN, or a
// filesystem that accepts O_DIRECT without enforcing alignment (e.g. tmpfs).
template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::queryAlignment() {
    EfStatx stx {};
    if (syscall(SYS_statx, mFd, "", AT_EMPTY_PATH,
                kEfStatxDioalign | kEfStatxBasicStats, &stx) != 0)
        throw storageException(
            std::string("queryAlignment: statx failed: ") + strerror(errno) +
            "\n");
    if (!(stx.stx_mask & kEfStatxDioalign))
        throw storageException(
            "queryAlignment: kernel does not report STATX_DIOALIGN "
            "(requires Linux 6.1+)\n");
    if (stx.stx_dio_offset_align == 0 || stx.stx_dio_mem_align == 0)
        throw storageException(
            "queryAlignment: filesystem does not support/enforce O_DIRECT "
            "alignment (dio_offset_align/dio_mem_align reported as 0 -- "
            "direct I/O is not actually honored on this filesystem, e.g. "
            "tmpfs)\n");

    // dio_offset_align is only the required minimum: on a 512e drive (512 B
    // logical, 4096 B physical) it is 512, and writing at that alignment forces
    // a device-side read-modify-write per block. Prefer stx_blksize (typically
    // the physical sector) when it is a whole multiple of dio_offset_align, so
    // writes land on physical-sector boundaries; fall back to dio_offset_align.
    mSectorSize = stx.stx_dio_offset_align;
    if ((stx.stx_mask & kEfStatxBasicStats) && stx.stx_blksize > mSectorSize &&
        stx.stx_blksize % stx.stx_dio_offset_align == 0) {
        mSectorSize = stx.stx_blksize;
    }
    mMemAlign = stx.stx_dio_mem_align;

    mHeaderSize = computeHeaderSize();
}

// The header only has to satisfy O_DIRECT's length requirement, i.e. be a
// multiple of mSectorSize. Buffer-address alignment is independent of size and
// is handled by posix_memalign. Readers parse headerSize out of the file, so
// this is not fixed at 4096.
template <typename bufferType_t>
uint64_t LinuxFileIO<bufferType_t>::computeHeaderSize() const {
    return mSectorSize;
}

// Mirrors WindowsFileIO::adjustToSectorSize: pad mBufferSize up to a sector
// multiple, then grow mWritesPerBuffer until every block's byte size (and the
// last block's) is itself a sector multiple -- required for O_DIRECT writes.
template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::adjustToSectorSize(size_t pSectorSize) {
    if (mBufferSize % pSectorSize != 0) {
        mPaddingBytes = pSectorSize - mBufferSize % pSectorSize;
        mBufferSize += mPaddingBytes;
    }

    if (static_cast<uint64_t>(mWritesPerBuffer) > pSectorSize)
        throw storageException(
            "adjustToSectorSize: writes per buffer exceeded the storage "
            "disk's sector size\n");

    while ((mBufferSize / mWritesPerBuffer) % pSectorSize != 0 ||
           (mBufferSize - (mWritesPerBuffer - 1) *
                              (mBufferSize / mWritesPerBuffer)) %
                   pSectorSize !=
               0) {
        mWritesPerBuffer++;
        if (static_cast<uint64_t>(mWritesPerBuffer) > pSectorSize)
            throw storageException(
                "adjustToSectorSize: writes per buffer exceeded the storage "
                "disk's sector size while trying to adjust for compliance "
                "of each write block size being a multiple of the sector "
                "size\n");
    }
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::configureBlocksAndOffsets() {
    mBlockSize.resize(mWritesPerBuffer);
    mBlockOffset.resize(mWritesPerBuffer);

    uint64_t blockSize = mBufferSize / mWritesPerBuffer;

    for (int i = 0; i < mWritesPerBuffer; i++) {
        if (i != mWritesPerBuffer - 1) {
            mBlockSize[i] = blockSize;
        } else {
            // Last block takes any remainder.
            mBlockSize[i] = mBufferSize - (mWritesPerBuffer - 1) * blockSize;
        }

        if (i == 0) {
            mBlockOffset[i] = 0;
        } else {
            mBlockOffset[i] =
                mBlockOffset[i - 1] + mBlockSize[i - 1] / sizeof(bufferType_t);
        }
    }
}

// ---------------------------------------------------------------------------
// Async write
// ---------------------------------------------------------------------------

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::writeOverlappedBuffer(bufferType_t *buffer,
                                                      int /*timeout*/) {
    const StorageDebugFlags &flags = storageDebugFlags();
    const StorageClock::time_point queuedAt = StorageClock::now();

    // Digest the source as the caller hands it over; the padding is not
    // written by the producer, so only the payload is covered.
    uint64_t digest = 0;
    size_t digestBytes = 0;
    if (flags.verify) {
        digestBytes = static_cast<size_t>(mBufferSize - mPaddingBytes);
        digest = probeDigest(buffer, digestBytes, flags.probes);
    }

    // Taken at queue time, so a deferred write still lands where it would have.
    const uint64_t recordIndex = mBuffersQueued;
    mBuffersQueued++;

    if (flags.delayWriteMs > 0) {
        // Hold the write without telling the caller, so storage still owns
        // the buffer while its producer moves on. Testing only.
        PendingWrite p;
        p.buffer = buffer;
        p.recordIndex = recordIndex;
        p.digest = digest;
        p.digestBytes = digestBytes;
        p.queuedAt = queuedAt;
        p.releaseAt = queuedAt + std::chrono::milliseconds(flags.delayWriteMs);
        mPending.push_back(p);
        flushPending(false);
        return;
    }

    issueWrite(buffer, recordIndex, digest, digestBytes, queuedAt);
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::issueWrite(bufferType_t *buffer,
                                           uint64_t recordIndex,
                                           uint64_t digest, size_t digestBytes,
                                           StorageClock::time_point queuedAt) {
    for (int i = 0; i < mWritesPerBuffer; i++) {
        // Indexed by the record, not mBuffersQueued: a deferred write must
        // land on the worker its dequeue side will look at.
        int idx = static_cast<int>((recordIndex * mWritesPerBuffer + i) %
                                   mMaxConcurrentWrites);
        AioWorker &w = mWorkers[idx];

        uint64_t blockByteOffset = mBlockOffset[i] * sizeof(bufferType_t);
        off_t fileOffset = static_cast<off_t>(mHeaderSize) +
                           static_cast<off_t>(recordIndex * mBufferSize) +
                           static_cast<off_t>(blockByteOffset);

        memset(&w.cb, 0, sizeof(struct aiocb));
        w.cb.aio_fildes = mFd;
        // aio_buf must be non-const; the API takes volatile void*.
        w.cb.aio_buf =
            const_cast<void *>(static_cast<const void *>(&buffer[mBlockOffset[i]]));
        w.cb.aio_nbytes = static_cast<size_t>(mBlockSize[i]);
        w.cb.aio_offset = fileOffset;
        w.cb.aio_sigevent.sigev_notify = SIGEV_NONE;

        w.queuedAt = queuedAt;
        w.digest = digest;
        w.digestBytes = digestBytes;
        w.recordIndex = recordIndex;

        if (aio_write(&w.cb) != 0)
            throw storageException(
                std::string("writeOverlappedBuffer: aio_write failed: ") +
                strerror(errno) + "\n");
        w.inUse = true;
        mStats.writeIssued();
    }
}

template <typename bufferType_t>
bool LinuxFileIO<bufferType_t>::flushPending(bool all) {
    bool issued = false;
    const StorageClock::time_point now = StorageClock::now();
    while (!mPending.empty()) {
        const PendingWrite &front = mPending.front();
        if (!all && front.releaseAt > now) break;
        PendingWrite held = front;
        mPending.pop_front();
        issueWrite(static_cast<bufferType_t *>(held.buffer), held.recordIndex,
                   held.digest, held.digestBytes, held.queuedAt);
        issued = true;
    }
    return issued;
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::onWriteCompleted(AioWorker &w) {
    mStats.writeCompleted();

    // Nothing polls for completion once storeBuffer stops being called, so a
    // write still open at the final drain is first noticed there -- possibly
    // long after it finished. Timing that would put the wait for the drain into
    // the write latency, so those are counted without it.
    if (mFinalDrain) {
        mStats.recordCompletedUntimed();
    } else {
        mStats.recordLatency(
            std::chrono::duration<double, std::milli>(StorageClock::now() -
                                                      w.queuedAt)
                .count());
    }

    // A changed digest means the producer refilled the buffer while the disk
    // was still reading it, so the record that just landed is two frames mixed.
    if (storageDebugFlags().verify && w.digestBytes > 0) {
        const uint64_t now =
            probeDigest(const_cast<const void *>(w.cb.aio_buf), w.digestBytes,
                        storageDebugFlags().probes);
        ++mStats.verified;
        if (now != w.digest) {
            mStats.recordCorrupt(w.recordIndex);
            std::cerr << "[storage] " << mStreamLabel << ": record "
                      << w.recordIndex
                      << " changed while its write was in flight -- stored data "
                         "is corrupt.\n";
        }
    }
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::reportStats() const {
    if (!storageDebugFlags().report || mStats.completed == 0) return;
    // An end-of-recording summary, which is what EF_LOG_LEVEL calls normal.
    // EF_STORAGE_STATS still turns it off on its own.
    if (!logAtLeast(kLogNormal)) return;

    std::cout << "[storage] " << mStreamLabel << ": " << mStats.completed
              << " writes | latency mean " << mStats.latencyMeanMs()
              << " ms, max " << mStats.latencyMaxMs << " ms | peak "
              << mStats.outstandingHighWater << " in flight | blocked "
              << mStats.blockedSumMs << " ms total, " << mStats.blockedMaxMs
              << " ms max";
    if (mStats.verified > 0) {
        std::cout << " | verified " << mStats.verified << ", corrupt "
                  << mStats.corrupted;
        if (mStats.anyCorrupt)
            std::cout << " (first at record " << mStats.firstCorruptRecord
                      << ")";
    }
    std::cout << "\n" << std::flush;
}

// ---------------------------------------------------------------------------
// Wait for one buffer to finish
// ---------------------------------------------------------------------------

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::waitForBufferWriteComplete() {
    if (mBuffersQueued <= mBuffersDequeued)
        throw storageException(
            "waitForBufferWriteComplete: no buffers to dequeue\n");

    // Anything still held has to go out first, or there is nothing to wait for.
    flushPending(true);

    const StorageClock::time_point blockedFrom = StorageClock::now();
    for (int i = 0; i < mWritesPerBuffer; i++) {
        int idx =
            static_cast<int>((mBuffersDequeued * mWritesPerBuffer + i) %
                             mMaxConcurrentWrites);
        AioWorker &w = mWorkers[idx];
        if (!w.inUse) continue;

        while (true) {
            const int err = aio_error(&w.cb);
            if (err == EINPROGRESS) {
                const struct aiocb *cblist[1] = {&w.cb};
                const int ret = aio_suspend(cblist, 1, nullptr);
                if (ret == 0 || errno == EINTR) continue;
                throw storageException(
                    std::string(
                        "waitForBufferWriteComplete: aio_suspend failed: ") +
                    strerror(errno) + "\n");
            }

            if (err == EINVAL) {
                // Usually a misaligned buffer address: O_DIRECT requires
                // aio_buf % mMemAlign == 0. BF/PDI are cudaMallocHost'd and so
                // page-aligned, but the caller-owned RF and time-tag buffers
                // carry no such guarantee. Report the address so the caller's
                // allocation can be fixed; there is no bounce-buffer fallback.
                const uintptr_t addr =
                    reinterpret_cast<uintptr_t>(const_cast<void *>(w.cb.aio_buf));
                char addrHex[32];
                std::snprintf(addrHex, sizeof(addrHex), "0x%" PRIxPTR, addr);
                throw storageException(
                    "waitForBufferWriteComplete: aio_error: Invalid argument "
                    "(likely a misaligned write buffer -- address " +
                    std::string(addrHex) +
                    " is not a multiple of the required buffer-address "
                    "alignment, " + std::to_string(mMemAlign) +
                    " bytes; offset from alignment: " +
                    std::to_string(addr % mMemAlign) + " bytes)\n");
            }
            if (err != 0)
                throw storageException(
                    std::string("waitForBufferWriteComplete: aio_error: ") +
                    strerror(err) + "\n");

            errno = 0;
            const ssize_t bytesWritten = aio_return(&w.cb);
            if (bytesWritten < 0)
                throw storageException(
                    std::string("waitForBufferWriteComplete: aio_return failed: ") +
                    strerror(errno) + "\n");
            if (static_cast<uint64_t>(bytesWritten) != mBlockSize[i]) {
                throw storageException(
                    "waitForBufferWriteComplete: short write detected\n");
            }

            onWriteCompleted(w);
            w.inUse = false;
            break;
        }
    }

    mStats.recordBlocked(msSince(blockedFrom));
    mBuffersDequeued++;
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::assignPrivileges() {
    // No-op on Linux (no equivalent to SE_MANAGE_VOLUME_NAME).
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::writeToHeader() {
    // posix_memalign requires the alignment to be a multiple of sizeof(void *),
    // which mMemAlign need not be (ext4 on WSL reports 4), so clamp up.
    // mMemAlign itself is left as reported and is quoted on error.
    size_t allocAlign = static_cast<size_t>(mMemAlign);
    if (allocAlign < sizeof(void *)) allocAlign = sizeof(void *);

    void *raw = nullptr;
    if (int rc = posix_memalign(&raw, allocAlign,
                                static_cast<size_t>(mHeaderSize)))
        throw storageException(
            "writeToHeader: posix_memalign(alignment=" +
            std::to_string(allocAlign) + ", size=" +
            std::to_string(mHeaderSize) + ") failed: " + strerror(rc) + "\n");
    std::unique_ptr<void, decltype(&free)> headerGuard(raw, &free);

    char *header = static_cast<char *>(raw);
    std::memset(header, 0, mHeaderSize);
    uint64_t *fields = reinterpret_cast<uint64_t *>(header);
    fields[0] = mVersion;
    fields[1] = mHeaderSize;
    fields[2] = mBuffersDequeued;
    fields[3] = (mBufferSize - mPaddingBytes) / sizeof(bufferType_t);  // elements per buffer, excluding padding
    fields[4] = mPaddingBytes;
    fields[5] = mDataTypeCode;

    size_t totalWritten = 0;
    while (totalWritten < mHeaderSize) {
        const ssize_t written =
            pwrite(mFd, header + totalWritten, mHeaderSize - totalWritten,
                   static_cast<off_t>(totalWritten));
        if (written < 0) {
            if (errno == EINTR) continue;
            throw storageException(
                std::string("writeToHeader: pwrite failed: ") +
                strerror(errno) + "\n");
        }
        totalWritten += static_cast<size_t>(written);
    }
}

template <typename bufferType_t>
void LinuxFileIO<bufferType_t>::completeRemainingWrites() {
    mFinalDrain = true;
    flushPending(true);
    while (mBuffersQueued > mBuffersDequeued) {
        waitForBufferWriteComplete();
    }
}

}  // namespace Storage
