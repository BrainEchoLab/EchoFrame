/**
 * @file fourier_imaging_kernels.cuh
 * @author BrainEcho Lab
 * @brief Fourier Imaging CUDA Kernels (Header)
 * @details This header declares CUDA kernels for Fourier-based imaging
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

#pragma once

#include <cuComplex.h>
#include <math_constants.h>

#include "../resources.h"

namespace Beamform {

/**
 * @brief Perform Time-Gain Compensation weighting on RF
 * @param RF RF input/output
 * @param tgcVector Time-Gain Compensation vector
 * @param receiveSpec receive structure
 */
__global__ void TGCWeighting_kernel(float2 *RF, const float *tgcVector,
                                    ReceiveSpec receiveSpec);
__global__ void TGCWeighting_kernel(float *RF, const float *tgcVector,
                                    ReceiveSpec receiveSpec);

/**
 * @brief Apply delays to every sample according to the planewave angle
 * @param RF RF input/output
 * @param delaysAx delays of each steering for each channel
 * @param delaysB delays of each steering
 * @param frequencyAxis frequency bands
 * @param padding zero-padding size applied to RF on the left (beginning)
 * @param receiveSpec receive structure
 */
__global__ void delayWave_kernel(float2 *RF, const float *delaysAx,
                                 const float *delaysB,
                                 const float *frequencyAxis, int padding,
                                 ReceiveSpec receiveSpec);

/**
 * @brief Interpolate the RF in the fast-time neighbourhood using linear
 * weights, also compound in the transmissions dimension
 * @param RFOutput RF output
 * @param RFInput RF input
 * @param delayIndices indices of neighbours according to delays
 * @param weights linear weights for interpolation
 * @param receiveSpec receive structure
 * @param reconSpec reconstruction structure
 */
__global__ void interpFastTimeAndCompound_kernel(
    float2 *RFOutput, const float2 *RFInput, const int32_t *delayIndices,
    const float2 *weights, ReceiveSpec receiveSpec, ReconSpec reconSpec);

/**
 * @brief Interpolate the RF in the fast-time neighbourhood using linear
 * weights, add padding/truncate to the actual reconstruction size and also
 * compound in the transmissions (angles) dimension
 * @param BFOutput beamformed output, sized nz by nx
 * @param RFInput RF input
 * @param delayIndices indices of neighbours according to delays
 * @param weights linear weights for interpolation
 * @param receiveSpec receive structure
 * @param nz axial size of the reconstruction grid
 * @param nx lateral size of the reconstruction grid
 */
__global__ void interpFastTimeCompoundAndPad_kernel(
    float2 *BFOutput, const float2 *RFInput, const int32_t *delayIndices,
    const float2 *weights, ReceiveSpec receiveSpec, const int32_t nz,
    const int32_t nx);

/**
 * @brief Convert linear indices of multi-dimensional array to subscripts for
 * each dimension
 * @param sub subscript of array position for each dimension (output)
 * @param idx linear index of array position(input)
 * @param strides strides of each dimension
 * @param ndim number of dimensions
 */
__host__ __device__ void ind2subV2(int *sub, int idx, const int *strides,
                                   int ndim);

}  // namespace Beamform
