/**
 * @file BF_formatter.h
 * @author BrainEcho Lab
 * @brief Beamformed Data Formatter (Header)
 * @details This header defines the BFFormatter class template, which provides
 * utilities for converting beamformed data to various output formats on the
 * GPU. Supported conversions include complex-to-real, complex single-to-half
 * precision, complex single-to-bfloat16, and complex-to-B-mode. The class
 * manages GPU memory, handles resource initialization and cleanup, and supports
 * efficient data transfer between device and host.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <iostream>

#include <cublas_v2.h>
#include <cuda.h>
#include <vector_types.h>

#include "../cuda/cuda_error.h"
#include "beamformer_kernels.h"
#include "resources.h"

namespace Beamform {
/**
 * @brief Class which converts beamformed data to output format. Currently
 * supports complex -> real, complex single -> complex half precision and
 * complex single -> complex bfloat16 conversions and complex -> to B-mode.
 * @tparam bfType_t BF data type
 * @tparam outputType_t output data type
 */
template <typename bfType_t, typename outputType_t>
class BFFormatter {
   private:
   private:
    ReceiveSpec receiveSpec;  ///< Receive specification
    ReconSpec reconSpec;      ///< Reconstruction specification

    size_t bfSize{0};         ///< Total size of beamformed data
    size_t bfSizeCropped{0};  ///< Size of cropped beamformed data

    std::vector<outputType_t *> h_output;  ///< Host output pointers

    outputType_t *d_output;  ///< Device output pointer

    bfType_t *d_bf;                 ///< Device pointer to original BF data
    half2 *d_half2Data = nullptr;   ///< Device pointer to half2 data
    float2 *d_bfCropped = nullptr;  ///< Device pointer to cropped BF data
    nv_bfloat162 *d_bfloat162Data =
        nullptr;  ///< Device pointer to bfloat16 data

    float *d_weights = nullptr;      ///< Device-side weights
    float *d_mean_output = nullptr;  ///< Device-side mean result
    cublasHandle_t cublas_handle;    ///< cuBLAS handle for matrix operations
    float alpha_mean;                ///< Scaling factor for mean calculation
    float beta_mean;                 ///< Offset for mean calculation

    bool initialized{false};  ///< Initialization flag

    // Storage writes DMA straight out of the buffer passed to storeBuffer, so
    // reusing one buffer per frame corrupts writes still in flight. Rotate
    // through a ring instead. Only the stored ring needs slots.
    float2 *pinnedBFBase = nullptr;         ///< Base of the BF slot ring
    float2 *pinnedBFCroppedBase = nullptr;  ///< Base of the cropped slot ring
    int mSlotsFull{1};                      ///< Slots in the full-BF ring
    int mSlotsCropped{1};                   ///< Slots in the cropped-BF ring
    int mStorageSlot{0};                    ///< Frame counter driving both rings

    /// Every slot must be page-aligned for O_DIRECT, not just the first.
    static constexpr size_t kSlotAlignmentBytes = 4096;

    /**
     * @brief Elements per slot, padded so each slot stays page-aligned.
     */
    static size_t slotStride(size_t elems) {
        constexpr size_t elemsPerPage = kSlotAlignmentBytes / sizeof(float2);
        return ((elems + elemsPerPage - 1) / elemsPerPage) * elemsPerPage;
    }

    /**
     * @brief Point pinnedBF/pinnedBFCropped at the current slot.
     */
    void refreshStorageViews() {
        if (pinnedBFBase)
            pinnedBF = pinnedBFBase +
                       static_cast<size_t>(mStorageSlot % mSlotsFull) *
                           slotStride(bfSize);
        if (pinnedBFCroppedBase)
            pinnedBFCropped =
                pinnedBFCroppedBase +
                static_cast<size_t>(mStorageSlot % mSlotsCropped) *
                    slotStride(bfSizeCropped);
    }

   public:
    // Host pointers for B-mode and BF accesible from outside.
    // pinnedBF/pinnedBFCropped are views into the rings, not allocations.
    float *pinnedBmode = nullptr;       ///< Host pinned memory for B-mode
    float2 *pinnedBF = nullptr;         ///< Current BF slot
    float2 *pinnedBFCropped = nullptr;  ///< Current cropped BF slot

    /**
     * @brief Default constructor.
     */
    BFFormatter() = default;

