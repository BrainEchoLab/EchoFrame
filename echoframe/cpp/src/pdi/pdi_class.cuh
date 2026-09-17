/**
 * @file pdi_class.cuh
 * @author BrainEcho Lab
 * @brief PDI class header file
 * @details This file contains the definition of the PDI class, which
 * performs Power Doppler Imaging (PDI) on beamformed data using CUDA.
 * It includes methods for SVD and covariance eigenvalue decomposition, as well
 * as memory management and data transfer between host and device.
 * @version 0.1
 * @date 2025-01-29
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once
#include <cstdint>
#include <vector>

#include <cuComplex.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cusolverDn.h>

#include "../beamformer/resources.h"
#include "pdi_kernels.cuh"
#include "pdi_spec.h"

namespace PDI {

/**
 * @brief Class that performs the Power Dopple Imaging (PDI) technique on
 * beamformed data. Currently it supports two methods:
 * 1. Full SVD (slower),
 * 2. Covariance Eigenvalue Decomposition (faster).
 *
 */

class PDI {
   public:
    // Views into the slot rings below, not allocations.
    float *h_mean;
    float *h_mean_cropped;

    /**
     * @brief Resize the storage slot ring.
     * @param nSlots Number of slots; pass the PDI storage handler's nBuffers
     * when PDI is being saved, 1 otherwise.
     * @details Storage DMAs out of the buffer passed to storeBuffer, so
     * refilling one buffer every frame corrupts writes still in flight.
     */
    void setStorageSlots(int nSlots);
    /**
     * @brief PDI object default constructor.
     *
     * @param pPdiSpec pdiSpec input struct.
     * @param pReceiveSpec receiveSpec input struct.
     * @param pReconSpec reconSpec input struct.
     * @param externalBF Allocate for caller-supplied beamformed data, as the
     * PDI-only path does.
     */
    PDI(PDISpec pPdiSpec, Beamform::ReceiveSpec pReceiveSpec,
        Beamform::ReconSpec pReconSpec, bool externalBF = false);

    /**
     * @brief PDI object destructor.
     *
     */
    ~PDI();

    /**
     * @brief Custom BF transfer to GPU (for PDI only process).
     *
     * @param externalBFHostSource Host pointer to the beamformed data
     * (external).
     */
    void transferExternalBFToGPU(const float2 *externalBFHostSource);

    /**
     * @brief Run the PDI method.
     *
     * @param d_beamformedData Device pointer to the beamformed data.
     */
    void runPDI(float2 *d_beamformedData);

    /**
     * @brief Wrapper around runPDI() to run the PDI method with external BF
     * data, on the buffer a prior transferExternalBFToGPU() filled.
     */
    void runExternalBFPDI();
    /**
     * @brief Live update the upper (tissue) reject threshold.
     *
     * @param newThreshold New threshold value (0-1 fraction).
     */
    void updateThreshold(float newThreshold);

    /**
     * @brief Live update the lower (noise) reject threshold.
     *
     * @param newLowerThreshold New lower threshold value (0-1 fraction).
     */
    void updateLowerThreshold(float newLowerThreshold);

    /**
     * @brief Return host pointer to the PDI results.
     *
     * @return float* Host pointer to the PDI results.
     */
    float *getResults();

    /**
     * @brief Return host pointer to the cropped PDI results.
     *
     * @return float* Host pointer to the cropped PDI results.
     */
    float *getCroppedResults();

   private:
    // PDI method enum
    SVDMethod method;

    // PDI, Receive and Reconstruction specs
    PDISpec pdiSpec;
    Beamform::ReceiveSpec receiveSpec;
    Beamform::ReconSpec reconSpec;

    // Thresholds
    float threshold;
    float lowerThreshold{0.0f};
    int32_t thresholdEig;
    int32_t thresholdSvd;
    int32_t lowerThresholdEig{0};

    // Frame dimensions and counts
    int32_t ensemble_size;
    int32_t num_ensembles;
    int32_t num_frames;
    int32_t shiftSize;
    int32_t overlap;
    int32_t total_frames_used;
    int32_t total_size;

    // Frame size parameters
    int32_t frame_size_z;
    int32_t frame_size_x;

    // Cropping parameters
    bool cropPDI;
    int32_t frame_size_z_cropped;
    int32_t frame_size_x_cropped;
    int32_t nSamplesCropTop;
    int32_t nSamplesCropBot;
    int32_t nChannelsCropLeft;
    int32_t nChannelsCropRight;
    int32_t nSamplesReduced;
    int32_t nChannelsReduced;
    int32_t totalSizeCropped;

    // Matrix dimensions
    int64_t M, N, min_M_N;
    int64_t M_cropped, N_cropped, min_M_N_cropped;

