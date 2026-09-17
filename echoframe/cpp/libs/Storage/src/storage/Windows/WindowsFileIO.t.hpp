//
// Created by petros on 26/03/2022.
//

#include "WindowsFileIO.h"

#include <algorithm>
#include <iostream>
#include <string>

#include "../error.h"

namespace Storage {
template <typename bufferType_t>
WindowsFileIO<bufferType_t>::WindowsFileIO(std::string &pFilePath,
                                           ULONGLONG pBufferSize,
                                           int pWritesPerBuffer,
                                           int pNConcBuffers,
                                           uint64_t pDataTypeCode) {
    if (pFilePath.empty())
        throw storageException(
            "WindowsFileIO constructor: File path location is empty\n");
    if (pBufferSize == 0)
        throw storageException("WindowsFileIO constructor: Buffer size is 0\n");
    if (pWritesPerBuffer <= 0)
        throw storageException(
            "WindowsFileIO constructor: writes per buffer is invalid\n");
    if (pNConcBuffers <= 0)
        throw storageException(
            "WindowsFileIO constructor: max concurrent writes is invalid\n");

    // rename file if it already exists
    std::string filePath(std::move(renameFile(pFilePath)));

    // open mFile and IO port
    try {
        mFile = CreateFile(filePath.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                           nullptr, CREATE_ALWAYS,
                           FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED |
                               FILE_FLAG_WRITE_THROUGH | FILE_ATTRIBUTE_NORMAL,
                           nullptr);

        if (GetLastError() == ERROR_ALREADY_EXISTS)
            throw storageException(
                "File with the same name has already been created. "
                "Overwriting...\n");
    } catch (storageException &e) {
        std::cerr << e.what();  // just let the user know, don't exit
    }

    mFileOpened = true;

    if (mFile == INVALID_HANDLE_VALUE)
        throw storageException(
            "Error (CreateFile): " + std::to_string(GetLastError()) + "\n");

    mIocp = CreateIoCompletionPort(mFile, nullptr, NULL, 0);
    mIocpCreated = true;

    queryAlignment();

    // Data type code
    mDataTypeCode = pDataTypeCode;

    // Names this stream in the write summary.
    const size_t slash = filePath.find_last_of("/\\");
    mStreamLabel = (slash == std::string::npos) ? filePath
                                                : filePath.substr(slash + 1);

    if (!mIocp)
        throw storageException("Error (CreateIoCompletionPort): " +
                               std::to_string(GetLastError()) + "\n");

    // buffers
    mBufferSize = pBufferSize * sizeof(bufferType_t);
    mWritesPerBuffer = pWritesPerBuffer;
    adjustToSectorSize(static_cast<size_t>(mSectorSize));
    configureBlocksAndOffsets();

    mBuffersQueued = 0;
    mBuffersDequeued = 0;

    // mWorkers
    mMaxConcurrentWrites = mWritesPerBuffer * pNConcBuffers;
    mWorkers.resize(mMaxConcurrentWrites);
    mWorkerTimers.resize(mMaxConcurrentWrites);

    Timer timer;
    timer.start();
    for (auto &worker : mWorkers) {
        ZeroMemory(&worker.overlapped, sizeof(OVERLAPPED));

        worker.overlapped.hEvent = CreateEvent(nullptr, true, false, nullptr);
    }

    mActiveWorkerCount = 0;
    mNextWorker = 0;
    if constexpr (kUseFreeListWorkerSelection) {
        mFreeWorkers.clear();
        mFreeWorkers.reserve(mMaxConcurrentWrites);
        // Push in reverse so pop_back() hands out 0, 1, 2, ... first.
        for (LONG w = mMaxConcurrentWrites - 1; w >= 0; --w)
            mFreeWorkers.push_back(w);
    }
}

template <typename bufferType_t>
WindowsFileIO<bufferType_t>::~WindowsFileIO() {
    if (verbose > 1) std::cout << "\nDestroying WindowsFileIO...\n";
    if (mFileOpened) {
        if (verbose > 0 && logAtLeast(kLogNormal))
            std::cout
                << "Completing remaining writes and writing to header...\n";
        completeRemainingWrites();
        reportStats();
        writeToHeader();

        CloseHandle(mFile);
    }

    if (mIocpCreated) CloseHandle(mIocp);
}

template <typename bufferType_t>
WindowsFileIO<bufferType_t>::WindowsFileIO(WindowsFileIO &&x) noexcept {
    if (mFileOpened) {
        completeRemainingWrites();
        reportStats();
        writeToHeader();

        CloseHandle(mFile);
    }
    mFile = x.mFile;
    x.mFile = nullptr;
    mFileOpened = x.mFileOpened;
    x.mFileOpened = false;

    if (mIocpCreated) CloseHandle(mIocp);
    mIocp = x.mIocp;
    x.mIocp = nullptr;
    mIocpCreated = x.mIocpCreated;
    x.mIocpCreated = false;

    // buffers
    mBufferSize = x.mBufferSize;
    mPaddingBytes = x.mPaddingBytes;
    mBufferAlignmentMask = x.mBufferAlignmentMask;
    mHeaderSize = x.mHeaderSize;
    mWritesPerBuffer = x.mWritesPerBuffer;
    mBlockSize = x.mBlockSize;
    mBlockOffset = x.mBlockOffset;

    mBuffersQueued = x.mBuffersQueued;
    mBuffersDequeued = x.mBuffersDequeued;
    mDataTypeCode = x.mDataTypeCode;

    // mWorkers
    mMaxConcurrentWrites = x.mMaxConcurrentWrites;
    mWorkers = x.mWorkers;
    mActiveWorkerCount = x.mActiveWorkerCount;
    mNextWorker = x.mNextWorker;
    mFreeWorkers = std::move(x.mFreeWorkers);

    mStats = x.mStats;
    mPending = std::move(x.mPending);
    mStreamLabel = std::move(x.mStreamLabel);
}

// Move assignment
template <typename bufferType_t>
WindowsFileIO<bufferType_t> &WindowsFileIO<bufferType_t>::operator=(
    WindowsFileIO &&x) noexcept {
    if (mFileOpened) {
        completeRemainingWrites();
        reportStats();
        writeToHeader();

        CloseHandle(mFile);
    }
    mFile = x.mFile;
    x.mFile = nullptr;
    mFileOpened = x.mFileOpened;
    x.mFileOpened = false;

    if (mIocpCreated) CloseHandle(mIocp);
    mIocp = x.mIocp;
    x.mIocp = nullptr;
    mIocpCreated = x.mIocpCreated;
    x.mIocpCreated = false;

    // buffers
    mBufferSize = x.mBufferSize;
    mPaddingBytes = x.mPaddingBytes;
    mBufferAlignmentMask = x.mBufferAlignmentMask;
    mHeaderSize = x.mHeaderSize;
    mWritesPerBuffer = x.mWritesPerBuffer;
    mBlockSize = x.mBlockSize;
    mBlockOffset = x.mBlockOffset;

    mBuffersQueued = x.mBuffersQueued;
    mBuffersDequeued = x.mBuffersDequeued;
    mDataTypeCode = x.mDataTypeCode;

    // mWorkers
    mMaxConcurrentWrites = x.mMaxConcurrentWrites;
    mWorkers = x.mWorkers;
    mActiveWorkerCount = x.mActiveWorkerCount;
    mNextWorker = x.mNextWorker;
    mFreeWorkers = std::move(x.mFreeWorkers);

    mStats = x.mStats;
    mPending = std::move(x.mPending);
    mStreamLabel = std::move(x.mStreamLabel);

    return *this;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::assignPrivileges() {
    HANDLE hToken;

    if (!::OpenProcessToken(::GetCurrentProcess(),
                            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &hToken))
        throw storageException("Error (assignPriviledges::OpenProcessToken): " +
                               std::to_string(GetLastError()) + "\n");

    LUID luid;

    if (!::LookupPrivilegeValue(nullptr, SE_MANAGE_VOLUME_NAME, &luid))
        throw storageException(
            "Error (assignPriviledges::LookupPrivilegeValue): " +
            std::to_string(GetLastError()) + "\n");

    TOKEN_PRIVILEGES tp;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Luid = luid;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (!::AdjustTokenPrivileges(hToken, false, &tp, sizeof(TOKEN_PRIVILEGES),
                                 nullptr, nullptr))
        throw storageException(
            "Error (assignPriviledges::AdjustTokenPriviledges): " +
            std::to_string(GetLastError()) + "\n");

    if (GetLastError() == ERROR_NOT_ALL_ASSIGNED)
        throw storageException(
            "Error (assignPriviledges::ERROR_NOT_ALL_ASSIGNED): " +
            std::to_string(GetLastError()) + "\n");

    CloseHandle(hToken);
}

template <typename bufferType_t>
BOOL WindowsFileIO<bufferType_t>::FileExists(LPCTSTR szPath) {
    DWORD dwAttrib = GetFileAttributes(szPath);

    return (dwAttrib != INVALID_FILE_ATTRIBUTES &&
            !(dwAttrib & FILE_ATTRIBUTE_DIRECTORY));
}

template <typename bufferType_t>
std::string WindowsFileIO<bufferType_t>::renameFile(std::string &pFilePath) {
    std::string filePath = pFilePath + ".dat";

    if (FileExists(filePath.c_str())) {
        int fileNr = 1;
        filePath = pFilePath + "_" + std::to_string(fileNr) + ".dat";
        while (FileExists(filePath.c_str())) {
            filePath = pFilePath + "_" + std::to_string(++fileNr) + ".dat";
        }
    }

    return filePath;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::extendFileHeader() {
    LARGE_INTEGER extendSize;
    LARGE_INTEGER fileEnd;
    extendSize.QuadPart = static_cast<LONGLONG>(mHeaderSize);

    if (!SetFilePointerEx(mFile, extendSize, &fileEnd, FILE_END))
        throw storageException("Error (SetFilePointerEx): " +
                               std::to_string(GetLastError()) + "\n");

    if (!SetEndOfFile(mFile))
        throw storageException(
            "Error (SetEndOfFile): " + std::to_string(GetLastError()) + "\n");

    if (!SetFileValidData(mFile, fileEnd.QuadPart))
        throw storageException("Error (SetFileValidData): " +
                               std::to_string(GetLastError()) + "\n");
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::extendFile(int nBuffers) {
    LARGE_INTEGER extendSize;
    LARGE_INTEGER fileEnd;
    extendSize.QuadPart = static_cast<LONGLONG>(mBufferSize * nBuffers);

    if (!SetFilePointerEx(mFile, extendSize, &fileEnd, FILE_END))
        throw storageException("Error (SetFilePointerEx): " +
                               std::to_string(GetLastError()) + "\n");

    if (!SetEndOfFile(mFile))
        throw storageException(
            "Error (SetEndOfFile): " + std::to_string(GetLastError()) + "\n");

    if (!SetFileValidData(mFile, fileEnd.QuadPart))
        throw storageException("Error (SetFileValidData): " +
                               std::to_string(GetLastError()) + "\n");
}

// Query the volume's buffer-address alignment for FILE_FLAG_NO_BUFFERING via
// GetFileInformationByHandleEx(FileAlignmentInfo) and its offset/length
// alignment (mSectorSize) via FileStorageInfo. Both are per-volume and are not
// guaranteed equal. Throws if either query fails; an AlignmentRequirement of 0
// (FILE_BYTE_ALIGNMENT) is a valid answer, not a failure.
template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::queryAlignment() {
    FILE_ALIGNMENT_INFO alignInfo{};
    if (!GetFileInformationByHandleEx(mFile, FileAlignmentInfo, &alignInfo,
                                       sizeof(alignInfo)))
        throw storageException(
            "queryAlignment: GetFileInformationByHandleEx(FileAlignmentInfo)"
            " failed: " +
            std::to_string(GetLastError()) + "\n");
    mBufferAlignmentMask = alignInfo.AlignmentRequirement;

    FILE_STORAGE_INFO storageInfo{};
    if (!GetFileInformationByHandleEx(mFile, FileStorageInfo, &storageInfo,
                                       sizeof(storageInfo)))
        throw storageException(
            "queryAlignment: GetFileInformationByHandleEx(FileStorageInfo) "
            "failed: " +
            std::to_string(GetLastError()) + "\n");
    if (storageInfo.LogicalBytesPerSector == 0)
        throw storageException(
            "queryAlignment: volume reported a logical sector size of 0\n");
    // Align writes to the physical sector, falling back to the logical sector
    // when the physical size is unknown (0) or smaller.
    const ULONGLONG logicalSector  = storageInfo.LogicalBytesPerSector;
    const ULONGLONG physicalSector = storageInfo.PhysicalBytesPerSectorForPerformance;
    mSectorSize = (physicalSector > logicalSector) ? physicalSector : logicalSector;

    mHeaderSize = computeHeaderSize();
}

// mHeaderSize only needs to be a multiple of mSectorSize -- the
// FILE_FLAG_NO_BUFFERING length requirement. The buffer-address requirement
// (mBufferAlignmentMask) is independent of size: _aligned_malloc(size,
// alignment) guarantees an aligned address for any size. mSectorSize is
// trivially a multiple of itself, so this is already sufficient.
template <typename bufferType_t>
ULONGLONG WindowsFileIO<bufferType_t>::computeHeaderSize() const {
    return mSectorSize;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::adjustToSectorSize(size_t pSectorSize) {
    // add padding if buffer size is not a multiple of the sector size of the
    // storage disk
    if (mBufferSize % pSectorSize != 0) {
        mPaddingBytes = pSectorSize - mBufferSize % pSectorSize;
        mBufferSize += mPaddingBytes;
    }

    // increment writes per buffer while block size is too large to fit into the
    // pre-configured block size
    while (static_cast<ULONGLONG>(std::ceil(mBufferSize / mWritesPerBuffer)) >
           static_cast<ULONGLONG>(ULONG_MAX)) {
        mWritesPerBuffer++;
    }

    if (mWritesPerBuffer > pSectorSize)
        throw storageException(
            "Writes per buffer exceeded the storage disk's sector size");

    // increment writes per buffer if block size is not a multiple of the sector
    // size of the storage disk
    while ((static_cast<ULONG>(std::ceil(mBufferSize / mWritesPerBuffer)) %
                pSectorSize !=
            0)  // all blocks sizes except last
           ||
           (mBufferSize -
            (mWritesPerBuffer - 1) *
                static_cast<ULONG>(std::ceil(mBufferSize / mWritesPerBuffer))) %
                   pSectorSize !=
               0) {  // last block size
        mWritesPerBuffer++;
        if (mWritesPerBuffer > pSectorSize)
            throw storageException(
                "Writes per buffer exceeded the storage disk's sector size "
                "while trying to adjust for compliance of each write block "
                "size being a multiple of the sector size");
    }
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::configureBlocksAndOffsets() {
    mBlockSize.resize(mWritesPerBuffer);
    mBlockOffset.resize(mWritesPerBuffer);
    for (int i = 0; i < mWritesPerBuffer; i++) {
        /* SIZES */
        // all blocks except last one
        if (i != mWritesPerBuffer - 1)
            mBlockSize.at(i) =
                static_cast<DWORD>(std::ceil(mBufferSize / mWritesPerBuffer));
        // last block
        else
            mBlockSize.at(i) =
                mBufferSize -
                (mWritesPerBuffer - 1) * static_cast<DWORD>(std::ceil(
                                             mBufferSize / mWritesPerBuffer));

        /* OFFSETS */
        // first block
        if (i == 0) mBlockOffset.at(i) = 0;
        // rest of blocks
        else
            mBlockOffset.at(i) = mBlockOffset.at(i - 1) +
                                 mBlockSize.at(i - 1) / sizeof(bufferType_t);
    }
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::waitForIoComplete() {
    std::vector<OVERLAPPED_ENTRY> io_results(mActiveWorkerCount);
    ULONG entries_removed;

    if (!GetQueuedCompletionStatusEx(mIocp, io_results.data(),
                                     mActiveWorkerCount, &entries_removed,
                                     INFINITE, true))
        throw storageException(
            "Error (waitForIoComplete::GetQueuedCompletionStatusEx): " +
            std::to_string(GetLastError()) + "\n");

    mActiveWorkerCount = 0;
    for (ULONG e = 0; e < entries_removed; ++e)
        onWriteCompleted(reinterpret_cast<OVERLAPPED_BUFFER *>(
            io_results[e].lpOverlapped));
    if constexpr (kUseFreeListWorkerSelection) {
        // Everything drained: every worker is free again.
        mFreeWorkers.clear();
        for (LONG w = mMaxConcurrentWrites - 1; w >= 0; --w)
            mFreeWorkers.push_back(w);
    }
    if (verbose > 1)
        std::cout << "Removed " << entries_removed
                  << " entries from completion queue\n";
}

template <typename bufferType_t>
unsigned long WindowsFileIO<bufferType_t>::dequeueNWorkers(
    unsigned long nworkers_to_remove, std::ofstream &profile_file) {
    unsigned long workers_removed = 0;

    while (mActiveWorkerCount != 0) {
        ULONG_PTR key;
        DWORD bytes_written;
        LPOVERLAPPED lpov;

        if (!GetQueuedCompletionStatus(mIocp, &bytes_written, &key, &lpov,
                                       INFINITE))
            throw storageException(
                "Error (dequeueNWorkers::GetQueuedCompletionStatusEx): " +
                std::to_string(GetLastError()) + "\n");

        profile_file << "Completed the transfer of "
                     << bytes_written / (1'024 * 1'024) << " Mbytes.\n";
        if constexpr (kUseFreeListWorkerSelection)
            mFreeWorkers.push_back(static_cast<LONG>(
                reinterpret_cast<OVERLAPPED_BUFFER *>(lpov) - mWorkers.data()));
        InterlockedDecrement(&mActiveWorkerCount);
        onWriteCompleted(reinterpret_cast<OVERLAPPED_BUFFER *>(lpov));
        workers_removed++;
        if (workers_removed == nworkers_to_remove) break;
    }
    return workers_removed;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::waitForBufferWriteComplete() {
    if (mBuffersQueued <= mBuffersDequeued)
        throw storageException(
            "Error (waitForBufferWriteComplete): no buffers to dequeue\n");

    // Anything still held has to go out first, or there is nothing to wait for.
    flushPending(true, INFINITE);

    const StorageClock::time_point blockedFrom = StorageClock::now();
    Timer timer;
    timer.start();
    for (LONG i = 0; i < mWritesPerBuffer; i++) {
        if (mActiveWorkerCount == 0) {
            throw storageException(
                "Error (waitForBufferWriteComplete): insufficient number of "
                "active workers to complete buffer write\n");
        }
        ULONG_PTR key;
        DWORD bytes_written;
        LPOVERLAPPED lpov;

        if (!GetQueuedCompletionStatus(mIocp, &bytes_written, &key, &lpov,
                                       INFINITE))
            throw storageException(
                "Error (dequeueNWorkers::GetQueuedCompletionStatusEx): " +
                std::to_string(GetLastError()) + "\n");

        if (verbose > 1)
            std::cout << "Completed the transfer of "
                      << bytes_written / (1'024 * 1'024) << " Mbytes.\n";
        if constexpr (kUseFreeListWorkerSelection)
            mFreeWorkers.push_back(static_cast<LONG>(
                reinterpret_cast<OVERLAPPED_BUFFER *>(lpov) - mWorkers.data()));
        InterlockedDecrement(&mActiveWorkerCount);
        onWriteCompleted(reinterpret_cast<OVERLAPPED_BUFFER *>(lpov));
    }
    timer.stop();
    mStats.recordBlocked(msSince(blockedFrom));
    if (verbose > 1)
        std::cout << "Waiting for single buffer storage took "
                  << timer.seconds() << " seconds.\n";

    mBuffersDequeued++;
}

template <typename bufferType_t>
OVERLAPPED_BUFFER *WindowsFileIO<bufferType_t>::getAvailableWorker(
    DWORD timeout, bool &workerDequeued) {
    OVERLAPPED_BUFFER *worker;

    if (mActiveWorkerCount < mMaxConcurrentWrites) {
        LONG free_worker;
        if constexpr (kUseFreeListWorkerSelection) {
            // The count guarantees a free slot, so the free-list must be
            // non-empty; guard anyway so an accounting desync surfaces instead
            // of UB.
            if (mFreeWorkers.empty())
                throw storageException(
                    "Error (getAvailableWorker): free-list empty but active "
                    "count below max (worker accounting desync)\n");
            free_worker = mFreeWorkers.back();
            mFreeWorkers.pop_back();
        } else {
            // Round-robin cursor, skipping any worker whose completion packet
            // has not been consumed yet. settleFinishedWrites() may have timed
            // and checked a write already, but its packet is still queued and
            // inFlight stays set until it is pulled; handing that worker out
            // again clears `settled`, and the stale packet then settles the
            // next write a second time. The active count guarantees an idle
            // worker exists, but not that the cursor is pointing at it --
            // completions are consumed in finishing order, not cursor order.
            LONG scanned = 0;
            do {
                if (mNextWorker >= mMaxConcurrentWrites) mNextWorker = 0;
                free_worker = mNextWorker;
                InterlockedIncrement(&mNextWorker);
                ++scanned;
            } while (mWorkers.at(free_worker).inFlight &&
                     scanned < mMaxConcurrentWrites);

            if (mWorkers.at(free_worker).inFlight)
                throw storageException(
                    "Error (getAvailableWorker): every worker still in flight "
                    "while the active count is below max (worker accounting "
                    "desync)\n");
        }
        InterlockedIncrement(&mActiveWorkerCount);

        if (verbose > 1) std::cout << "Using free worker\n";

        worker = &mWorkers.at(free_worker);
    }
    // All slots in flight: block for a completion (IOCP hands back the exact
    // worker via lpov) and reuse it directly. When the free-list is active it
    // never re-enters the list; the round-robin path advances past it normally.
    else {
        ULONG_PTR key;
        DWORD bytes_written;
        LPOVERLAPPED lpov;

        const StorageClock::time_point blockedFrom = StorageClock::now();
        if (!GetQueuedCompletionStatus(mIocp, &bytes_written, &key, &lpov,
                                       timeout))
            throw storageException(
                "Error (getAvailableWorker::GetQueuedCompletionStatus): " +
                std::to_string(GetLastError()) + "\n");
        mStats.recordBlocked(msSince(blockedFrom));

        if (verbose > 1)
            std::cout << "Completed the transfer of "
                      << bytes_written / (1'024 * 1'024) << " Mbytes.\n";

        worker = reinterpret_cast<OVERLAPPED_BUFFER *>(lpov);
        // Before the worker is handed out again and its fields overwritten.
        onWriteCompleted(worker);
        if (verbose > 1) std::cout << "Using dequeued worker\n";
        workerDequeued = true;
    }

    ResetEvent(worker->overlapped.hEvent);

    return worker;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::writeOverlappedBuffer(bufferType_t *buffer,
                                                        DWORD timeout) {
    // Time and check anything that has finished since the last call, before the
    // caller's producer gets a chance to refill those buffers.
    settleFinishedWrites();

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
        flushPending(false, timeout);
        return;
    }

    issueWrite(buffer, recordIndex, digest, digestBytes, queuedAt, timeout);
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::issueWrite(bufferType_t *buffer,
                                             uint64_t recordIndex,
                                             uint64_t digest,
                                             size_t digestBytes,
                                             StorageClock::time_point queuedAt,
                                             DWORD timeout) {
    bool workerDequeued = false;
    for (LONG i = 0; i < mWritesPerBuffer; i++) {
        // get worker
        OVERLAPPED_BUFFER *worker = getAvailableWorker(timeout, workerDequeued);

        // get a buffer's block to write
        ULONGLONG blockOffset = mBlockOffset.at(i);
        DWORD blockSize = mBlockSize.at(i);
        worker->buffer = &buffer[blockOffset];
        ULONGLONG offset = mHeaderSize +
                           static_cast<ULONGLONG>(recordIndex * mBufferSize) +
                           blockOffset;

        worker->queuedAt = queuedAt;
        worker->digest = digest;
        worker->digestBytes = digestBytes;
        worker->recordIndex = recordIndex;
        worker->inFlight = true;
        worker->settled = false;

        LPOVERLAPPED overlapped_ptr = &worker->overlapped;
        overlapped_ptr->Offset = offset & 0xFFFFFFFF;
        overlapped_ptr->OffsetHigh = (offset & 0xFFFFFFFF00000000) >> 32;

        WriteFile(mFile, worker->buffer, blockSize, nullptr, overlapped_ptr);

        if (GetLastError() != ERROR_IO_PENDING)
            throw storageException(
                "Error (writeOverlappedBuffer::WriteFile): " +
                std::to_string(GetLastError()) + "\n");

        mStats.writeIssued();
    }
    if (workerDequeued) mBuffersDequeued++;
}

template <typename bufferType_t>
bool WindowsFileIO<bufferType_t>::flushPending(bool all, DWORD timeout) {
    bool issued = false;
    const StorageClock::time_point now = StorageClock::now();
    while (!mPending.empty()) {
        const PendingWrite &p = mPending.front();
        if (!all && p.releaseAt > now) break;
        PendingWrite held = p;
        mPending.pop_front();
        issueWrite(static_cast<bufferType_t *>(held.buffer), held.recordIndex,
                   held.digest, held.digestBytes, held.queuedAt, timeout);
        issued = true;
    }
    return issued;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::onWriteCompleted(OVERLAPPED_BUFFER *worker) {
    mStats.writeCompleted();
    if (worker == nullptr) return;

    // Already timed and checked by settleFinishedWrites(); this call is only
    // here to keep the outstanding count straight.
    if (worker->settled) {
        worker->settled = false;
        worker->inFlight = false;
        return;
    }
    settleWrite(*worker);
    worker->inFlight = false;
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::settleWrite(OVERLAPPED_BUFFER &worker) {
    // Nothing polls for completion once storeBuffer stops being called, so a
    // write still open at the final drain is first noticed there -- possibly
    // long after it finished. Timing that would put the wait for the drain into
    // the write latency, so those are counted without it.
    if (mFinalDrain) {
        mStats.recordCompletedUntimed();
    } else {
        mStats.recordLatency(
            std::chrono::duration<double, std::milli>(StorageClock::now() -
                                                      worker.queuedAt)
                .count());
    }

    // A changed digest means the producer refilled the buffer while the disk
    // was still reading it, so the record that just landed is two frames mixed.
    if (storageDebugFlags().verify && worker.digestBytes > 0) {
        const uint64_t now = probeDigest(worker.buffer, worker.digestBytes,
                                         storageDebugFlags().probes);
        ++mStats.verified;
        if (now != worker.digest) {
            mStats.recordCorrupt(worker.recordIndex);
            std::cerr << "[storage] " << mStreamLabel << ": record "
                      << worker.recordIndex
                      << " changed while its write was in flight -- stored data "
                         "is corrupt.\n";
        }
    }
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::settleFinishedWrites() {
    for (auto &w : mWorkers) {
        if (!w.inFlight || w.settled) continue;
        if (!HasOverlappedIoCompleted(&w.overlapped)) continue;
        settleWrite(w);
        w.settled = true;
    }
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::reportStats() const {
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

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::writeToHeader() {
    // mHeaderSize (set by queryAlignment()/computeHeaderSize()) is a
    // multiple of mSectorSize, satisfying FILE_FLAG_NO_BUFFERING's
    // write-length requirement; _aligned_malloc(..., memAlign) separately
    // guarantees the buffer address is aligned, independent of size.
    const ULONGLONG memAlign =
        static_cast<ULONGLONG>(mBufferAlignmentMask) + 1;
    void *raw = _aligned_malloc(static_cast<size_t>(mHeaderSize),
                                static_cast<size_t>(memAlign));
    if (raw == nullptr)
        throw storageException("writeToHeader: _aligned_malloc failed\n");
    std::unique_ptr<void, decltype(&_aligned_free)> headerGuard(
        raw, &_aligned_free);

    char *header = static_cast<char *>(raw);
    ZeroMemory(header, mHeaderSize);

    // Write fixed header fields (each 8 bytes)
    uint64_t *header_fields = reinterpret_cast<uint64_t *>(header);
    header_fields[0] = mVersion;
    header_fields[1] = mHeaderSize;
    header_fields[2] = mBuffersDequeued;
    header_fields[3] = (mBufferSize - mPaddingBytes) / sizeof(bufferType_t);
    header_fields[4] = mPaddingBytes;
    header_fields[5] = mDataTypeCode;

    // Prepare an OVERLAPPED_BUFFER to write the entire header
    OVERLAPPED_BUFFER worker{};
    ZeroMemory(&worker.overlapped, sizeof(OVERLAPPED));
    worker.overlapped.hEvent = CreateEvent(nullptr, true, false, nullptr);
    worker.buffer = header;

    // Write header at offset 0
    LPOVERLAPPED overlapped_ptr = &worker.overlapped;
    overlapped_ptr->Offset = 0;
    overlapped_ptr->OffsetHigh = 0;

    WriteFile(mFile, worker.buffer, static_cast<DWORD>(mHeaderSize), nullptr,
              overlapped_ptr);
    if (GetLastError() != ERROR_IO_PENDING)
        throw storageException("Error (writeToHeader::WriteFile): " +
                               std::to_string(GetLastError()) + "\n");

    // Wait for completion (simplified)
    ULONG_PTR key;
    DWORD bytes_written;
    LPOVERLAPPED lpov;
    if (!GetQueuedCompletionStatus(mIocp, &bytes_written, &key, &lpov,
                                   INFINITE))
        throw storageException(
            "Error (writeToHeader::GetQueuedCompletionStatus): " +
            std::to_string(GetLastError()) + "\n");

    if (verbose > 1)
        std::cout << "Header: Completed the transfer of " << bytes_written
                  << " bytes.\n";
}

template <typename bufferType_t>
void WindowsFileIO<bufferType_t>::completeRemainingWrites() {
    mFinalDrain = true;
    flushPending(true, INFINITE);
    if (mBuffersQueued > mBuffersDequeued) {
        const unsigned long nBuffers = mBuffersQueued - mBuffersDequeued;
        for (unsigned long i = 0; i < nBuffers; i++) {
            waitForBufferWriteComplete();
        }
    }
}
}  // namespace Storage
