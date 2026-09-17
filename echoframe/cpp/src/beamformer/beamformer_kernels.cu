/**
 * @file beamformer_kernels.cu
 * @author BrainEcho Lab
 * @brief Beamformer CUDA Kernels Implementation
 * @details This file implements CUDA kernels for RF data formatting,
 * conversion operations in the EchoFrame pipeline. It includes
 * kernels for converting raw RF data to complex or real formats, computing
 * magnitudes, converting between floating-point types, and cropping beamformed
 * data on the GPU. These kernels are used throughout the beamforming and
 * post-processing stages for efficient GPU-accelerated computation.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "beamformer_kernels.h"

#include <cuComplex.h>

namespace Beamform {
template <typename rfType_t>
__global__ void formatRf_kernel(float2 *rfFormatted, const rfType_t *rfRaw,
                                const Beamform::ReceiveSpec rcv) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    int rowsIQ = rcv.nSamplesIQ * rcv.nTX * rcv.nRepeats;
    if (idx >= rowsIQ) return;

    // filter out inactive channels (elements)
    for (int i = 0; i < rcv.nActiveChannels; i++) {
        // Make complex IQ by negating imaginary part
        rfFormatted[idx + i * rowsIQ] = {
            static_cast<float>(
                rfRaw[2 * (idx + rcv.d_activeChannelMap[i] * rowsIQ)]),
            -static_cast<float>(
                rfRaw[2 * (idx + rcv.d_activeChannelMap[i] * rowsIQ) + 1])};
    }
}

/// @cond  Explicit instantiation; Sphinx cannot parse a bare `template`.
template __global__ void formatRf_kernel(float2 *rfFormatted,
                                         const int16_t *rfRaw,
                                         const Beamform::ReceiveSpec rcv);
/// @endcond

template <typename rfType_t>
__global__ void formatRf_kernel(float *rfFormatted, const rfType_t *rfRaw,
                                const Beamform::ReceiveSpec rcv) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    int rows = rcv.nSamples * rcv.nTX * rcv.nRepeats;
    if (idx >= rows) return;

    // filter out inactive channels (elements)
    for (int i = 0; i < rcv.nActiveChannels; i++) {
        rfFormatted[idx + i * rows] =
            static_cast<float>(rfRaw[idx + rcv.d_activeChannelMap[i] * rows]);
    }
}

/// @cond  Explicit instantiation; Sphinx cannot parse a bare `template`.
template __global__ void formatRf_kernel(float *rfFormatted,
                                         const int16_t *rfRaw,
                                         const Beamform::ReceiveSpec rcv);
/// @endcond

__global__ void getMagnitude_kernel(float *output, const float2 *input,
                                    size_t size) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;

    if (idx >= size) return;

    output[idx] = cuCabsf(input[idx]);
}

__global__ void convertFloat2ToHalf2(const float2 *input, half2 *output,
                                     size_t size) {
    int idx = threadIdx.x + blockDim.x * blockIdx.x;

    if (idx >= size) return;

    output[idx] = __float22half2_rn(input[idx]);
}

__global__ void convertFloat2ToBfloat162(const float2 *input,
                                         nv_bfloat162 *output, size_t size) {
    int idx = threadIdx.x + blockDim.x * blockIdx.x;

    if (idx >= size) return;

    output[idx] = __float22bfloat162_rn(input[idx]);
}

__global__ void crop_BF(float2 *input, float2 *output, int32_t nChannels,
                        int32_t nSamples, int32_t nEnsembles,
                        int32_t totalSizeCropped, int32_t nSamplesReduced,
                        int32_t nChannelsReduced, int32_t nSamplesCropTop,
                        int32_t nSamplesCropBot, int32_t nChannelsCropLeft,
                        int32_t nChannelsCropRight) {
    int32_t idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < totalSizeCropped * nEnsembles) {
        // Calculate this thread's position within the cropped area
        int32_t ensemble_idx = idx / totalSizeCropped;
        int32_t pixel_within_ensemble = idx % totalSizeCropped;
        int32_t col = pixel_within_ensemble / nSamplesReduced;
        int32_t row = pixel_within_ensemble % nSamplesReduced;

        // Calculate correct index
        int32_t input_col = col + nChannelsCropLeft;
        int32_t input_row = row + nSamplesCropTop;

        // Find input index for column-major BF
        int32_t input_idx = ensemble_idx * (nSamples * nChannels) +
                            input_col * nSamples + input_row;

        // Copy data in cropped BF
        output[idx] = input[input_idx];
    }
}

}  // namespace Beamform