//
// Created by petros on 12/17/2021.
//

#ifndef CUBE_STORAGE_HANDLER_H
#define CUBE_STORAGE_HANDLER_H

#ifdef _WIN32
#include "Windows/WindowsFileIO.t.hpp"
#elif defined(__linux__)
#include "Linux/LinuxFileIO.t.hpp"
#endif

#include <fstream>
#include <mutex>
#include <vector>

#include "../utils/Timer.h"
#include "storage_spec.h"
#include "write_stats.h"

#define WRITES_PER_BUFFER 1
#define EXTEND_FILE_STEP 10

#define STORAGE_ERROR_NO_ERROR 0
#define STORAGE_ERROR_OPEN_FILE 1
#define STORAGE_ERROR_FILE_ALREADY_OPEN 2
#define STORAGE_ERROR_WRITE_BUFFER 3
#define STORAGE_ERROR_INVALID_PRIVILEGE 4
#define STORAGE_ERROR_NO_BUFFER_AVAILABLE 5
#define STORAGE_ERROR_WRITE_BUSY 6
#define STORAGE_ERROR_FILE_NOT_OPEN 7
#define STORAGE_ERROR_EXTEND_FILE 8

namespace Storage {
static bool PRIVILEDGES_ASSIGNED{false};

enum DataTypeCode : uint64_t {
    DT_UNKNOWN = 0,
    DT_INT16 = 1,
    DT_SINGLE = 2,
    DT_COMPLEX_SINGLE = 3,
    DT_DOUBLE = 4,
    DT_COMPLEX_DOUBLE = 5,
    DT_BFLOAT = 6,
    DT_BFLOAT_COMPLEX = 7
};

/// Bytes one stored element occupies, as the header describes it. Readers take
/// the stride from this, so it has to match the buffer the handler writes.
/// 0 for a code whose width is not known.
inline size_t dataTypeBytes(DataTypeCode code) {
    switch (code) {
        case DT_INT16: return 2;
        case DT_SINGLE: return 4;
        case DT_COMPLEX_SINGLE: return 8;
        case DT_DOUBLE: return 8;
        case DT_COMPLEX_DOUBLE: return 16;
        case DT_BFLOAT: return 2;
        case DT_BFLOAT_COMPLEX: return 4;
        default: return 0;
    }
}

template <typename bufferType_t>
class Handler {
   private:
    /*
     * Naming convention for each variable
     * member variable: mVar
     * parameter variable: pVar
     * bool / ofstream / mutex / condition_variable / timer : _flag / _file /
     * _mtx / _cv / _timer suffix
     */
    std::string mStoragePath;
    std::string mDataType;
    DataTypeCode mDataTypeCode;
    unsigned long long
        mBufferSize;   // buffer size (bytes) + padding (if needed)
    int mMaxNBuffers;  // max number of buffers to store
    int mCurrentMaxNBuffers{
        0};                 // current number of buffers which fit into file
    int mNWritesPerBuffer;  // max number of writing segments per buffer,
                            // defines the block size
    int mNConcBuffers;      // number of concurrent buffers being written
    int mNBuffers;          // number of buffers in the array of buffers
    const bufferType_t **mBuffers;     // array of buffers to store
    int mBuffersQueued;                // number of buffers queued for storage
    bool mCrop{false};                 // store cropped or not
    bool mPreallocateFullFile{false};  // pre-allocate full file

#ifdef _WIN32
    WindowsFileIO<bufferType_t> mStorageFile;
#elif defined(__linux__)
    LinuxFileIO<bufferType_t> mStorageFile;
#endif
    int mLastError = STORAGE_ERROR_NO_ERROR;  // last error during Handler

    int verbose{1};
    bool mInitialized{false};
    bool mCapReported{false};  // the max-buffers message prints once

    /**
     * @brief Decode datatype string into uint values for header
     *
     */
    DataTypeCode decodeDataType(const std::string &dataTypeStr);

   public:
    Handler() = default;

    Handler(std::string &pFilepath, std::string &pDataType, size_t pBufferSize,
            int pWritesPerBuffer, int pMaxNBuffers, int pNBuffers, bool pCrop,
            bool preallocateFullFile);

    ~Handler();

    Handler(Handler &&) noexcept;             // move-constructor
    Handler &operator=(Handler &&) noexcept;  // move-assignment

    /**
     * @brief Re-initialize storage save file location
     */
    void switchFile();

    /**
     * @brief Assign admin priviledges for writing to files, makes extending the
     * files more efficient
     */
    static void assignPriviledges();

    /**
     * @brief Open a file
     * @param pFilepath file path
     */
    void openFile(std::string &pFilepath);

    /**
     * @brief Extend a file
     */
    void extendFile();

    /**
     * @brief Store a buffer
     * @param pBuffer buffer
     */
    void storeBuffer(const bufferType_t *pBuffer);

    /**
     * @return Last error
     */
    [[nodiscard]] int getLastError() const;

    /**
     * @brief Complete every write still in flight.
     * @details The disk reads directly from the buffers storeBuffer was given,
     * so those buffers must outlive their writes. Call this before freeing
     * them; the destructor would otherwise be the first point at which the
     * writes are waited on, which is too late if the producer is torn down
     * first. Idempotent.
     */
    void finishWrites() {
        if (mInitialized) mStorageFile.completeRemainingWrites();
    }

    /**
     * @return Write instrumentation, empty when no file is open.
     */
    [[nodiscard]] WriteStats getWriteStats() const {
        if (!mInitialized) return WriteStats{};
        return mStorageFile.stats();
    }

    /**
     * @return Buffers handed to storeBuffer so far. Diverging counts between
     * streams mean their record indices no longer line up.
     */
    [[nodiscard]] int getBuffersQueued() const { return mBuffersQueued; }

    /**
     * @brief Begin writing to file
     */
    void initiateStorage();
};
}  // namespace Storage

#endif  // CUBE_STORAGE_HANDLER_H
