/**
 * @file cuda_error.h
 * @author BrainEcho Lab
 * @brief CUDA Error Handling Utilities
 * @details This header provides exception classes, macros, and helper functions
 * for robust CUDA, cuBLAS, cuFFT, cuSPARSE, and cuSOLVER error checking and
 * reporting. It enables consistent error handling and descriptive exception
 * messages for GPU operations throughout the EchoFrame codebase.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <stdexcept>
#include <string>

#include <cublas_v2.h>
#include <cuda.h>
#include <cufft.h>
#include <cusolverDn.h>
#include <cusparse.h>

/**
 * @brief Exception class for CUDA-related errors.
 */
class cudaException : public std::runtime_error {
   public:
    /**
     * @brief Construct a new cudaException object.
     * @param msg Error message string.
     */
    explicit cudaException(const std::string &msg) : std::runtime_error(msg) {};
};

/**
 * @brief Macro for checking CUDA errors and throwing exceptions.
 */
#define gpuErrchk(ans)                        \
    {                                         \
        gpuAssert((ans), __FILE__, __LINE__); \
    }

/**
 * @brief Checks CUDA error codes and throws cudaException on failure.
 * @param code CUDA error code.
 * @param file Source file name.
 * @param line Source line number.
 * @param abort Whether to abort on error (default: true).
 */
inline void gpuAssert(cudaError_t code, const char *file, int line,
                      bool abort = true) {
    if (code != cudaSuccess) {
        throw cudaException(
            "CUDA error in file " + std::string(file) + " line " +
            std::to_string(line) + "\n Error " + std::to_string(code) + " : " +
            std::string(cudaGetErrorString(code)) + "\nterminating!\n");
    }
}

/**
 * @brief Returns a string representation of a cuFFT error code.
 * @param error cuFFT error code.
 * @return const char* Error string.
 */
static const char *cudaGetErrorEnum(cufftResult error) {
    switch (error) {
        case CUFFT_SUCCESS:
            return "CUFFT_SUCCESS";

        case CUFFT_INVALID_PLAN:
            return "CUFFT_INVALID_PLAN";

        case CUFFT_ALLOC_FAILED:
            return "CUFFT_ALLOC_FAILED";

        case CUFFT_INVALID_TYPE:
            return "CUFFT_INVALID_TYPE";

        case CUFFT_INVALID_VALUE:
            return "CUFFT_INVALID_VALUE";

        case CUFFT_INTERNAL_ERROR:
            return "CUFFT_INTERNAL_ERROR";

        case CUFFT_EXEC_FAILED:
            return "CUFFT_EXEC_FAILED";

        case CUFFT_SETUP_FAILED:
            return "CUFFT_SETUP_FAILED";

        case CUFFT_INVALID_SIZE:
            return "CUFFT_INVALID_SIZE";

        case CUFFT_UNALIGNED_DATA:
            return "CUFFT_UNALIGNED_DATA";

        case CUFFT_INVALID_DEVICE:
            return "CUFFT_INVALID_DEVICE";

        case CUFFT_NO_WORKSPACE:
            return "CUFFT_NO_WORKSPACE";

        case CUFFT_NOT_IMPLEMENTED:
            return "CUFFT_NOT_IMPLEMENTED";

        case CUFFT_NOT_SUPPORTED:
            return "CUFFT_NOT_SUPPORTED";
        default:
            return "<unknown>";
    }
}

/**
 * @brief Returns a string representation of a cuBLAS error code.
 * @param status cuBLAS status code.
 * @return const char* Error string.
 */
