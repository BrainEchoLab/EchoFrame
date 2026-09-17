/**
 * @file beamformer_kernels.h
 * @author BrainEcho Lab
 * @brief Beamformer CUDA Kernels (Header)
 * @details This header declares CUDA kernels for RF data formatting,
 * conversion, and beamforming operations in the EchoFrame pipeline. It includes
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

#pragma once

#include <cuda_bf16.h>
#include <cuda_fp16.h>

#include "../beamformer/beamformer.h"

namespace Beamform {
/**
 * @brief Convert RF IQ-signal to desired format, while discarding inactive
 * channels
 * @tparam rfType_t RF data type
 * @param rfFormatted output RF in desired format, containing only active
 * channels
 * @param rfRaw input RF in rfType_t, containing all channels (both active and
 * inactive
 * @param rcv receive specification structure
 *
 * @todo: overload this function for more types if needed by adding definitions
 * with more types in Beamformer_kernels.cu file
 */
template <typename rfType_t>
__global__ void formatRf_kernel(float2 *rfFormatted, const rfType_t *rfRaw,
                                const Beamform::ReceiveSpec rcv);

/**
 * @brief Convert RF non-IQ-signal to desired format, while discarding inactive
 * channels
 * @tparam rfType_t RF data type
 * @param rfFormatted output RF in desired format, containing only active
 * channels
 * @param rfRaw input RF in rfType_t, containing all channels (both active and
 * inactive
 * @param rcv receive specification structure
 *
 * @todo: overload this function for more types if needed by adding definitions
 * with more types in Beamformer_kernels.cu file
 */
template <typename rfType_t>
__global__ void formatRf_kernel(float *rfFormatted, const rfType_t *rfRaw,
                                const Beamform::ReceiveSpec rcv);

/**
 * @brief Compute magnitude of a complex array on the GPU.
 * @param output Device pointer to real output array (float*).
 * @param input Device pointer to complex input array (float2*).
 * @param size Number of elements in the input/output arrays.
 */
__global__ void getMagnitude_kernel(float *output, const float2 *input,
                                    size_t size);
/**
 * @brief Convert a complex float array (float2) to half precision (half2) on
 * the GPU.
 * @param input Device pointer to complex BF single precision input (float2*).
 * @param output Device pointer to complex BF half precision output (half2*).
 * @param size Number of elements to convert.
 */
__global__ void convertFloat2ToHalf2(const float2 *input, half2 *output,
                                     size_t size);

/**
 * @brief Convert a complex float array (float2) to bfloat16 (nv_bfloat162) on
 * the GPU.
 * @param input Device pointer to complex BF single precision input (float2*).
 * @param output Device pointer to complex BF bfloat16 output (nv_bfloat162*).
 * @param size Number of elements to convert.
 */
__global__ void convertFloat2ToBfloat162(const float2 *input,
                                         nv_bfloat162 *output, size_t size);
/**
 * @brief Crop beamformed data on the GPU.
 * @param input Device pointer to full-size beamformed data (float2*).
 * @param output Device pointer for cropped beamformed data (float2*).
 * @param nChannels Number of channels in the input data.
 * @param nSamples Number of samples per channel in the input data.
 * @param nEnsembles Number of ensembles (frames).
 * @param totalSizeCropped Total number of elements in the cropped output.
 * @param nSamplesReduced Number of samples after cropping.
 * @param nChannelsReduced Number of channels after cropping.
 * @param nSamplesCropTop Number of samples to crop from the top.
 * @param nSamplesCropBot Number of samples to crop from the bottom.
 * @param nChannelsCropLeft Number of channels to crop from the left.
 * @param nChannelsCropRight Number of channels to crop from the right.
 */
__global__ void crop_BF(float2 *input, float2 *output, int32_t nChannels,
                        int32_t nSamples, int32_t nEnsembles,
                        int32_t totalSizeCropped, int32_t nSamplesReduced,
                        int32_t nChannelsReduced, int32_t nSamplesCropTop,
                        int32_t nSamplesCropBot, int32_t nChannelsCropLeft,
                        int32_t nChannelsCropRight);
}  // namespace Beamform
