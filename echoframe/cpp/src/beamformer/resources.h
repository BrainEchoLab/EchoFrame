/**
 * @file resources.h
 * @author BrainEcho Lab
 * @brief Beamformer Resource Specifications (Header)
 * @details This header defines the core resource structures for beamforming in
 * EchoFrame. It includes ReceiveSpec for RF data properties and ReconSpec for
 * reconstruction parameters, cropping, and output options. These structures are
 * used throughout the beamforming pipeline for configuration and memory
 * management.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <string>
#include <vector>

namespace Beamform {

/**
 * @brief Structure describing RF data acquisition and transducer properties.
 */
struct ReceiveSpec {
    // RF properties
    int32_t nSamples{0};          ///< Number of RF samples per channel.
    int32_t nSamplesIQ{0};        ///< Number of IQ samples per channel.
    int32_t nSlowTimeSamples{0};  ///< Number of slow-time samples.
    int32_t nChannels{0};         ///< Number of receive channels.
    int32_t nTX{0};               ///< Number of transmit events.
    int32_t nRepeats{0};          ///< Number of repeated acquisitions.
    int32_t nFastTimeSamples{0};  ///< Number of fast-time samples.
    int64_t rfSize{0};            ///< Total RF data size.
    int32_t mNRows{0};  ///< Number of rows (rfSize divided by channels).

    // Transducer properties
    int32_t nActiveChannels{0};     ///< Number of active channels.
    int32_t *activeChannelMap{};    ///< Map of active channel indices (host).
    int32_t *d_activeChannelMap{};  ///< Map of active channel indices (device).

    int32_t sampleMode{0};  ///< Sample mode (e.g., raw, IQ).
    float Fs{0};            ///< Sampling frequency (RF).

    bool initialized{false};  ///< Initialization flag.
};

/**
 * @brief Structure describing reconstruction parameters and output options.
 */
struct ReconSpec {
    // reconstruction dimensions
    int32_t ensembleSize{};  ///< Ensemble size for reconstruction.
    int32_t nz{};            ///< Number of pixels in z dimension.
    int32_t nx{};            ///< Number of pixels in x dimension.

    // Cropping
    int32_t nSamplesReduced;   ///< nz after cropping.
    int32_t nChannelsReduced;  ///< nx after cropping.

    int32_t nSamplesCropTop;     ///< Cropping: samples to remove from top.
    int32_t nSamplesCropBot;     ///< Cropping: samples to remove from bottom.
    int32_t nChannelsCropLeft;   ///< Cropping: channels to remove from left.
    int32_t nChannelsCropRight;  ///< Cropping: channels to remove from right.

    double zSpacing{};  ///< Pixel spacing in z direction.
    double xSpacing{};  ///< Pixel spacing in x direction.

    int32_t totalSize{};            ///< Total number of pixels.
    int32_t totalSizeCropped{};     ///< Total number of cropped pixels.
    bool filterFrequencies{false};  ///< Enable frequency filtering.
    bool getBF{false};              ///< Output beamformed data.
    bool getPDI{false};             ///< Output PDI data.
    bool cropBF{false};             ///< Crop beamformed data.

    bool initialized{false};  ///< Initialization flag.
};
}  // namespace Beamform
