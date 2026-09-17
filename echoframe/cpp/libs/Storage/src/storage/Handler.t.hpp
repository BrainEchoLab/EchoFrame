//
// Created by petros on 12/17/2021.
//

#include "Handler.h"

#include <condition_variable>

#include "error.h"

namespace Storage {
template <typename bufferType_t>
Handler<bufferType_t>::Handler(std::string &pFilepath, std::string &pDataType,
                               size_t pBufferSize, int pWritesPerBuffer,
                               int pMaxNBuffers, int pNBuffers, bool pCrop,
                               bool preallocateFullFile) {
    // storage variables
    mMaxNBuffers = pMaxNBuffers;
    mNWritesPerBuffer = pWritesPerBuffer;
    mNBuffers = pNBuffers;
    if (mNBuffers <= 1) mNBuffers = 2;
    mNConcBuffers =
        mNBuffers - 1;  // number of instances being stored concurrently
    mBuffersQueued = 0;

    // buffer
    mBufferSize = pBufferSize;
    mBuffers = static_cast<const bufferType_t **>(
        malloc(mNBuffers * sizeof(bufferType_t *)));

    // crop
    mCrop = pCrop;

    mPreallocateFullFile = preallocateFullFile;

    // priviledges
    assignPriviledges();

    // Open File
    mStoragePath = pFilepath;
    mDataType = pDataType;
    mDataTypeCode = decodeDataType(mDataType);

    // A reader takes its stride from the header's type code, so it has to match
    // what this handler writes; a narrower one reads back a partial recording.
    const size_t declaredBytes = dataTypeBytes(mDataTypeCode);
    if (declaredBytes == 0)
        throw storageException("Error (Handler): unknown dataType '" +
                               mDataType + "'\n");
    if (declaredBytes != sizeof(bufferType_t))
        throw storageException(
            "Error (Handler): dataType '" + mDataType + "' describes " +
            std::to_string(declaredBytes) + " bytes per element, but this " +
            "stream writes " + std::to_string(sizeof(bufferType_t)) +
            ". The header would misdescribe the file.\n");

    openFile(mStoragePath);

    extendFile();
    mInitialized = true;
}

template <typename bufferType_t>
Handler<bufferType_t>::~Handler() {
    if (verbose > 1) std::cout << "\n\nDestroying Handler!\n";

    if (mInitialized) {
        if (mBuffers) free(mBuffers);
    }
}

template <typename bufferType_t>
Handler<bufferType_t>::Handler(Handler &&x) noexcept {
    // storage variables
    mStoragePath = x.mStoragePath;
    mDataType = x.mDataType;
    mMaxNBuffers = x.mMaxNBuffers;
    mCurrentMaxNBuffers = x.mCurrentMaxNBuffers;
    mNWritesPerBuffer = x.mNWritesPerBuffer;
    mNBuffers = x.mNBuffers;
    mNConcBuffers = x.mNConcBuffers;
    mNWritesPerBuffer = x.mNWritesPerBuffer;
    mBuffersQueued = x.mBuffersQueued;

    // buffer
    mBufferSize = x.mBufferSize;
    if (mInitialized && mBuffers) free(mBuffers);
    mBuffers = x.mBuffers;
    x.mBuffers = nullptr;

    // crop
    mCrop = x.mCrop;

    // Pre-allocate full file flag
    mPreallocateFullFile = x.mPreallocateFullFile;

    // storage file
#if defined(_WIN32) || defined(__linux__)
    mStorageFile = std::move(x.mStorageFile);
#endif  // _WIN32 || __linux__

    mInitialized = x.mInitialized;
    x.mInitialized = false;
}

template <typename bufferType_t>
Handler<bufferType_t> &Handler<bufferType_t>::operator=(Handler &&x) noexcept {
    // storage variables
    mStoragePath = x.mStoragePath;
    mDataType = x.mDataType;
    mMaxNBuffers = x.mMaxNBuffers;
    mCurrentMaxNBuffers = x.mCurrentMaxNBuffers;
    mNWritesPerBuffer = x.mNWritesPerBuffer;
    mNBuffers = x.mNBuffers;
    mNConcBuffers = x.mNConcBuffers;
    mNWritesPerBuffer = x.mNWritesPerBuffer;
    mBuffersQueued = x.mBuffersQueued;

    // buffer
    mBufferSize = x.mBufferSize;
    if (mInitialized && mBuffers) free(mBuffers);
    mBuffers = x.mBuffers;
    x.mBuffers = nullptr;

    // crop
    mCrop = x.mCrop;

    // Copying preallocateFullFile
    mPreallocateFullFile = x.mPreallocateFullFile;

    // storage file
#if defined(_WIN32) || defined(__linux__)
    mStorageFile = std::move(x.mStorageFile);
#endif  // _WIN32 || __linux__

    mInitialized = x.mInitialized;
    x.mInitialized = false;

    return *this;
}

template <typename bufferType_t>
void Handler<bufferType_t>::switchFile() {
    // reset file-dependent fields
    mCurrentMaxNBuffers = 0;
    mBuffersQueued = 0;
    mCapReported = false;

    openFile(mStoragePath);
    extendFile();

    mInitialized = true;
}

template <typename bufferType_t>
void Handler<bufferType_t>::assignPriviledges() {
    if (!PRIVILEDGES_ASSIGNED) {
        try {
#ifdef _WIN32
            WindowsFileIO<bufferType_t>::assignPrivileges();
#elif defined(__linux__)
            LinuxFileIO<bufferType_t>::assignPrivileges();
#endif  // _WIN32 || __linux__
            PRIVILEDGES_ASSIGNED = true;
        } catch (storageException &e) {
            std::cerr << e.what();
            std::terminate();
        }
    }
}

template <typename bufferType_t>
void Handler<bufferType_t>::openFile(std::string &pFilepath) {
    Timer timer_open_file;
    timer_open_file.start();
    try {
        // this calls the move-constructor rather than the copy-constructor
        // because copy-constructor is undefined
#ifdef _WIN32
        mStorageFile = std::move(WindowsFileIO<bufferType_t>(
            pFilepath, mBufferSize, mNWritesPerBuffer, mNConcBuffers,
            mDataTypeCode));
#elif defined(__linux__)
        mStorageFile = std::move(
            LinuxFileIO<bufferType_t>(pFilepath, mBufferSize, mNWritesPerBuffer,
                                      mNConcBuffers, mDataTypeCode));
#endif  // _WIN32 || __linux__
    } catch (storageException &e) {
        std::cerr << e.what();
        exit(EXIT_FAILURE);
    }
    timer_open_file.stop();
    auto time_open_file = timer_open_file.seconds();
    if (verbose > 1)
        std::cout << "Opening file took " << std::to_string(time_open_file)
                  << " seconds\n";
}

template <typename bufferType_t>
void Handler<bufferType_t>::extendFile() {
    if (mCurrentMaxNBuffers >= mMaxNBuffers)
        return;  // Skip if fully preallocated

    Timer timer_extend_file;
    timer_extend_file.start();

#if defined(_WIN32) || defined(__linux__)
    mStorageFile.extendFileHeader();
#endif  // _WIN32 || __linux__
    try {
        int step = EXTEND_FILE_STEP;
        // Check if we should extend to the full file size immediately
        if (mPreallocateFullFile) {
            step = mMaxNBuffers - mCurrentMaxNBuffers;
            mCurrentMaxNBuffers = mMaxNBuffers;
        } else {
            mCurrentMaxNBuffers += step;
            if (mCurrentMaxNBuffers > mMaxNBuffers) {
                step = EXTEND_FILE_STEP - (mCurrentMaxNBuffers - mMaxNBuffers);
                mCurrentMaxNBuffers = mMaxNBuffers;
            }
        }
#if defined(_WIN32) || defined(__linux__)
        mStorageFile.extendFile(step);
#endif  // _WIN32 || __linux__
    } catch (storageException &e) {
        std::cerr << e.what();
        std::terminate();
    }

    timer_extend_file.stop();
    auto time_extend_file = timer_extend_file.seconds();
    unsigned int extended_file_size =
        mBufferSize * mCurrentMaxNBuffers / (1'024 * 1'024);
    if (verbose > 1) {
        std::cout << "Extending file ("
                  << std::to_string(extended_file_size * sizeof(bufferType_t))
                  << " MB) took " << std::to_string(time_extend_file)
                  << " seconds\n";
    }
}

template <typename bufferType_t>
void Handler<bufferType_t>::storeBuffer(const bufferType_t *pBuffer) {
    if (!mInitialized)
        throw storageException("Storage buffer not initialized. Cannot store");

    // Queued more buffers than were pre-allocated. Only this stream stops, so
    // say so -- otherwise its record indices silently drift out of step with
    // the streams that are still recording.
    if (mBuffersQueued >= mMaxNBuffers) {
        if (!mCapReported) {
            mCapReported = true;
            std::cerr << "[storage] " << mStoragePath << ": reached maxNBuffers ("
                      << mMaxNBuffers
                      << "); every further frame is dropped from THIS stream "
                         "only, so its record indices no longer line up with "
                         "the other streams.\n"
                      << std::flush;
        }
        // Keep draining. Returning outright leaves the last writes pending
        // until the file closes, and their source buffers are reused long
        // before then.
#if defined(_WIN32) || defined(__linux__)
        if (mStorageFile.mBuffersQueued > mStorageFile.mBuffersDequeued)
            mStorageFile.waitForBufferWriteComplete();
#endif  // _WIN32 || __linux__
        return;
    }

    if (mBuffersQueued >= mCurrentMaxNBuffers) {
        try {
            int step = EXTEND_FILE_STEP;
            mCurrentMaxNBuffers += step;
            if (mCurrentMaxNBuffers >= mMaxNBuffers) {
                step = EXTEND_FILE_STEP - (mCurrentMaxNBuffers - mMaxNBuffers);
                mCurrentMaxNBuffers = mMaxNBuffers;
            }
#if defined(_WIN32) || defined(__linux__)
            mStorageFile.extendFile(step);
#endif  // _WIN32 || __linux__
        } catch (storageException &e) {
            std::cerr << e.what();
            std::terminate();
        }
    }

    int bufferPos = mBuffersQueued % mNBuffers;
    // assign the already allocated buffer to mBuffers
    mBuffers[bufferPos] = pBuffer;

    Timer timer;
    timer.start();
    // store buffer
    initiateStorage();
    mBuffersQueued++;  // increment number of data queued for storage

    timer.stop();
    if (verbose > 1)
        std::cout << "Queuing buffer storage took " << timer.seconds()
                  << " seconds.\n";

    timer.start();

    // wait for completion of a single buffer write
    if (mBuffersQueued >= mNConcBuffers) {
        try {
#if defined(_WIN32) || defined(__linux__)
            mStorageFile.waitForBufferWriteComplete();
#endif  // _WIN32 || __linux__
        } catch (std::ios_base::failure &failure) {
            std::cerr << failure.what();
            std::terminate();
        }
    }

    timer.stop();
}

template <typename bufferType_t>
int Handler<bufferType_t>::getLastError() const {
    return mLastError;
}

template <typename bufferType_t>
void Handler<bufferType_t>::initiateStorage() {
    {
#ifdef _WIN32
        mStorageFile.writeOverlappedBuffer(
            const_cast<bufferType_t *>(
                mBuffers[(mStorageFile.mBuffersQueued) % mNBuffers]),
            INFINITE);
#elif defined(__linux__)
        mStorageFile.writeOverlappedBuffer(
            const_cast<bufferType_t *>(
                mBuffers[(mStorageFile.mBuffersQueued) % mNBuffers]),
            -1);
#endif  // _WIN32 || __linux__
    }
}

template <typename bufferType_t>
DataTypeCode Handler<bufferType_t>::decodeDataType(
    const std::string &dataTypeStr) {
    if (dataTypeStr == "int16") {
        return DT_INT16;
    } else if (dataTypeStr == "single") {
        return DT_SINGLE;
    } else if (dataTypeStr == "complex single") {
        return DT_COMPLEX_SINGLE;
    } else if (dataTypeStr == "double") {
        return DT_DOUBLE;
    } else if (dataTypeStr == "complex double") {
        return DT_COMPLEX_DOUBLE;
    } else if (dataTypeStr == "bfloat") {
        return DT_BFLOAT;
    } else if (dataTypeStr == "bfloat complex") {
        return DT_BFLOAT_COMPLEX;
    } else {
        return DT_UNKNOWN;  // unknown data type
    }
}
}  // namespace Storage
