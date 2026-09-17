/**
 * @file pdi_kernels.cu
 * @author BrainEcho Lab
 * @brief CUDA Kernel definitions for PDI
 * @details This file contains the definitions of CUDA kernels used for
 * Power Doppler Imaging (PDI) processing. The kernels include functions for
 * thresholding singular values, converting real arrays to complex arrays,
 * calculating absolute values of complex matrices, and cropping 2D matrices.
 * The kernels are designed to be used with the PDI class, which performs
 * PDI on beamformed data using CUDA.
 * @version 0.1
 * @date 2025-01-30
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "pdi_kernels.cuh"

#include <cmath>
#include <iostream>
#include <string>

#include <cuda_runtime.h>

__global__ void threshold_singular_values(float *s, int32_t threshold) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < threshold) {
        s[i] = 0.0f;
    }
}

__global__ void copyRealToComplex(const float *src, float2 *dst, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx].x = src[idx];
        dst[idx].y = 0.0f;
    }
}

__global__ void absComplex(float2 *in, float *out, int m, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int idy = blockIdx.y * blockDim.y + threadIdx.y;

    if (idx < m && idy < n) {
        int index = idy * m + idx;
        float2 val = in[index];
        out[index] = val.x * val.x + val.y * val.y;
    }
}

__global__ void cropPDIkernel(float *input, float *output, int32_t nChannels,
                              int32_t nSamples, int32_t totalSizeCropped,
                              int32_t nSamplesReduced,
                              int32_t nChannelsReduced,
                              int32_t nSamplesCropTop,
                              int32_t nSamplesCropBot,
                              int32_t nChannelsCropLeft,
                              int32_t nChannelsCropRight) {
    int32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < totalSizeCropped) {
        // Calculate (col, row) in the CROPPED space
        int32_t col = idx / nSamplesReduced;
        int32_t row = idx % nSamplesReduced;

        // Map back to the input (un-cropped) coordinates
        int32_t input_col = col + nChannelsCropLeft;
        int32_t input_row = row + nSamplesCropTop;
        int32_t input_idx = input_col * nSamples + input_row;
        output[idx] = input[input_idx];
    }
}