static const char *cublasGetErrorEnum(cublasStatus_t status) {
    switch (status) {
        case CUBLAS_STATUS_SUCCESS:
            return "CUBLAS_STATUS_SUCCESS";

        case CUBLAS_STATUS_NOT_INITIALIZED:
            return "CUBLAS_STATUS_NOT_INITIALIZED";

        case CUBLAS_STATUS_ALLOC_FAILED:
            return "CUBLAS_STATUS_ALLOC_FAILED";

        case CUBLAS_STATUS_INVALID_VALUE:
            return "CUBLAS_STATUS_INVALID_VALUE";

        case CUBLAS_STATUS_ARCH_MISMATCH:
            return "CUBLAS_STATUS_ARCH_MISMATCH";

        case CUBLAS_STATUS_MAPPING_ERROR:
            return "CUBLAS_STATUS_MAPPING_ERROR";

        case CUBLAS_STATUS_EXECUTION_FAILED:
            return "CUBLAS_STATUS_EXECUTION_FAILED";

        case CUBLAS_STATUS_INTERNAL_ERROR:
            return "CUBLAS_STATUS_INTERNAL_ERROR";

        case CUBLAS_STATUS_NOT_SUPPORTED:
            return "CUBLAS_STATUS_NOT_SUPPORTED";

        case CUBLAS_STATUS_LICENSE_ERROR:
            return "CUBLAS_STATUS_LICENSE_ERROR";
    }

    return "<unknown>";
}

/**
 * @brief Macro for checking cuFFT errors and throwing exceptions.
 */
#define cufftErrchk(ans)                          \
    {                                             \
        cufftSafeCall((ans), __FILE__, __LINE__); \
    }

/**
 * @brief Checks cuFFT error codes and throws cudaException on failure.
 * @param status cuFFT status code.
 * @param file Source file name.
 * @param line Source line number.
 */
inline void cufftSafeCall(cufftResult status, const char *file,
                          const int line) {
    if (CUFFT_SUCCESS != status) {
        throw cudaException(
            "CUFFT error in file " + std::string(file) + " line " +
            std::to_string(line) + "\n Error " + std::to_string(status) +
            " : " + std::string(cudaGetErrorEnum(status)) + "\nterminating!\n");
    }
}

/**
 * @brief Macro for checking cuBLAS errors and throwing exceptions.
 */
#define cublasErrchk(ans)                          \
    {                                              \
        cublasSafeCall((ans), __FILE__, __LINE__); \
    }

/**
 * @brief Checks cuBLAS error codes and throws cudaException on failure.
 * @param status cuBLAS status code.
 * @param file Source file name.
 * @param line Source line number.
 */
inline void cublasSafeCall(cublasStatus_t status, const char *file,
                           const int line) {
    if (CUBLAS_STATUS_SUCCESS != status) {
        throw cudaException("CUBLAS error in file " + std::string(file) +
                            " line " + std::to_string(line) + "\n Error " +
                            std::to_string(status) + " : " +
                            std::string(cublasGetErrorEnum(status)) +
                            "\nterminating!\n");
    }
}

/**
 * @brief Returns a string representation of a cuSPARSE error code.
 * @param status cuSPARSE status code.
 * @return const char* Error string.
 */
static const char *cusparseGetErrorEnum(cusparseStatus_t status) {
    switch (status) {
        case CUSPARSE_STATUS_SUCCESS:
            return "CUSPARSE_STATUS_SUCCESS";

        case CUSPARSE_STATUS_NOT_INITIALIZED:
            return "CUSPARSE_STATUS_NOT_INITIALIZED";

        case CUSPARSE_STATUS_ALLOC_FAILED:
            return "CUSPARSE_STATUS_ALLOC_FAILED";

        case CUSPARSE_STATUS_INVALID_VALUE:
            return "CUSPARSE_STATUS_INVALID_VALUE";

        case CUSPARSE_STATUS_ARCH_MISMATCH:
            return "CUSPARSE_STATUS_ARCH_MISMATCH";

        case CUSPARSE_STATUS_MAPPING_ERROR:
            return "CUSPARSE_STATUS_MAPPING_ERROR";

        case CUSPARSE_STATUS_EXECUTION_FAILED:
            return "CUSPARSE_STATUS_EXECUTION_FAILED";

        case CUSPARSE_STATUS_INTERNAL_ERROR:
            return "CUSPARSE_STATUS_INTERNAL_ERROR";

        case CUSPARSE_STATUS_MATRIX_TYPE_NOT_SUPPORTED:
            return "CUSPARSE_STATUS_MATRIX_TYPE_NOT_SUPPORTED";

        case CUSPARSE_STATUS_ZERO_PIVOT:
            return "CUSPARSE_STATUS_ZERO_PIVOT";
        default:
            return "<unknown>";
    }
}