    /**
     * @brief Construct a new BFFormatter with resource specs and sizes.
     * @param pReceiveSpec Receive specification.
     * @param pReconSpec Reconstruction specification.
     * @param pBfSize Total BF size.
     * @param pBfSizeCropped Cropped BF size.
     */
    explicit BFFormatter(ReceiveSpec &pReceiveSpec, ReconSpec &pReconSpec,
                         size_t pBfSize, size_t pBfSizeCropped)
        : receiveSpec(pReceiveSpec),
          reconSpec(pReconSpec),
          bfSize(pBfSize),
          bfSizeCropped(pBfSizeCropped) {
        alpha_mean = 1.0f / receiveSpec.nRepeats;
        beta_mean = 0.0f;

        initGPU();
        initialized = true;
    }

    /**
     * @brief Destructor. Releases GPU and host resources.
     */
    ~BFFormatter() {
        if (initialized) {
            clearGPU();
        }
        if (d_half2Data != nullptr) {
            cudaFree(d_half2Data);
        }
        if (d_bfloat162Data != nullptr) {
            cudaFree(d_bfloat162Data);
        }
        if (d_bfCropped != nullptr) {
            cudaFree(d_bfCropped);
        }
        if (d_weights) {
            cudaFree(d_weights);
        }
        if (d_mean_output) {
            cudaFree(d_mean_output);
        }
        if (reconSpec.cropBF && pinnedBFCroppedBase) {
            gpuErrchk(cudaFreeHost(pinnedBFCroppedBase));
        }
        gpuErrchk(cudaFreeHost(pinnedBmode));
        if (pinnedBFBase) gpuErrchk(cudaFreeHost(pinnedBFBase));
        cublasDestroy(cublas_handle);
    }

    /**
     * @brief Move constructor.
     */
    BFFormatter(BFFormatter &&x) noexcept {
        receiveSpec = std::move(x.receiveSpec);
        reconSpec = std::move(x.reconSpec);
        h_output = std::move(x.h_output);
        d_output = x.d_output;
        d_bf = x.d_bf;
        bfSize = x.bfSize;
        bfSizeCropped = x.bfSizeCropped;
        d_weights = x.d_weights;
        d_mean_output = x.d_mean_output;
        cublas_handle = x.cublas_handle;
        alpha_mean = x.alpha_mean;
        beta_mean = x.beta_mean;
        pinnedBmode = x.pinnedBmode;
        pinnedBFBase = x.pinnedBFBase;
        pinnedBFCroppedBase = x.pinnedBFCroppedBase;
        mSlotsFull = x.mSlotsFull;
        mSlotsCropped = x.mSlotsCropped;
        mStorageSlot = x.mStorageSlot;
        pinnedBF = x.pinnedBF;
        pinnedBFCropped = x.pinnedBFCropped;

        initialized = x.initialized;
        x.initialized = false;

        // Nullify the pointers in the source object to avoid double-free
        x.d_output = nullptr;
        x.d_bf = nullptr;
        x.d_half2Data = nullptr;
        x.d_bfCropped = nullptr;
        x.d_bfloat162Data = nullptr;
        x.d_weights = nullptr;
        x.d_mean_output = nullptr;
        x.pinnedBmode = nullptr;
        x.pinnedBFBase = nullptr;
        x.pinnedBFCroppedBase = nullptr;
        x.pinnedBF = nullptr;
        x.pinnedBFCropped = nullptr;
    }

    /**
     * @brief Move-assignment operator.
     */
    BFFormatter &operator=(BFFormatter &&x) noexcept {
        if (this != &x) {  // Check for self-assignment
            // Free existing resources if necessary
            if (initialized) {
                clearGPU();
                if (d_half2Data) gpuErrchk(cudaFree(d_half2Data));
                if (d_bfCropped) gpuErrchk(cudaFree(d_bfCropped));
                if (d_bfloat162Data) gpuErrchk(cudaFree(d_bfloat162Data));
                if (d_weights) gpuErrchk(cudaFree(d_weights));
                if (d_mean_output) gpuErrchk(cudaFree(d_mean_output));
                if (pinnedBmode) gpuErrchk(cudaFreeHost(pinnedBmode));
                if (pinnedBFBase) gpuErrchk(cudaFreeHost(pinnedBFBase));
                if (pinnedBFCroppedBase)
                    gpuErrchk(cudaFreeHost(pinnedBFCroppedBase));
                cublasDestroy(cublas_handle);
            }

            // Transfer ownership of resources
            receiveSpec = std::move(x.receiveSpec);
            reconSpec = std::move(x.reconSpec);
            h_output = std::move(x.h_output);
            d_output = x.d_output;
            d_bf = x.d_bf;
            bfSize = x.bfSize;
            bfSizeCropped = x.bfSizeCropped;
            d_weights = x.d_weights;
            d_mean_output = x.d_mean_output;
            cublas_handle = x.cublas_handle;
            alpha_mean = x.alpha_mean;
            beta_mean = x.beta_mean;
            pinnedBmode = x.pinnedBmode;
            pinnedBFBase = x.pinnedBFBase;
            pinnedBFCroppedBase = x.pinnedBFCroppedBase;
            mSlotsFull = x.mSlotsFull;
            mSlotsCropped = x.mSlotsCropped;
            mStorageSlot = x.mStorageSlot;
            pinnedBF = x.pinnedBF;
            pinnedBFCropped = x.pinnedBFCropped;

            initialized = x.initialized;
            x.initialized = false;

            // Nullify the pointers in the source object to avoid double-free
            x.d_output = nullptr;
            x.d_bf = nullptr;
            x.d_half2Data = nullptr;
            x.d_bfCropped = nullptr;
            x.d_bfloat162Data = nullptr;
            x.d_weights = nullptr;
            x.d_mean_output = nullptr;
            x.pinnedBmode = nullptr;
            x.pinnedBFBase = nullptr;
            x.pinnedBFCroppedBase = nullptr;
            x.pinnedBF = nullptr;
            x.pinnedBFCropped = nullptr;
            x.cublas_handle = nullptr;
        }
        return *this;
    }

