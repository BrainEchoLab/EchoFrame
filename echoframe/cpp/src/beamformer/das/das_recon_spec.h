/**
 * @file das_recon_spec.h
 * @brief Delay-and-sum reconstruction parameters.
 */
#pragma once

#include <cstdint>

namespace Beamform {

struct DASReconSpec {
    float *channelPositions{};    ///< Host pointer, (nActiveChannels, 3).
    float *d_channelPositions{};  ///< Device pointer, (nActiveChannels, 3).
    float *voxelPositions{};      ///< Host pointer, (totalSize, 3), z fastest.
    float *d_voxelPositions{};    ///< Device pointer, (totalSize, 3).
    float *offsets{};             ///< Host pointer, (nTX, totalSize).
    float *d_offsets{};           ///< Device pointer, (nTX, totalSize).
    float *weights{};             ///< Host pointer, (nTX, totalSize).
    float *d_weights{};           ///< Device pointer, (nTX, totalSize).
    float *tgcVector{};           ///< Host pointer, (nSamplesIQ).
    float *d_tgcVector{};         ///< Device pointer, (nSamplesIQ).
    float
        *sourceDirections{};  ///< Optional host pointer, (nActiveChannels, 4).
    float *d_sourceDirections{};  ///< Optional device pointer,
                                  ///< (nActiveChannels, 4).
    float wavenum{0.0f};          ///< IQ phase rotation, -2*pi*Fc/Fs.
    int32_t algorithm{1};         ///< ffdas algorithm: 1=ALG1, 2=ALG2, 4=ALG4.
    int32_t computeType{0};       ///< ffdas compute type: 0=default.
    bool useDirectivity{false};
};

}  // namespace Beamform
