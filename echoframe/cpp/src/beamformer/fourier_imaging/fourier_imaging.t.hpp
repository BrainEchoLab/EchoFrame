/**
 * @file fourier_imaging.t.hpp
 * @author BrainEcho Lab
 * @brief Fourier Imaging Beamformer Template Implementations
 * @details This file implements the template member functions for the
 * FourierImaging class in EchoFrame. It provides move semantics, GPU memory
 * management, cuFFT planning, initialization, cleanup, and the main processing
 * logic for Fourier-based beamforming and reconstruction workflows.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "fourier_imaging.h"

#include <iostream>

#include "fourier_imaging_kernels.cuh"

namespace Beamform {

template <typename bfType_t>
FourierImaging<bfType_t>::~FourierImaging() {
    if (mInitialized) {
        clearGPU();
    }
}

template <typename bfType_t>
void FourierImaging<bfType_t>::initialize() {
    initGPU();
}

template <typename bfType_t>
FourierImaging<bfType_t>::FourierImaging(FourierImaging &&x) noexcept {
    // Beamformer base class
    this->receiveSpec = std::move(x.receiveSpec);
    this->reconSpec = std::move(x.reconSpec);

    this->d_rfFormatted = x.d_rfFormatted;
    this->d_RF = x.d_RF;
    this->d_BF = x.d_BF;

    this->mUsedGPUMem = x.mUsedGPUMem;

    this->initialized = x.initialized;
    x.initialized = false;

    // FourierImaging class
    fourierReconSpec = std::move(x.fourierReconSpec);
    d_RFPadded = x.d_RFPadded;
    d_RFFourier = x.d_RFFourier;

    // CUFFT
    mFftFastTimePlan = x.mFftFastTimePlan;
    mFftChannelsPlan = x.mFftChannelsPlan;
    mIfftBFPlan = x.mIfftBFPlan;

    mInitialized = x.mInitialized;
    x.mInitialized = false;
}

template <typename bfType_t>
FourierImaging<bfType_t> &FourierImaging<bfType_t>::operator=(
    FourierImaging &&x) noexcept {
    // Beamformer base class
    this->receiveSpec = std::move(x.receiveSpec);
    this->reconSpec = std::move(x.reconSpec);

    this->d_rfFormatted = x.d_rfFormatted;
    this->d_RF = x.d_RF;
    this->d_BF = x.d_BF;

    this->mUsedGPUMem = x.mUsedGPUMem;

    this->initialized = x.initialized;
    x.initialized = false;

    // FourierImaging class
    fourierReconSpec = std::move(x.fourierReconSpec);
    d_RFPadded = x.d_RFPadded;
    d_RFFourier = x.d_RFFourier;

    // CUFFT
    mFftFastTimePlan = x.mFftFastTimePlan;
    mFftChannelsPlan = x.mFftChannelsPlan;
    mIfftBFPlan = x.mIfftBFPlan;

    mInitialized = x.mInitialized;
    x.mInitialized = false;

    return *this;
}

template <typename bfType_t>
void FourierImaging<bfType_t>::initGPU() {
    fourierReconSpec.nz = this->reconSpec.nz;
    fourierReconSpec.nx = this->reconSpec.nx;
    fourierReconSpec.totalSize = this->reconSpec.totalSize;

    // allocate reconstruction properties
    gpuErrchk(cudaMalloc(&fourierReconSpec.d_delayIndices,
                         this->receiveSpec.nFastTimeSamples *
                             this->receiveSpec.nChannels *
                             this->receiveSpec.nTX * sizeof(int32_t)));
    gpuErrchk(cudaMalloc(&fourierReconSpec.d_interpolationWeights,
                         this->receiveSpec.nFastTimeSamples *
                             this->receiveSpec.nChannels *
                             this->receiveSpec.nTX * sizeof(float2)));
    gpuErrchk(cudaMalloc(&fourierReconSpec.d_frequencyAxis,
                         this->receiveSpec.nFastTimeSamples * sizeof(float)));
    gpuErrchk(cudaMalloc(&fourierReconSpec.d_planewaveDelays,
                         2 * this->receiveSpec.nTX * sizeof(float)));
    gpuErrchk(cudaMalloc(&fourierReconSpec.d_tgcVector,
                         this->receiveSpec.nFastTimeSamples * sizeof(float)));

    // copy reconstruction properties
    gpuErrchk(cudaMemcpy(
        fourierReconSpec.d_delayIndices, fourierReconSpec.delayIndices,
        this->receiveSpec.nFastTimeSamples * this->receiveSpec.nChannels *
            this->receiveSpec.nTX * sizeof(int32_t),
        cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(fourierReconSpec.d_interpolationWeights,
                         fourierReconSpec.interpolationWeights,
                         this->receiveSpec.nFastTimeSamples *
                             this->receiveSpec.nChannels *
                             this->receiveSpec.nTX * sizeof(float2),
                         cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(fourierReconSpec.d_frequencyAxis,
                         fourierReconSpec.frequencyAxis,
                         this->receiveSpec.nFastTimeSamples * sizeof(float),
                         cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(
        fourierReconSpec.d_planewaveDelays, fourierReconSpec.planewaveDelays,
        2 * this->receiveSpec.nTX * sizeof(float), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(fourierReconSpec.d_tgcVector,
                         fourierReconSpec.tgcVector,
                         this->receiveSpec.nFastTimeSamples * sizeof(float),
                         cudaMemcpyHostToDevice));

    // allocate padded RF
    gpuErrchk(cudaMalloc(&d_RFPadded, this->receiveSpec.nFastTimeSamples *
                                          this->receiveSpec.nTX *
                                          this->receiveSpec.nSlowTimeSamples *
                                          this->receiveSpec.nChannels *
                                          sizeof(bfType_t)));
    // pad with zeros left and right
    float paddingSize = static_cast<float>(this->receiveSpec.nChannels) -
                        static_cast<float>(this->receiveSpec.nActiveChannels);
    int paddingSizeL = floorf(paddingSize / 2);
    int paddingSizeR = ceilf(paddingSize / 2);
    size_t rfRows = this->receiveSpec.nFastTimeSamples * this->receiveSpec.nTX *
                    this->receiveSpec.nSlowTimeSamples;
    gpuErrchk(
        cudaMemset(d_RFPadded, 0, rfRows * paddingSizeL * sizeof(bfType_t)));
    int offsetR = rfRows * (paddingSizeL + this->receiveSpec.nActiveChannels);
    gpuErrchk(cudaMemset(&d_RFPadded[offsetR], 0,
                         rfRows * paddingSizeR * sizeof(bfType_t)));

    // allocate RF for FFT over channels result
    // note: we choose not to store the result in the d_RFPadded in-place
    // because it would mess up the
    //  zero-paddings and we would have to use a cudaMemset to zero-initialize
    //  it everytime, so this choice saves a bit of computation time in expense
    //  of memory
    gpuErrchk(cudaMalloc(&d_RFFourier, this->receiveSpec.nFastTimeSamples *
                                           this->receiveSpec.nTX *
                                           this->receiveSpec.nSlowTimeSamples *
                                           this->receiveSpec.nChannels *
                                           sizeof(bfType_t)));

    // 1D FFT over fast-time
    int nxFastTime = this->receiveSpec.nFastTimeSamples;
    int nBatchesXFastTime = this->receiveSpec.nTX *
                            this->receiveSpec.nSlowTimeSamples *
                            this->receiveSpec.nActiveChannels;
    if (std::is_same_v<bfType_t, float2>) {
        cufftErrchk(cufftPlan1d(&mFftFastTimePlan, nxFastTime, CUFFT_C2C,
                                nBatchesXFastTime));
    }
    else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT planning\n");

    // 1D FFT over channels
    int rankC = 1;  // 1D FFT
    int inembedC[] = {0};
    int onembedC[] = {0};  // ignored in 1D FFT
    // number of elements in each batch
    int nC[] = {this->receiveSpec.nChannels};
    // stride between elements
    int channelStride = this->receiveSpec.nFastTimeSamples *
                        this->receiveSpec.nTX *
                        this->receiveSpec.nSlowTimeSamples;
    int istrideC = channelStride;
    int ostrideC = channelStride;
    // distance between first elements between batches
    int idistC = 1;
    int odistC = 1;
    int nBatchesC = channelStride;  // number of batches

    if (std::is_same_v<bfType_t, float2> || std::is_same_v<bfType_t, float>) {
        cufftErrchk(cufftPlanMany(&mFftChannelsPlan, rankC, nC, inembedC,
                                  istrideC, idistC, onembedC, ostrideC, odistC,
                                  CUFFT_C2C, nBatchesC));
    } else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT planning\n");

    // 2D IFFT over Nx x Nz
    int rankBF = 2;  // 2D IFFT
    int inembedBF[] = {this->reconSpec.nx, this->reconSpec.nz};
    int onembedBF[] = {this->reconSpec.nx, this->reconSpec.nz};
    // number of elements in each batch
    int nBF[] = {this->reconSpec.nx, this->reconSpec.nz};
    // stride between elements
    int istrideBF = 1;
    int ostrideBF = 1;
    // distance first elements of batches
    int idistBF = this->reconSpec.nz * this->reconSpec.nx;
    int odistBF = this->reconSpec.nz * this->reconSpec.nx;
    int nBatchesBF = this->reconSpec.ensembleSize;  // number of batches

    if (std::is_same_v<bfType_t, float2> || std::is_same_v<bfType_t, float>) {
        cufftErrchk(cufftPlanMany(&mIfftBFPlan, rankBF, nBF, inembedBF,
                                  istrideBF, idistBF, onembedBF, ostrideBF,
                                  odistBF, CUFFT_C2C, nBatchesBF));
    } else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT planning\n");
}

template <typename bfType_t>
void FourierImaging<bfType_t>::clearGPU() {
    gpuErrchk(cudaFree(fourierReconSpec.d_delayIndices));
    gpuErrchk(cudaFree(fourierReconSpec.d_interpolationWeights));
    gpuErrchk(cudaFree(fourierReconSpec.d_frequencyAxis));
    gpuErrchk(cudaFree(fourierReconSpec.d_planewaveDelays));
    gpuErrchk(cudaFree(fourierReconSpec.d_tgcVector));

    gpuErrchk(cudaFree(d_RFPadded));
    gpuErrchk(cudaFree(d_RFFourier));

    // CUFFT
    cufftErrchk(cufftDestroy(mFftFastTimePlan));
    cufftErrchk(cufftDestroy(mFftChannelsPlan));
    cufftErrchk(cufftDestroy(mIfftBFPlan));
}

template <typename bfType_t>
void FourierImaging<bfType_t>::process() {
    // Step 1: apply padding over the RF channels
    // This is done to have 2^N channels (reconSpec.nChannels == 2^N) for the
    // FFTs If number of active channels / 2 is not integer, pad with floor on
    // the
    //  left and ceil on the right to get 2^N channels
    // In practice, the zero-padding is already applied to a pre-allocated
    // buffer,
    //  and all we have to do is copy the RF (GPU) to the middle of that buffer
    //  (also GPU)
    float paddingSize = static_cast<float>(this->receiveSpec.nChannels) -
                        static_cast<float>(this->receiveSpec.nActiveChannels);
    int paddingSizeL = floorf(paddingSize / 2);
    size_t rfRows = this->receiveSpec.nFastTimeSamples * this->receiveSpec.nTX *
                    this->receiveSpec.nSlowTimeSamples;
    gpuErrchk(cudaMemcpy(
        &d_RFPadded[rfRows * paddingSizeL], this->d_RF,
        rfRows * this->receiveSpec.nActiveChannels * sizeof(bfType_t),
        cudaMemcpyDeviceToDevice));

    // Step 2: apply proper weighting to RF according to Time-Gain Compensation
    // (TGC) only apply to the non-padded area, since the rest is zeroes
    int threadsPerBlock = 512;
    dim3 dimGrid(
        rfRows * this->receiveSpec.nActiveChannels / threadsPerBlock + 1, 1, 1);
    dim3 dimBlock(threadsPerBlock, 1, 1);
    TGCWeighting_kernel<<<dimGrid, dimBlock>>>(
        &d_RFPadded[rfRows * paddingSizeL], fourierReconSpec.d_tgcVector,
        this->receiveSpec);

    // Step 3: 1D FFT over fast-time
    // only apply to the non-padded area, since the rest is zeroes
    if (std::is_same_v<bfType_t, float2>) {
        cufftErrchk(cufftExecC2C(
            mFftFastTimePlan,
            reinterpret_cast<float2 *>(&d_RFPadded[rfRows * paddingSizeL]),
            reinterpret_cast<float2 *>(&d_RFPadded[rfRows * paddingSizeL]),
            CUFFT_FORWARD));
    }
    else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT execution over fast-time\n");

    // Step 4: delay every sample according to the planewave angle
    // only apply to the non-padded area, since the rest is zeroes
    threadsPerBlock = 512;
    dimGrid = {
        static_cast<unsigned int>(rfRows) *
                static_cast<unsigned int>(this->receiveSpec.nActiveChannels) /
                threadsPerBlock +
            1,
        1, 1};
    dimBlock = {static_cast<unsigned int>(threadsPerBlock), 1, 1};

    delayWave_kernel<<<dimGrid, dimBlock>>>(
        reinterpret_cast<float2 *>(&d_RFPadded[rfRows * paddingSizeL]),
        fourierReconSpec.d_planewaveDelays,
        &fourierReconSpec.d_planewaveDelays[this->receiveSpec.nTX],
        fourierReconSpec.d_frequencyAxis, paddingSizeL * rfRows,
        this->receiveSpec);

    // Step 5: 1D FFT over channels
    // either if the bfType_t is complex or real, the RF should have become
    // complex after running the first FFT
    if (std::is_same_v<bfType_t, float2> || std::is_same_v<bfType_t, float>) {
        cufftErrchk(cufftExecC2C(
            mFftChannelsPlan, reinterpret_cast<float2 *>(d_RFPadded),
            reinterpret_cast<float2 *>(d_RFFourier), CUFFT_FORWARD));
    } else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT execution over channels\n");

    // Step 6: Beamform using nearest neighbour indexing and linear phase
    // weighting
    //  also compound the angles and expand/truncate samples and channels to
    //  nz and nx, respectively

    // Interpolate and pad/truncate the array with trailing zeros
    // d_BF is zero-initialized for the 2D IFFT in the next step, because not
    // all of its space will be computed here
    gpuErrchk(cudaMemset(this->d_BF, 0,
                         this->reconSpec.totalSize *
                             this->reconSpec.ensembleSize * sizeof(bfType_t)));

    threadsPerBlock = 512;
    dimGrid = {
        static_cast<unsigned int>(this->receiveSpec.nFastTimeSamples) *
                static_cast<unsigned int>(this->receiveSpec.nChannels) *
                static_cast<unsigned int>(this->receiveSpec.nSlowTimeSamples) /
                threadsPerBlock +
            1,
        1, 1};
    dimBlock = {static_cast<unsigned int>(threadsPerBlock), 1, 1};

    interpFastTimeCompoundAndPad_kernel<<<dimGrid, dimBlock>>>(
        reinterpret_cast<float2 *>(this->d_BF),
        reinterpret_cast<float2 *>(d_RFFourier),
        fourierReconSpec.d_delayIndices,
        fourierReconSpec.d_interpolationWeights, this->receiveSpec,
        this->reconSpec.nz, this->reconSpec.nx);

    // Step 7: Go back to spatial domain using zero padding in frequency domain
    // to get interpolated frames
    //  and also compound the different angle views (transmissions)

    // either if the bfType_t is complex or real, the RF should have become
    // complex after running the first FFT
    if (std::is_same_v<bfType_t, float2> || std::is_same_v<bfType_t, float>) {
        cufftErrchk(cufftExecC2C(
            mIfftBFPlan, reinterpret_cast<float2 *>(this->d_BF),
            reinterpret_cast<float2 *>(this->d_BF), CUFFT_INVERSE));
    } else
        throw std::runtime_error(
            "Fourier Imaging initialization: data type specified is not "
            "implemented during cuFFT execution over channels\n");

    gpuErrchk(cudaDeviceSynchronize());
}

}  // namespace Beamform