    /**
     * @brief Initialize variables/structs in GPU memory.
     */
    void initGPU() {
        if (!std::is_same_v<bfType_t, outputType_t>) {
            gpuErrchk(cudaMalloc(&d_output, bfSize * sizeof(outputType_t)));
        }

        // Initialize cuBLAS handle
        cublasCreate(&cublas_handle);

        // Allocate device memory for weights (for averaging)
        std::vector<float> h_weights(receiveSpec.nRepeats, 1.0f);
        gpuErrchk(cudaMalloc(&d_weights, receiveSpec.nRepeats * sizeof(float)));
        gpuErrchk(cudaMemcpy(d_weights, h_weights.data(),
                             receiveSpec.nRepeats * sizeof(float),
                             cudaMemcpyHostToDevice));

        // Allocate memory for the mean output
        gpuErrchk(
            cudaMalloc(&d_mean_output, reconSpec.totalSize * sizeof(float)));

        // Allocate pinned memory for B-mode output
        gpuErrchk(cudaMallocHost((void **)&pinnedBmode,
                                 reconSpec.totalSize * sizeof(float)));

        gpuErrchk(cudaMallocHost((void **)&pinnedBFBase,
                                 static_cast<size_t>(mSlotsFull) *
                                     slotStride(bfSize) * sizeof(float2)));
        mStorageSlot = 0;
        refreshStorageViews();
    }

    /**
     * @brief Resize the storage slot ring.
     * @param nSlots Number of slots; pass the storage handler's nBuffers when
     * BF is being saved, 1 otherwise.
     * @param croppedIsStored Give the slots to the cropped ring rather than the
     * full one; the other stays at 1.
     * @details Call before initializeResources(), and again from
     * reinitStorage() if saving is switched on later.
     */
    void setStorageSlots(int nSlots, bool croppedIsStored) {
        if (nSlots < 1) nSlots = 1;
        const int wantFull    = croppedIsStored ? 1 : nSlots;
        const int wantCropped = croppedIsStored ? nSlots : 1;
        if (wantFull == mSlotsFull && wantCropped == mSlotsCropped &&
            pinnedBFBase != nullptr)
            return;

        mSlotsFull    = wantFull;
        mSlotsCropped = wantCropped;
        mStorageSlot  = 0;

        if (pinnedBFBase) gpuErrchk(cudaFreeHost(pinnedBFBase));
        gpuErrchk(cudaMallocHost((void **)&pinnedBFBase,
                                 static_cast<size_t>(mSlotsFull) *
                                     slotStride(bfSize) * sizeof(float2)));

        // Owned by initializeResources(); resize only if already allocated.
        if (pinnedBFCroppedBase) {
            gpuErrchk(cudaFreeHost(pinnedBFCroppedBase));
            gpuErrchk(cudaMallocHost(
                (void **)&pinnedBFCroppedBase,
                static_cast<size_t>(mSlotsCropped) *
                    slotStride(bfSizeCropped) * sizeof(float2)));
        }

        refreshStorageViews();
    }

    /**
     * @brief Clear variables/structs in GPU memory
     */
    void clearGPU() {
        // unpin the pinned memory
        for (auto &pinnedBFPtr : h_output) {
            gpuErrchk(cudaHostUnregister(pinnedBFPtr));
        }

        if (!std::is_same_v<bfType_t, outputType_t>) {
            gpuErrchk(cudaFree(d_output));
        }
    }

