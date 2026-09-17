# cuda/

This directory contains CUDA utility headers for the EchoFrame system, providing robust error handling and GPU timing utilities to support high-performance and reliable GPU computation performance measurements.

## Directory Structure

### Files

- **cuda_error.h**
  - Provides exception classes, macros, and helper functions for robust error checking and reporting with CUDA, cuBLAS, cuFFT, cuSPARSE, and cuSOLVER. Includes macros for error checking (`gpuErrchk`, `cufftErrchk`, `cublasErrchk`, `cusparseErrchk`, `cusolverErrchk`) and functions for converting error codes to human-readable strings. Ensures consistent and descriptive error handling for all GPU operations.

- **cuda_event_timer.hpp**
  - Defines the `CudaEventTimer` class, a utility for timing CUDA GPU operations using named event pairs. Supports multiple timing stages, elapsed time queries, and automatic resource cleanup. Used for detailed performance profiling of different stages in the EchoFrame processing pipeline.

## Usage

Include these headers in modules that require GPU error checking or performance profiling. Use `CudaEventTimer` to measure and profile the duration of GPU operations, and use the error checking macros to ensure robust and informative error handling for all CUDA and related library calls.
