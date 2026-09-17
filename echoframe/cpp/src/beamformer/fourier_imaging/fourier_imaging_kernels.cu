/**
 * @file fourier_imaging_kernels.cu
 * @author BrainEcho Lab
 * @brief Fourier Imaging CUDA Kernels Implementation
 * @details This file implements CUDA kernels for Fourier-based imaging
 * operations in the EchoFrame pipeline. It includes kernels for time-gain
 * compensation (TGC), delay application, fast-time interpolation, compounding,
 * zero-padding, and in-place scaling of RF and beamformed data on the GPU.
 * These kernels enable efficient GPU-accelerated computation for advanced
 * Fourier imaging workflows.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "fourier_imaging_kernels.cuh"

#include <cstdint>

#include "gsl/gsl"

namespace Beamform {
__global__ void TGCWeighting_kernel(float2 *RF, const float *tgcVector,
                                    ReceiveSpec receiveSpec) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= receiveSpec.nFastTimeSamples * receiveSpec.nTX *
                   receiveSpec.nSlowTimeSamples * receiveSpec.nActiveChannels)
        return;

    int tgcIdx = idx % receiveSpec.nFastTimeSamples;
    float2 tgcComplex = {tgcVector[tgcIdx], 0};

    RF[idx] = cuCmulf(tgcComplex, RF[idx]);
}

__global__ void TGCWeighting_kernel(float *RF, const float *tgcVector,
                                    ReceiveSpec receiveSpec) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= receiveSpec.nFastTimeSamples * receiveSpec.nTX *
                   receiveSpec.nSlowTimeSamples * receiveSpec.nActiveChannels)
        return;

    int tgcIdx = idx % receiveSpec.nFastTimeSamples;

    RF[idx] = tgcVector[tgcIdx] * RF[idx];
}

__global__ void delayWave_kernel(float2 *RF, const float *delaysAx,
                                 const float *delaysB,
                                 const float *frequencyAxis, int padding,
                                 ReceiveSpec receiveSpec) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= receiveSpec.nFastTimeSamples * receiveSpec.nTX *
                   receiveSpec.nSlowTimeSamples * receiveSpec.nActiveChannels)
        return;

    // get subscripts of this RF index
    const unsigned int nDim = 4;
    int sub[nDim];
    int strides[nDim];
    strides[0] = 1;
    strides[1] = receiveSpec.nFastTimeSamples * strides[0];
    strides[2] = receiveSpec.nTX * strides[1];
    strides[3] = receiveSpec.nSlowTimeSamples * strides[2];
    // add padding to idx since only the middle (non-zero) part of the RF is
    // passed here
    ind2subV2(sub, idx + padding, strides, 4);

    float delayD =
        delaysAx[sub[1]] * (sub[3] + 1) + delaysB[sub[1]];  // delay of element
    float delayK = frequencyAxis[sub[0]] * delayD;  // frequency bin of sample
    float2 delay = {cosf(delayK), sinf(delayK)};

    RF[idx] = cuCmulf(delay, RF[idx]);
}

__global__ void interpFastTimeAndCompound_kernel(float2 *RFOutput,
                                                 const float2 *RFInput,
                                                 const int32_t *delayIndices,
                                                 const float2 *weights,
                                                 ReceiveSpec receiveSpec) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= receiveSpec.nFastTimeSamples * receiveSpec.nChannels *
                   receiveSpec.nSlowTimeSamples)
        return;

    // RF input strides
    // Dims: Fast-time x Transmissions x Slow-time x Channels
    int stridesIn[4];
    stridesIn[0] = 1;
    stridesIn[1] = stridesIn[0] * receiveSpec.nFastTimeSamples;
    stridesIn[2] = stridesIn[1] * receiveSpec.nTX;
    stridesIn[3] = stridesIn[2] * receiveSpec.nSlowTimeSamples;

    // RF output strides
    // Dims: Fast-time x Channels x Slow-Time
    const unsigned int nDim = 3;
    int sub[nDim];
    int stridesOut[nDim];
    stridesOut[0] = 1;
    stridesOut[1] = stridesOut[0] * receiveSpec.nFastTimeSamples;
    stridesOut[2] = stridesOut[1] * receiveSpec.nChannels;
    // get subscripts of this RF output index
    ind2subV2(sub, idx, stridesOut, nDim);

    float2 compoundSample{0, 0};
    for (gsl::index i = 0; i < receiveSpec.nTX; i++) {
        // Indices Dims: Fast-time x Channels x Transmissions
        unsigned int neighbourIdx =
            stridesOut[0] * sub[0] + stridesOut[1] * sub[1] + stridesOut[2] * i;
        unsigned int sampleDelayIdx = delayIndices[neighbourIdx];

        // interpolate samples in the neighbourhood by multiplying with proper
        // weights
        unsigned int rfDelayIdx = stridesIn[0] * sampleDelayIdx +
                                  stridesIn[1] * i + stridesIn[2] * sub[2] +
                                  stridesIn[3] * sub[1];
        float2 sample = cuCmulf(weights[neighbourIdx], RFInput[rfDelayIdx]);

        compoundSample = cuCaddf(compoundSample, sample);
    }
    RFOutput[idx] = compoundSample;
}

__global__ void interpFastTimeCompoundAndPad_kernel(
    float2 *BFOutput, const float2 *RFInput, const int32_t *delayIndices,
    const float2 *weights, ReceiveSpec receiveSpec, const int32_t nz,
    const int32_t nx) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= receiveSpec.nFastTimeSamples * receiveSpec.nChannels *
                   receiveSpec.nSlowTimeSamples)
        return;

    // RF input strides
    // Dims: Fast-time x Transmissions x Slow-time x Channels
    int stridesRF[4];
    stridesRF[0] = 1;
    stridesRF[1] = stridesRF[0] * receiveSpec.nFastTimeSamples;
    stridesRF[2] = stridesRF[1] * receiveSpec.nTX;
    stridesRF[3] = stridesRF[2] * receiveSpec.nSlowTimeSamples;

    // BF output strides
    // Dims: Nx x Nz x Slow-Time (ensemble size)
    int stridesBF[3];
    stridesBF[0] = 1;
    stridesBF[1] = stridesBF[0] * nz;
    stridesBF[2] = stridesBF[1] * nx;

    // Delay indices / weights strides
    // Dims: Fast-time x Channels x Transmissions
    const unsigned int nDim = 3;
    int sub[nDim];
    int stridesInds[nDim];
    stridesInds[0] = 1;
    stridesInds[1] = stridesInds[0] * receiveSpec.nFastTimeSamples;
    stridesInds[2] = stridesInds[1] * receiveSpec.nChannels;
    // get subscripts of the indices' dimensions, because these will be used for
    // the delays/weights, RF and BF
    ind2subV2(sub, idx, stridesInds, nDim);

    // padding
    // put the zero-padding in the middle of the frequency field
    // this is needed for the IFFT later
    int xBounds = (nz - receiveSpec.nFastTimeSamples) / 2;
    int x = (sub[0] < xBounds) ? sub[0] : sub[0] + xBounds * 2;
    int zBounds = (nx - receiveSpec.nChannels) / 2;
    int z = (sub[1] < zBounds) ? sub[1] : sub[1] + zBounds * 2;

    float2 compoundSample{0, 0};
    for (gsl::index i = 0; i < receiveSpec.nTX; i++) {
        unsigned int neighbourIdx = stridesInds[0] * sub[0] +
                                    stridesInds[1] * sub[1] +
                                    stridesInds[2] * i;
        unsigned int sampleDelayIdx = delayIndices[neighbourIdx];

        // interpolate samples in the neighbourhood by multiplying with proper
        // weights
        unsigned int rfDelayIdx = stridesRF[0] * sampleDelayIdx +
                                  stridesRF[1] * i + stridesRF[2] * sub[2] +
                                  stridesRF[3] * sub[1];
        float2 sample = cuCmulf(weights[neighbourIdx], RFInput[rfDelayIdx]);

        compoundSample = cuCaddf(compoundSample, sample);
    }

    int bfIdx = stridesBF[0] * x + stridesBF[1] * z + stridesBF[2] * sub[2];
    BFOutput[bfIdx] = compoundSample;
}

__host__ __device__ void ind2subV2(int *sub, int idx, const int *strides,
                                   int ndim) {
    int nidx = idx;
    if (ndim > 2) {
        // construct subscript for all dimensions except first 2
        for (int i = ndim - 1; i > 1; i--) {
            int vi = nidx % strides[i];
            int vj = (nidx - vi) / strides[i];
            sub[i] = vj;
            nidx = vi;
        }
    }

    if (ndim >= 2) {
        int v1 = nidx % strides[1];
        sub[1] = (nidx - v1) / strides[1];
        sub[0] = v1;
    } else {
        sub[0] = nidx;
    }
}
}  // namespace Beamform