    // Rings backing h_mean / h_mean_cropped; both share one index.
    float *h_mean_base{nullptr};
    float *h_mean_cropped_base{nullptr};
    int mStorageSlots{1};
    int mStorageSlot{0};
    static constexpr size_t kSlotAlignmentBytes = 4096;

    /**
     * @brief Elements per slot, padded so each slot stays page-aligned.
     */
    static size_t slotStride(size_t elems);

    /**
     * @brief Point h_mean/h_mean_cropped at the current slot.
     */
    void refreshStorageViews();

    // CUDA resources
    cusolverDnHandle_t cusolverHandle;
    cublasHandle_t cublasHandle;
    cusolverDnParams_t cusolverParams;
    cusolverStatus_t status;

    // Internal beamformer data pointer
    float2 *offset_ptr;  // offset_ptr is &d_beamformedData[ensembleIdx *
                         // pdiSpec.M * pdiSpec.N]

    // Device memory - Common
    float2 *d_A_reconstructed;
    float *d_abs_A;
    float *d_weights;
    float *d_mean;
    float *d_mean_offset;

    // Device memory - full SVD
    float2 *d_U;
    float2 *d_VT;
    float *d_S;
    int *d_info;
    float2 *d_US;
    float2 *d_S_complex;
    float *d_mean_cropped;
    int *d_info_dp;

    // Device memory - Eig Covariance
    float2 *d_cov;
    float2 *d_U_cov;
    float2 *d_VT_cov;
    float *d_S_cov;
    float2 *d_S_reduced_cov;
    void *d_work_eig;
    int *d_info_eig;

    // Complex constants
    float2 alpha;
    float2 beta;
    float alpha_mean;
    float beta_mean;

    // Host memory - common
    // float *h_mean;
    // float *h_mean_cropped;
    std::vector<float> h_weights;
    size_t workspaceInBytesOnDevice;
    size_t workspaceInBytesOnHost;
    void *workspaceBufferOnDevice;
    void *workspaceBufferOnHost;

    // Host memory - full SVD
    double *h_err_sigma;
    size_t size_A;
    size_t size_U;
    size_t size_VT;
    size_t size_S;

    // Host memory - Eig Covariance
    void *h_work_eig;

    // CUDA events for timing
    cudaEvent_t start_total, stop_total;
    cudaEvent_t start_svd, stop_svd;
    cudaEvent_t start_pdi, stop_pdi;

    // CUDA data types
    cudaDataType dataTypeA;
    cudaDataType dataTypeS;
    cudaDataType dataTypeU;
    cudaDataType dataTypeV;
    cudaDataType computeType;

    bool externalBFAlloc;  // Flag to indicate if the beamformed data is
                           // coming externally

    float2 *d_externalBeamformedData =
        nullptr;  // Pointer to the external beamformed
    // data

    float2 *h_externalBeamformedDataPinned = nullptr;

    // Private Methods.

    /**
     * @brief Run the full SVD method.
     *
     * @param d_beamformedData Device pointer to the beamformed data.
     */
    void runSVD(float2 *d_beamformedData);

    /**
     * @brief Run the covariance eig method.
     *
     * @param d_beamformedData Device pointer to the beamformed data.
     */
    void runCovarianceEig(float2 *d_beamformedData);

    /**
     * @brief Recompute lowerThresholdEig from lowerThreshold, clamped to
     * [0, thresholdEig). Call after thresholdEig or lowerThreshold changes.
     */
    void computeLowerThresholdEig();

    /**
     * @brief Initialize CUDA resources (i.e., cuSOLOVER, cuBLAS, etc.)
     *
     */
    void initCudaResources();

    /**
     * @brief Initialize cropping parameters as well as GPU and host memory for
     * cropping.
     *
     */
    void initCropParameters();

    /**
     * @brief Allocate memory for the PDI class.
     *
     * @param externalBFAlloc bool to indicate if the beamformed data is coming
     * internally/externally
     */
    void allocateMemory(const bool externalBFAlloc);

    /**
     * @brief Allocate specific memory for the full SVD method.
     *
     */
    void allocateFullSVDMemory();

    /**
     * @brief Allocate specific memory for the covariance eig method.
     *
     */
    void allocateCovarianceEigMemory();

    /**
     * @brief Allocate common memory for both methods.
     *
     * @param externalBFAlloc bool to indicate if the beamformed data is coming
     * internally/externally
     */
    void allocateCommonMemory(const bool externalBFAlloc);

    /**
     * @brief Copy the PDI results to the host from the GPU.
     *
     */
    void copyPDIToHost();

    /**
     * @brief Copy the cropped PDI results to the host from the GPU.
     *
     */
    void copyCroppedPDIToHost();
};
}  // namespace PDI
