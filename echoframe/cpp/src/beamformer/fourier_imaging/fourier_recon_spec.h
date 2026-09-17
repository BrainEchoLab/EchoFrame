/**
 * @file fourier_recon_spec.h
 * @author BrainEcho Lab
 * @brief Fourier Reconstruction Specification (Header)
 * @details This header defines the FourierReconSpec structure, which contains
 * parameters and GPU pointers for Fourier-based beamforming and reconstruction
 * in EchoFrame. It includes image dimensions, delay indices, interpolation
 * weights, frequency axis, planewave delays, and time-gain compensation
 * vectors, both on host and device. This structure is used to configure and
 * manage resources for advanced Fourier imaging workflows.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <cstdint>
#include <vector>

#include <cuda_runtime.h>

namespace Beamform {
/**
 * @brief Structure describing parameters and GPU pointers for Fourier-based
 * reconstruction.
 */
struct FourierReconSpec {
    // General reconstruction parameters
    int32_t nx;         ///< Number of pixels in x dimension.
    int32_t nz;         ///< Number of pixels in z dimension.
    int32_t totalSize;  ///< Total number of pixels.

    // Fourier beamforming specific parameters and pointers
    int32_t *delayIndices;         ///< Host pointer to delay indices.
    int32_t *d_delayIndices;       ///< Device pointer to delay indices.
    float2 *interpolationWeights;  ///< Host pointer to interpolation weights.
    float2
        *d_interpolationWeights;  ///< Device pointer to interpolation weights.
    float *frequencyAxis;         ///< Host pointer to frequency axis.
    float *d_frequencyAxis;       ///< Device pointer to frequency axis.
    float *planewaveDelays;       ///< Host pointer to planewave delays.
    float *d_planewaveDelays;     ///< Device pointer to planewave delays.
    float *tgcVector;             ///< Host pointer to TGC vector.
    float *d_tgcVector;           ///< Device pointer to TGC vector.
};
}  // namespace Beamform