    /**
     * @brief Cleanup host output pointers.
     */
    void cleanup() {
        for (auto &pinnedBFPtr : h_output) {
            gpuErrchk(cudaHostUnregister(pinnedBFPtr));
        }
        h_output.clear();
    }

    /**
     * @brief Initialize resources after modifying crop specs.
     */
    void initializeResources() {
        if (reconSpec.cropBF) {
            // Device
            if (d_bfCropped == nullptr) {
                gpuErrchk(
                    cudaMalloc(&d_bfCropped, bfSizeCropped * sizeof(float2)));
            } else {
                gpuErrchk(cudaFree(d_bfCropped));
                gpuErrchk(
                    cudaMalloc(&d_bfCropped, bfSizeCropped * sizeof(float2)));
            }

            // Host pinned, one copy per slot.
            const size_t croppedRingBytes =
                static_cast<size_t>(mSlotsCropped) *
                slotStride(bfSizeCropped) * sizeof(float2);
            if (pinnedBFCroppedBase != nullptr) {
                gpuErrchk(cudaFreeHost(pinnedBFCroppedBase));
            }
            gpuErrchk(
                cudaMallocHost((void **)&pinnedBFCroppedBase, croppedRingBytes));
            refreshStorageViews();
        }
    }

    /**
     * @brief Update cropping specifications and reinitialize resources.
     * @param newReconSpec New reconstruction specification.
     */
    void updateCropSpecs(ReconSpec &newReconSpec) {
        reconSpec.cropBF = newReconSpec.cropBF;
        reconSpec.nSamplesCropBot = newReconSpec.nSamplesCropBot;
        reconSpec.nSamplesCropTop = newReconSpec.nSamplesCropTop;
        reconSpec.nChannelsCropLeft = newReconSpec.nChannelsCropLeft;
        reconSpec.nChannelsCropRight = newReconSpec.nChannelsCropRight;

        reconSpec.nSamplesReduced =
            reconSpec.nSamplesCropBot - reconSpec.nSamplesCropTop + 1;
        reconSpec.nChannelsReduced =
            reconSpec.nChannelsCropRight - reconSpec.nChannelsCropLeft + 1;
        reconSpec.totalSizeCropped =
            reconSpec.nSamplesReduced * reconSpec.nChannelsReduced;

        // Recalculate sizes based on new specs
        bfSize = reconSpec.totalSize * reconSpec.ensembleSize;
        bfSizeCropped = reconSpec.totalSizeCropped * reconSpec.ensembleSize;

        // Reinitialize GPU resources
        initializeResources();
    }

    /**
     * @brief Convert BF to output type.
     * @param d_bf BF in GPU memory.
     * @param cropBF Whether to crop the BF data.
     */
    void BF2OutputType(bfType_t *d_bf, bool cropBF) {
        this->d_bf = d_bf;

        if (cropBF) {
            int threadsPerBlock = 256;
            dim3 dimBlock(threadsPerBlock, 1, 1);
            dim3 dimGrid(
                (reconSpec.nSamplesReduced * reconSpec.nChannelsReduced *
                     receiveSpec.nRepeats +
                 threadsPerBlock - 1) /
                    threadsPerBlock,
                1, 1);

            // Kernel params are (nChannels=lateral=nx, nSamples=axial=nz); the
            // lateral stride used inside the kernel is nSamples (= nz).
            crop_BF<<<dimGrid, dimBlock>>>(
                d_bf, d_bfCropped, reconSpec.nx, reconSpec.nz,
                receiveSpec.nRepeats, reconSpec.totalSizeCropped,
                reconSpec.nSamplesReduced, reconSpec.nChannelsReduced,
                reconSpec.nSamplesCropTop, reconSpec.nSamplesCropBot,
                reconSpec.nChannelsCropLeft, reconSpec.nChannelsCropRight);
        }
        // get BF magnitude if output is real, while BF is complex
        if (std::is_same_v<bfType_t, float2> &&
            std::is_same_v<outputType_t, float>) {
            int threadsPerBlock = 1024;
            int blocksPerGrid =
                (bfSize + threadsPerBlock - 1) / threadsPerBlock;
            getMagnitude_kernel<<<blocksPerGrid, threadsPerBlock>>>(
                reinterpret_cast<float *>(d_output),
                reinterpret_cast<const float2 *>(d_bf), bfSize);

        } else if (std::is_same_v<bfType_t, outputType_t>) {
            d_output = reinterpret_cast<outputType_t *>(d_bf);
        } else
            throw std::runtime_error(
                "BFFormatter: BF/Output types specified are not implemented\n");
    }