/**
 * @brief Macro for checking cuSPARSE errors and throwing exceptions.
 */
#define cusparseErrchk(ans)                          \
    {                                                \
        cusparseSafeCall((ans), __FILE__, __LINE__); \
    }

/**
 * @brief Checks cuSPARSE error codes and throws cudaException on failure.
 * @param status cuSPARSE status code.
 * @param file Source file name.
 * @param line Source line number.
 */
inline void cusparseSafeCall(cusparseStatus_t status, const char *file,
                             const int line) {
    if (CUSPARSE_STATUS_SUCCESS != status) {
        throw cudaException("CUSPARSE error in file " + std::string(file) +
                            " line " + std::to_string(line) + "\n Error " +
                            std::to_string(status) + " : " +
                            std::string(cusparseGetErrorEnum(status)) +
                            "\nterminating!\n");
    }
}

/**
 * @brief Returns a string representation of a cuSOLVER error code.
 * @param status cuSOLVER status code.
 * @return const char* Error string.
 */
static const char *cusolverGetErrorEnum(cusolverStatus_t status) {
    switch (status) {
        case CUSOLVER_STATUS_SUCCESS:
            return "CUSOLVER_STATUS_SUCCESS";
        case CUSOLVER_STATUS_NOT_INITIALIZED:
            return "CUSOLVER_STATUS_NOT_INITIALIZED";
        case CUSOLVER_STATUS_ALLOC_FAILED:
            return "CUSOLVER_STATUS_ALLOC_FAILED";
        case CUSOLVER_STATUS_INVALID_VALUE:
            return "CUSOLVER_STATUS_INVALID_VALUE";
        case CUSOLVER_STATUS_ARCH_MISMATCH:
            return "CUSOLVER_STATUS_ARCH_MISMATCH";
        case CUSOLVER_STATUS_MAPPING_ERROR:
            return "CUSOLVER_STATUS_MAPPING_ERROR";
        case CUSOLVER_STATUS_EXECUTION_FAILED:
            return "CUSOLVER_STATUS_EXECUTION_FAILED";
        case CUSOLVER_STATUS_INTERNAL_ERROR:
            return "CUSOLVER_STATUS_INTERNAL_ERROR";
        case CUSOLVER_STATUS_MATRIX_TYPE_NOT_SUPPORTED:
            return "CUSOLVER_STATUS_MATRIX_TYPE_NOT_SUPPORTED";
        case CUSOLVER_STATUS_NOT_SUPPORTED:
            return "CUSOLVER_STATUS_NOT_SUPPORTED";
        case CUSOLVER_STATUS_ZERO_PIVOT:
            return "CUSOLVER_STATUS_ZERO_PIVOT";
        case CUSOLVER_STATUS_INVALID_LICENSE:
            return "CUSOLVER_STATUS_INVALID_LICENSE";
        default:
            return "<unknown>";
    }
}

/**
 * @brief Macro for checking cuSOLVER errors and throwing exceptions.
 */
#define cusolverErrchk(ans)                          \
    {                                                \
        cusolverSafeCall((ans), __FILE__, __LINE__); \
    }

/**
 * @brief Checks cuSOLVER error codes and throws cudaException on failure.
 * @param status cuSOLVER status code.
 * @param file Source file name.
 * @param line Source line number.
 */
inline void cusolverSafeCall(cusolverStatus_t status, const char *file,
                             const int line) {
    if (CUSOLVER_STATUS_SUCCESS != status) {
        throw cudaException("CUSOLVER error in file " + std::string(file) +
                            " line " + std::to_string(line) + "\n Error " +
                            std::to_string(status) + " : " +
                            std::string(cusolverGetErrorEnum(status)) +
                            "\nterminating!\n");
    }
}
