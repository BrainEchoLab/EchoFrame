/**
 * @file pdi_class.cu
 * @author BrainEcho Lab
 * @brief PDI class implementation.
 * @details This file contains the implementation of the PDI class, which
 * performs Power Doppler Imaging (PDI) on beamformed data using CUDA.
 * It includes methods for SVD and covariance eigenvalue decomposition, as well
 * as memory management and data transfer between host and device.
 * @version 0.1
 * @date 2025-02-03
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "pdi_class.cuh"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

#include "../cuda/cuda_error.h"

namespace PDI {
PDI::PDI(PDISpec pPdiSpec, Beamform::ReceiveSpec pReceiveSpec,
         Beamform::ReconSpec pReconSpec, bool externalBF)
    : pdiSpec(pPdiSpec),
      receiveSpec(pReceiveSpec),
      reconSpec(pReconSpec),
      externalBFAlloc(externalBF),
      // Initialize pointers to nullptr
      cusolverHandle(nullptr),
      cusolverParams(NULL),
      offset_ptr(nullptr),
      d_mean_offset(nullptr),
      d_U(nullptr),
      d_VT(nullptr),
      d_S(nullptr),
      d_info(nullptr),
      d_US(nullptr),
      d_S_complex(nullptr),
      d_mean_cropped(nullptr),
      d_info_dp(nullptr),
      d_cov(nullptr),
      d_U_cov(nullptr),
      d_VT_cov(nullptr),
      d_S_cov(nullptr),
      d_S_reduced_cov(nullptr),
      d_work_eig(nullptr),
      d_info_eig(nullptr),
      d_A_reconstructed(nullptr),
      d_abs_A(nullptr),
      d_weights(nullptr),
      d_mean(nullptr),
      h_err_sigma(nullptr),
      h_mean(nullptr),
      h_mean_cropped(nullptr),
      d_externalBeamformedData(nullptr),
      h_externalBeamformedDataPinned(nullptr),
      // Initialize other members
      alpha(make_float2(1.0f, 0.0f)),
      beta(make_float2(0.0f, 0.0f)),
      alpha_mean(0.0f),
      beta_mean(0.0f),
      dataTypeA(CUDA_C_32F),
      dataTypeS(CUDA_R_32F),
      dataTypeU(CUDA_C_32F),
      dataTypeV(CUDA_C_32F),
      computeType(CUDA_C_32F) {
    // Calculate ensemble parameters
    this->ensemble_size = pdiSpec.ensemble_size;
    this->shiftSize = pdiSpec.shiftSize;
    this->cropPDI = pdiSpec.cropPDI;
    this->method = pdiSpec.method;
    this->threshold = pdiSpec.threshold;
    this->lowerThreshold = pdiSpec.lowerThreshold;
    this->total_size = pdiSpec.total_size;

    num_frames = receiveSpec.nRepeats;
    // num_ensembles = floor(num_frames / shiftSize) - 1;
    num_ensembles =
        std::max<int32_t>(0, (num_frames - ensemble_size) / shiftSize + 1);
    total_frames_used = num_ensembles * ensemble_size;

    // Calculate frame dimensions
    frame_size_x = reconSpec.nx;
    frame_size_z = reconSpec.nz;

    // Calculate matrix dimensions M x N
    M = frame_size_x * frame_size_z;
    N = ensemble_size;
    min_M_N = std::min(M, N);

    // Initialize Common Alphas and Betas
    alpha_mean = 1.0f / static_cast<float>(N);
    beta_mean = 0.0f;

    if (method == SVDMethod::Full) {
        thresholdSvd = static_cast<int32_t>(
            std::roundf(threshold * static_cast<float>(ensemble_size)));
    } else if (method == SVDMethod::CovarianceEig) {
        thresholdEig = static_cast<int32_t>(
            std::roundf(static_cast<float>(ensemble_size) -
                        (threshold * static_cast<float>(ensemble_size))));
    }
    computeLowerThresholdEig();

    initCudaResources();
    allocateMemory(externalBFAlloc);
}

void PDI::computeLowerThresholdEig() {
    // Only the CovarianceEig path uses lowerThresholdEig (and only its thresholdEig
    // is set); leave it at 0 otherwise.
    if (method != SVDMethod::CovarianceEig) {
        lowerThresholdEig = 0;
        return;
    }
    lowerThresholdEig = static_cast<int32_t>(
        std::roundf(lowerThreshold * static_cast<float>(ensemble_size)));
    if (lowerThresholdEig < 0) lowerThresholdEig = 0;
    // Keep at least one component: lowerThresholdEig < thresholdEig.
    if (thresholdEig > 0 && lowerThresholdEig > thresholdEig - 1)
        lowerThresholdEig = thresholdEig - 1;
}

PDI::~PDI() {
    // Free common device memory
    cudaFree(d_A_reconstructed);
    cudaFree(d_abs_A);
    cudaFree(d_weights);
    cudaFree(d_mean);

    // Free common host memory (slot-ring base, not the h_mean view)
    cudaFreeHost(h_mean_base);
    free(workspaceBufferOnHost);

    // Method-specific cleanup
    if (method == SVDMethod::Full) {
        // Device memory full SVD
        cudaFree(d_U);
        cudaFree(d_VT);
        cudaFree(d_S);
        cudaFree(d_info);
        cudaFree(d_US);
        cudaFree(d_S_complex);
        cudaFree(d_info_dp);
        cudaFree(workspaceBufferOnDevice);

        // Host memory full SVD
        delete[] h_err_sigma;
    } else if (method == SVDMethod::CovarianceEig) {
        // Device memory Eig Covariance
        cudaFree(d_cov);
        cudaFree(d_U_cov);
        cudaFree(d_VT_cov);
        cudaFree(d_S_cov);
        cudaFree(d_S_reduced_cov);
        gpuErrchk(cudaFree(d_work_eig));
        gpuErrchk(cudaFree(d_info_eig));

        // Host memory Eig Covariance
    }
    if (externalBFAlloc) {
        if (d_externalBeamformedData) {
            cudaFree(d_externalBeamformedData);
            d_externalBeamformedData = nullptr;
        }
        if (h_externalBeamformedDataPinned) {
            cudaFreeHost(h_externalBeamformedDataPinned);
            h_externalBeamformedDataPinned = nullptr;
        }
    }

    // Free cropped memory if used
    if (cropPDI) {
        cudaFree(d_mean_cropped);
        cudaFreeHost(h_mean_cropped_base);
    }

    // Destroy handles
    cusolverDnDestroy(cusolverHandle);
    cublasDestroy(cublasHandle);
}

void PDI::initCudaResources() {
    status = cusolverDnCreate(&cusolverHandle);
    if (status != CUSOLVER_STATUS_SUCCESS) {
        throw std::runtime_error("cuSOLVER initialization failed");
    }

    if (cublasCreate(&cublasHandle) != CUBLAS_STATUS_SUCCESS) {
        throw std::runtime_error("cuBLAS initialization failed");
    }

    cusolverDnCreateParams(&cusolverParams);
}

void PDI::allocateMemory(const bool externalBFAlloc) {
    // Initialize thresholds
    if (method == SVDMethod::Full) {
        thresholdSvd = static_cast<int32_t>(
            std::roundf(threshold * static_cast<float>(ensemble_size)));
    } else if (method == SVDMethod::CovarianceEig) {
        thresholdEig = static_cast<int32_t>(
            std::roundf(static_cast<float>(ensemble_size) -
                        (threshold * static_cast<float>(ensemble_size))));
    }

    // Initialize host weights
    h_weights = std::vector<float>(N, 1.0f);

    // Allocate method-specific memory
    if (method == SVDMethod::Full) {
        allocateFullSVDMemory();
    } else if (method == SVDMethod::CovarianceEig) {
        allocateCovarianceEigMemory();
    }

    // Allocate common memory
    allocateCommonMemory(externalBFAlloc);
}

void PDI::allocateFullSVDMemory() {
    size_A = M * N * sizeof(float2);
    size_U = M * min_M_N * sizeof(float2);
    size_VT = min_M_N * N * sizeof(float2);
    size_S = min_M_N * sizeof(float);

    // Allocate SVD-specific device memory
    gpuErrchk(cudaMalloc((void **)&d_U, size_U));
    gpuErrchk(cudaMalloc((void **)&d_VT, size_VT));
    gpuErrchk(cudaMalloc((void **)&d_S, size_S));
    gpuErrchk(cudaMalloc((void **)&d_info, sizeof(int)));
    gpuErrchk(cudaMalloc((void **)&d_US, M * min_M_N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_S_complex, min_M_N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_info_dp, sizeof(int)));

    // Initialize memory with zeros
    gpuErrchk(cudaMemset(d_S_complex, 0, min_M_N * sizeof(float2)));

    // Setup SVD workspace
    cusolverDnXgesvdp_bufferSize(
        cusolverHandle, cusolverParams, CUSOLVER_EIG_MODE_VECTOR, 1, M, N,
        dataTypeA, offset_ptr, M, dataTypeS, d_S, dataTypeU, d_U, M, dataTypeV,
        d_VT, min_M_N, computeType, &workspaceInBytesOnDevice,
        &workspaceInBytesOnHost);

    // Allocate workspace buffers (used by both methods)
    gpuErrchk(cudaMalloc(&workspaceBufferOnDevice, workspaceInBytesOnDevice));

    // Allocate host memory for full SVD
    h_err_sigma = new double[min_M_N];
    workspaceBufferOnHost = malloc(workspaceInBytesOnHost);
}

void PDI::allocateCovarianceEigMemory() {
    gpuErrchk(cudaMalloc((void **)&d_cov, N * N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_U_cov, N * N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_VT_cov, N * N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_S_cov, N * sizeof(float)));
    gpuErrchk(cudaMalloc((void **)&d_S_reduced_cov, N * sizeof(float2)));

    // Query buffer size
    cusolverErrchk(cusolverDnXsyevd_bufferSize(
        cusolverHandle, cusolverParams, CUSOLVER_EIG_MODE_VECTOR,
        CUBLAS_FILL_MODE_UPPER, N, CUDA_C_32F, d_cov, N, CUDA_R_32F, d_S_cov,
        CUDA_C_32F, &workspaceInBytesOnDevice, &workspaceInBytesOnHost));

    gpuErrchk(cudaMalloc(&d_work_eig, workspaceInBytesOnDevice));
    gpuErrchk(cudaMalloc(&d_info_eig, sizeof(int)));

    workspaceBufferOnHost = malloc(workspaceInBytesOnHost);
}

void PDI::allocateCommonMemory(const bool externalBFAlloc) {
    // Common device memory
    gpuErrchk(cudaMalloc((void **)&d_A_reconstructed, M * N * sizeof(float2)));
    gpuErrchk(cudaMalloc((void **)&d_abs_A, M * N * sizeof(float)));
    gpuErrchk(cudaMalloc((void **)&d_weights, N * sizeof(float)));
    gpuErrchk(cudaMalloc((void **)&d_mean, num_ensembles * M * sizeof(float)));

    // Initialize with zeros
    gpuErrchk(cudaMemset(d_A_reconstructed, 0, M * N * sizeof(float2)));
    gpuErrchk(cudaMemset(d_mean, 0, num_ensembles * M * sizeof(float)));

    // Copy weights to device
    gpuErrchk(cudaMemcpy(d_weights, h_weights.data(), N * sizeof(float),
                         cudaMemcpyHostToDevice));

    // Init Pinned host for return (one slot; setStorageSlots resizes it)
    gpuErrchk(cudaMallocHost(&h_mean_base,
                             static_cast<size_t>(mStorageSlots) *
                                 slotStride(num_ensembles * M) *
                                 sizeof(float)));
    mStorageSlot = 0;
    refreshStorageViews();

    if (externalBFAlloc) {
        size_t externalBFSize = num_frames * M * sizeof(float2);

        // Allocate GPU memory
        gpuErrchk(cudaMalloc(&d_externalBeamformedData, externalBFSize));
        // gpuErrchk(cudaMemset(d_externalBeamformedData, 0, externalBFSize));

        // Allocate pinned host memory
        gpuErrchk(
            cudaMallocHost(&h_externalBeamformedDataPinned, externalBFSize));
    }

    if (cropPDI) {
        initCropParameters();
    }
}

void PDI::initCropParameters() {
    frame_size_x_cropped = reconSpec.nChannelsReduced;
    frame_size_z_cropped = reconSpec.nSamplesReduced;

    nSamplesCropTop = reconSpec.nSamplesCropTop;
    nSamplesCropBot = reconSpec.nSamplesCropBot;
    nChannelsCropLeft = reconSpec.nChannelsCropLeft;
    nChannelsCropRight = reconSpec.nChannelsCropRight;

    nSamplesReduced = reconSpec.nSamplesReduced;
    nChannelsReduced = reconSpec.nChannelsReduced;

    totalSizeCropped = nSamplesReduced * nChannelsReduced;

    M_cropped = frame_size_x_cropped * frame_size_z_cropped;
    N_cropped = ensemble_size;
    min_M_N_cropped = std::min(M_cropped, N_cropped);

    // Allocate cropped memory
    gpuErrchk(
        cudaMalloc(&d_mean_cropped, num_ensembles * M_cropped * sizeof(float)));
    gpuErrchk(cudaMemset(d_mean_cropped, 0,
                         num_ensembles * M_cropped * sizeof(float)));
    if (h_mean_cropped_base) gpuErrchk(cudaFreeHost(h_mean_cropped_base));
    gpuErrchk(cudaMallocHost(&h_mean_cropped_base,
                             static_cast<size_t>(mStorageSlots) *
                                 slotStride(num_ensembles * M_cropped) *
                                 sizeof(float)));
    refreshStorageViews();
}

size_t PDI::slotStride(size_t elems) {
    // Every slot must start on a page boundary for O_DIRECT, not just the
    // first, so pad each one up to a page.
    constexpr size_t elemsPerPage = kSlotAlignmentBytes / sizeof(float);
    return ((elems + elemsPerPage - 1) / elemsPerPage) * elemsPerPage;
}

void PDI::refreshStorageViews() {
    if (h_mean_base)
        h_mean = h_mean_base + static_cast<size_t>(mStorageSlot) *
                                   slotStride(num_ensembles * M);
    if (h_mean_cropped_base)
        h_mean_cropped = h_mean_cropped_base +
                         static_cast<size_t>(mStorageSlot) *
                             slotStride(num_ensembles * M_cropped);
}

void PDI::setStorageSlots(int nSlots) {
    if (nSlots < 1) nSlots = 1;
    if (nSlots == mStorageSlots && h_mean_base != nullptr) return;

    mStorageSlots = nSlots;
    mStorageSlot = 0;

    if (h_mean_base) gpuErrchk(cudaFreeHost(h_mean_base));
    gpuErrchk(cudaMallocHost(&h_mean_base,
                             static_cast<size_t>(mStorageSlots) *
                                 slotStride(num_ensembles * M) *
                                 sizeof(float)));

    if (h_mean_cropped_base) {
        gpuErrchk(cudaFreeHost(h_mean_cropped_base));
        gpuErrchk(cudaMallocHost(&h_mean_cropped_base,
                                 static_cast<size_t>(mStorageSlots) *
                                     slotStride(num_ensembles * M_cropped) *
                                     sizeof(float)));
    }

    refreshStorageViews();
}

void PDI::transferExternalBFToGPU(const float2 *externalBFHostSource) {
    if (!externalBFAlloc || !h_externalBeamformedDataPinned ||
        !d_externalBeamformedData)
        throw std::runtime_error("External BF buffers not allocated!");

    size_t externalBFSize = num_frames * M * sizeof(float2);

    // First copy from your provided source (regular host memory) to pinned
    // memory
    memcpy(h_externalBeamformedDataPinned, externalBFHostSource,
           externalBFSize);

    // Now efficiently copy from pinned host memory to GPU
    gpuErrchk(cudaMemcpy(d_externalBeamformedData,
                         h_externalBeamformedDataPinned, externalBFSize,
                         cudaMemcpyHostToDevice));
}

void PDI::runPDI(float2 *d_beamformedData) {
    // \callgraph
    if (method == SVDMethod::Full) {
        runSVD(d_beamformedData);
    } else if (method == SVDMethod::CovarianceEig) {
        runCovarianceEig(d_beamformedData);
    }
}

void PDI::runExternalBFPDI() {
    if (!d_externalBeamformedData)
        throw std::runtime_error("External BF GPU memory not allocated!");

    runPDI(d_externalBeamformedData);
}

void PDI::runSVD(float2 *d_beamformedData) {
    for (int32_t ensembleIdx = 0; ensembleIdx < num_ensembles; ensembleIdx++) {
        // Setup pointers for the portion of data we’re analyzing
        offset_ptr = &d_beamformedData[ensembleIdx * M * shiftSize];
        d_mean_offset = &d_mean[ensembleIdx * M];

        // Safety check on cuSolver status if needed
        if (status != CUSOLVER_STATUS_SUCCESS) {
            std::cerr << "CUSOLVER bufferSize query failed" << std::endl;
            exit(1);
        }

        // Perform SVD using cuSOLVER
        status = cusolverDnXgesvdp(
            cusolverHandle, cusolverParams, CUSOLVER_EIG_MODE_VECTOR, 1, M, N,
            dataTypeA, offset_ptr, M, dataTypeS, d_S, dataTypeU, d_U, M,
            dataTypeV, d_VT, min_M_N, computeType, workspaceBufferOnDevice,
            workspaceInBytesOnDevice, workspaceBufferOnHost,
            workspaceInBytesOnHost,
            d_info_dp,   // device info
            h_err_sigma  // host error info (size = min(M, N))
        );

        if (status != CUSOLVER_STATUS_SUCCESS) {
            std::cerr << "CUSOLVER SVD computation failed" << std::endl;
            exit(1);
        }

        // 1. Threshold the singular values on GPU
        int blockSize = 256;
        int gridSize = (thresholdSvd + blockSize - 1) / blockSize;
        if (thresholdSvd > 0) {
            threshold_singular_values<<<gridSize, blockSize>>>(d_S,
                                                               thresholdSvd);
            gpuErrchk(cudaPeekAtLastError());
        }

        // 2.Convert real singular values to complex form
        int blockSize_R2C = 256;
        int gridSize_R2C = (min_M_N + blockSize_R2C - 1) / blockSize_R2C;
        copyRealToComplex<<<gridSize_R2C, blockSize_R2C>>>(d_S, d_S_complex,
                                                           min_M_N);
        gpuErrchk(cudaPeekAtLastError());

        // 3. Compute (U * S_thresholded)
        cublasStatus_t cublas_stat =
            cublasCdgmm(cublasHandle, CUBLAS_SIDE_RIGHT, M, min_M_N,
                        reinterpret_cast<cuComplex *>(d_U), M,
                        reinterpret_cast<cuComplex *>(d_S_complex), 1,
                        reinterpret_cast<cuComplex *>(d_US), M);
        if (cublas_stat != CUBLAS_STATUS_SUCCESS) {
            std::cerr << "cublasCdgmm failed" << std::endl;
            exit(1);
        }

        // 4. Compute A_reconstructed = (U * S') * V^H
        cublas_stat = cublasCgemm(cublasHandle,
                                  CUBLAS_OP_N,    // no transpose U*S
                                  CUBLAS_OP_C,    // conjugate transpose V^T
                                  M,              // # of rows of result
                                  N,              // # of cols of result
                                  min_M_N,        // shared dimension
                                  &alpha,         // alpha
                                  d_US, M,        // A = U*S
                                  d_VT, min_M_N,  // B = V^H
                                  &beta,          // beta
                                  d_A_reconstructed, M);
        if (cublas_stat != CUBLAS_STATUS_SUCCESS) {
            std::cerr << "cublasCgemm failed" << std::endl;
            exit(1);
        }

        // 5. Compute absolute value of A_reconstructed
        dim3 blockSize_abs(16, 16);
        dim3 gridSize_abs((M + blockSize_abs.x - 1) / blockSize_abs.x,
                          (N + blockSize_abs.y - 1) / blockSize_abs.y);
        absComplex<<<gridSize_abs, blockSize_abs>>>(d_A_reconstructed, d_abs_A,
                                                    M, N);
        gpuErrchk(cudaPeekAtLastError());

        // 6. Compute mean along columns -> d_mean_offset
        float alpha_mean = 1.0f / N;
        float beta_mean = 0.0f;
        cublas_stat =
            cublasSgemv(cublasHandle, CUBLAS_OP_N, M, N, &alpha_mean, d_abs_A,
                        M, d_weights, 1, &beta_mean, d_mean_offset, 1);
        if (cublas_stat != CUBLAS_STATUS_SUCCESS) {
            std::cerr << "cublasSgemv (mean) failed" << std::endl;
            exit(1);
        }

        // 7. Crop if necessary
        if (cropPDI) {
            dim3 threadsPerBlock(128);
            dim3 numBlocks((totalSizeCropped + threadsPerBlock.x - 1) /
                           threadsPerBlock.x);

            cropPDIkernel<<<numBlocks, threadsPerBlock>>>(
                d_mean_offset, d_mean_cropped + ensembleIdx * M_cropped,
                frame_size_x, frame_size_z,
                totalSizeCropped, nSamplesReduced, nChannelsReduced,
                nSamplesCropTop, nSamplesCropBot, nChannelsCropLeft,
                nChannelsCropRight);
            gpuErrchk(cudaPeekAtLastError());
        }
    }
}

void PDI::runCovarianceEig(float2 *d_beamformedData) {
    for (int32_t ensembleIdx = 0; ensembleIdx < num_ensembles; ensembleIdx++) {
        // Setup pointers for the portion of data we’re analyzing
        offset_ptr = &d_beamformedData[ensembleIdx * M * shiftSize];
        d_mean_offset = &d_mean[ensembleIdx * M];

        // 1. Compute covariance matrix: d_cov = (1/M) * x^H * x
        const cuComplex alpha =
            make_cuComplex(1.0f / static_cast<float>(M), 0.0f);
        const cuComplex beta = make_cuComplex(0.0f, 0.0f);

        // cublasCgemm3m or cublasCgemm, depending on your setup
        cublasErrchk(cublasCgemm3m(cublasHandle, CUBLAS_OP_C, CUBLAS_OP_N, N, N,
                                   M, &alpha, offset_ptr, M, offset_ptr, M,
                                   &beta, d_cov, N));

        // 2. Eigenvalue decomposition of d_cov

        // Perform syevd
        cusolverErrchk(cusolverDnXsyevd(
            cusolverHandle, cusolverParams, CUSOLVER_EIG_MODE_VECTOR,
            CUBLAS_FILL_MODE_UPPER, N, CUDA_C_32F, d_cov, N, CUDA_R_32F,
            d_S_cov, CUDA_C_32F, d_work_eig, workspaceInBytesOnDevice,
            workspaceBufferOnHost, workspaceInBytesOnHost, d_info_eig));

        int h_info_eig = 0;
        gpuErrchk(cudaMemcpy(&h_info_eig, d_info_eig, sizeof(int),
                             cudaMemcpyDeviceToHost));
        if (h_info_eig != 0) {
            std::cerr << "Eigen decomposition failed, info = " << h_info_eig
                      << std::endl;
            exit(1);
        }

        // 3. Threshold / partial reconstruction. Reconstruct from eigenvectors
        // [lowerThresholdEig, thresholdEig): the upper cut drops tissue, the
        // lower cut drops noise (lowerThresholdEig == 0 -> no noise reject).
        const float falpha = 1.0f;
        const float fbeta = 0.0f;

        cublasErrchk(cublasCherk(cublasHandle, CUBLAS_FILL_MODE_UPPER,
                                 CUBLAS_OP_N, N, thresholdEig - lowerThresholdEig,
                                 &falpha, d_cov + (lowerThresholdEig * N), N,
                                 &fbeta, d_VT_cov, N));

        // Then cublasChemm
        cublasErrchk(cublasChemm(
            cublasHandle, CUBLAS_SIDE_RIGHT, CUBLAS_FILL_MODE_UPPER, M, N,
            &alpha, d_VT_cov, N, offset_ptr, M, &beta, d_A_reconstructed, M));

        // 4. Calculate the absolute value of the reconstructed A
        dim3 blockSize_abs(16, 16);
        dim3 gridSize_abs((M + blockSize_abs.x - 1) / blockSize_abs.x,
                          (N + blockSize_abs.y - 1) / blockSize_abs.y);
        absComplex<<<gridSize_abs, blockSize_abs>>>(d_A_reconstructed, d_abs_A,
                                                    M, N);
        gpuErrchk(cudaPeekAtLastError());

        // 5. Calculate the mean along columns
        cublasErrchk(cublasSgemv(cublasHandle, CUBLAS_OP_N, M, N, &alpha_mean,
                                 d_abs_A, M, d_weights, 1, &beta_mean,
                                 d_mean_offset, 1));

        // 6. Crop if necessary
        if (cropPDI) {
            dim3 threadsPerBlock(128);
            dim3 numBlocks((totalSizeCropped + threadsPerBlock.x - 1) /
                           threadsPerBlock.x);

            cropPDIkernel<<<numBlocks, threadsPerBlock>>>(
                d_mean_offset, d_mean_cropped + ensembleIdx * M_cropped,
                frame_size_x, frame_size_z,
                totalSizeCropped, nSamplesReduced, nChannelsReduced,
                nSamplesCropTop, nSamplesCropBot, nChannelsCropLeft,
                nChannelsCropRight);
            gpuErrchk(cudaPeekAtLastError());
        }
    }
}

void PDI::updateThreshold(float newThreshold) {
    // Update the raw threshold
    this->threshold = newThreshold;

    if (method == SVDMethod::Full) {
        thresholdSvd = static_cast<int32_t>(
            std::roundf(newThreshold * static_cast<float>(ensemble_size)));
    } else if (method == SVDMethod::CovarianceEig) {
        thresholdEig = static_cast<int32_t>(
            std::roundf(static_cast<float>(ensemble_size) -
                        (newThreshold * static_cast<float>(ensemble_size))));
    } else {
        throw std::invalid_argument("PDI::updateThreshold: invalid SVD method");
    }
    computeLowerThresholdEig();  // re-clamp against the new thresholdEig
}

void PDI::updateLowerThreshold(float newLowerThreshold) {
    this->lowerThreshold = newLowerThreshold;
    // Only the CovarianceEig path consumes lowerThresholdEig today.
    computeLowerThresholdEig();
}

void PDI::copyPDIToHost() {
    // 1. Check if pointers are allocated
    if (!h_mean || !d_mean) {
        std::cerr << "Error: h_mean or d_mean is not allocated." << std::endl;
        throw std::runtime_error(
            "PDI::copyPDIToHost(): Host or device pointer not allocated.");
        exit(1);
    }

    // 2. Advance before filling, so h_mean names this frame's buffer. Runs
    // every frame before copyCroppedPDIToHost(), so it is the only advance.
    mStorageSlot = (mStorageSlot + 1) % mStorageSlots;
    refreshStorageViews();

    // 3. Perform device-to-host copy
    cudaError_t err =
        cudaMemcpy(h_mean, d_mean, num_ensembles * M * sizeof(float),
                   cudaMemcpyDeviceToHost);

    // 4. Check for errors
    if (err != cudaSuccess) {
        std::cerr << "Error in cudaMemcpy from d_mean to h_mean: "
                  << cudaGetErrorString(err) << std::endl;
        throw std::runtime_error("PDI::copyPDIToHost() failed: " +
                                 std::string(cudaGetErrorString(err)));
    }
}

void PDI::copyCroppedPDIToHost() {
    // 1. Check if cropping is actually enabled
    if (!cropPDI) {
        std::cerr << "Warning: copyCroppedPDIToHost() called while cropPDI "
                     "== false."
                  << std::endl;
        return;
    }

    // 2. Check if pointers are allocated
    if (!h_mean_cropped || !d_mean_cropped) {
        std::cerr << "Error: h_mean_cropped or d_mean_cropped is not allocated."
                  << std::endl;
        throw std::runtime_error(
            "PDI::copyCroppedPDIToHost(): Host or device pointer not "
            "allocated.");
        // or: exit(1);
    }

    // 3. Perform device-to-host copy
    cudaError_t err = cudaMemcpy(h_mean_cropped, d_mean_cropped,
                                 num_ensembles * M_cropped * sizeof(float),
                                 cudaMemcpyDeviceToHost);

    // 4. Check for errors
    if (err != cudaSuccess) {
        std::cerr
            << "Error in cudaMemcpy from d_mean_cropped to h_mean_cropped: "
            << cudaGetErrorString(err) << std::endl;
        throw std::runtime_error("PDI::copyCroppedPDIToHost() failed: " +
                                 std::string(cudaGetErrorString(err)));
    }
}

float *PDI::getResults() {
    // Copy the full PDI (non-cropped) results to host, then return pointer
    copyPDIToHost();
    return h_mean;
}

float *PDI::getCroppedResults() {
    // Copy the cropped PDI results to host, then return pointer
    if (!cropPDI) {
        std::cerr
            << "Warning: getCroppedResults() called, but cropPDI == false."
            << std::endl;
        return nullptr;
    }

    copyCroppedPDIToHost();
    return h_mean_cropped;
}
}  // namespace PDI