    /**
     * @brief Copy output data from device to host.
     * @param output Host pointer to receive output data.
     */
    void getOutput(outputType_t *output) {
        gpuErrchk(cudaMemcpy(output, d_output, bfSize * sizeof(outputType_t),
                             cudaMemcpyDeviceToHost));
    }

    /**
     * @brief Compute and copy B-mode output from device to host.
     */
    void getOutputBmode() {
        // Perform matrix-vector multiplication to calculate the mean along the
        // nRepeats dimension
        cublasSgemv(cublas_handle, CUBLAS_OP_N, reconSpec.totalSize,
                    receiveSpec.nRepeats, &alpha_mean, d_output,
                    reconSpec.totalSize, d_weights, 1, &beta_mean,
                    d_mean_output, 1);

        // Copy the B-mode output data from device to host
        gpuErrchk(cudaMemcpy(pinnedBmode, d_mean_output,
                             reconSpec.totalSize * sizeof(float),
                             cudaMemcpyDeviceToHost));
    }

    /**
     * @brief Copy complex output from device to host.
     */
    void getComplexOutput() {
        // Advance before filling, so pinnedBF names this frame's buffer for
        // both the storeBuffer call and the pointer returned to MATLAB.
        mStorageSlot = (mStorageSlot + 1) % (mSlotsFull > mSlotsCropped
                                                 ? mSlotsFull
                                                 : mSlotsCropped);
        refreshStorageViews();

        // Perform the memory copy
        gpuErrchk(cudaMemcpy(pinnedBF, d_bf, bfSize * sizeof(bfType_t),
                             cudaMemcpyDeviceToHost));
    }

    /**
     * @brief Copy cropped BF data from device to host.
     */
    void getCroppedBF() {
        gpuErrchk(cudaMemcpy(
            pinnedBFCropped, d_bfCropped,
            receiveSpec.nRepeats * reconSpec.totalSizeCropped * sizeof(float2),
            cudaMemcpyDeviceToHost));
    }

    /**
     * @brief Get the output pointer (device BF pointer).
     * @return bfType_t* Device BF pointer.
     */
    bfType_t *getOutputPointer() const { return d_bf; }

    /**
     * @brief Allocate and convert data to half2 format.
     * @param d_float2Data Device pointer to float2 data.
     */
    void convertToHalf2(float2 *d_float2Data) {
        // Allocate device memory for the half2 array
        if (d_half2Data != nullptr) {
            cudaFree(d_half2Data);
        }
        cudaMalloc(&d_half2Data, bfSize * sizeof(half2));

        // Calculate grid and block sizes
        int threadsPerBlock = 256;  // This is a typical value; adjust as needed
        int blocksPerGrid = (bfSize + threadsPerBlock - 1) / threadsPerBlock;

        // Launch the kernel to convert float2 to half2
        convertFloat2ToHalf2<<<blocksPerGrid, threadsPerBlock>>>(
            d_float2Data, d_half2Data, bfSize);
        cudaDeviceSynchronize();  // Wait for the conversion to finish
    }

    /**
     * @brief Allocate and convert data to bfloat16 format.
     * @param d_float2Data Device pointer to float2 data.
     */
    void convertToBfloat162(float2 *d_float2Data) {
        // Allocate device memory for the half2 array
        if (d_bfloat162Data != nullptr) {
            cudaFree(d_bfloat162Data);
        }
        cudaMalloc(&d_bfloat162Data, bfSize * sizeof(nv_bfloat162));

        // Calculate grid and block sizes
        int threadsPerBlock = 256;  // This is a typical value; adjust as needed
        int blocksPerGrid = (bfSize + threadsPerBlock - 1) / threadsPerBlock;

        // Launch the kernel to convert float2 to half2
        convertFloat2ToBfloat162<<<blocksPerGrid, threadsPerBlock>>>(
            d_float2Data, d_bfloat162Data, bfSize);
        cudaDeviceSynchronize();  // Wait for the conversion to finish
    }

    /**
     * @brief Get the device pointer to half2 data.
     * @return half2* Device pointer.
     */
    half2 *getHalf2DataPointer() const { return d_half2Data; }

    /**
     * @brief Get the device pointer to bfloat16 data.
     * @return nv_bfloat162* Device pointer.
     */
    nv_bfloat162 *getBfloat162DataPointer() const { return d_bfloat162Data; }
};
}  // namespace Beamform
