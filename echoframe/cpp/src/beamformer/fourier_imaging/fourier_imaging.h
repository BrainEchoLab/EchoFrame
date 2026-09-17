/**
 * @file fourier_imaging.h
 * @author BrainEcho Lab
 * @brief Fourier Imaging Beamformer (Header)
 * @details This header defines the FourierImaging class template, which
 * implements Fourier-based beamforming and reconstruction in EchoFrame. It
 * manages resource specifications, GPU memory, cuFFT planning, and provides
 * initialization and cleanup logic for advanced Fourier imaging workflows.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <cstdint>

#include "../beamformer.h"
#include "fourier_recon_spec.h"

namespace Beamform {

/**
 * @brief Beamformer implementation for Fourier-based imaging.
 * @tparam bfType_t Beamformed data type.
 *
 * This class extends the Beamformer base class to provide Fourier-based
 * beamforming and reconstruction, including GPU memory management, cuFFT
 * planning, and resource initialization/cleanup for advanced imaging workflows.
 */
template <typename bfType_t>
class FourierImaging : public Beamformer<bfType_t> {
   private:
    FourierReconSpec
        fourierReconSpec;   ///< Fourier reconstruction specification.
    bfType_t *d_RFPadded;   ///< Device pointer to padded RF data.
    bfType_t *d_RFFourier;  ///< Device pointer to Fourier-transformed RF data.

    // cuFFT handles for various transforms
    cufftHandle mFftFastTimePlan{};  ///< cuFFT plan for fast-time dimension.
    cufftHandle mFftChannelsPlan{};  ///< cuFFT plan for channels dimension.
    cufftHandle mIfftBFPlan{};       ///< cuFFT plan for inverse FFT of BF.

    bool mInitialized{false};  ///< Initialization flag.

   public:
    /**
     * @brief Default constructor.
     */
    FourierImaging() = default;

    /**
     * @brief Construct a new FourierImaging object with resource
     * specifications.
     * @param pReceiveSpec Receive specification.
     * @param pReconSpec Reconstruction specification.
     * @param pFourierReconSpec Fourier reconstruction specification.
     * @param d_pRF Device pointer to formatted RF data.
     */
    FourierImaging(ReceiveSpec pReceiveSpec, ReconSpec pReconSpec,
                   FourierReconSpec pFourierReconSpec, bfType_t *d_pRF)
        : Beamformer<bfType_t>(std::move(pReceiveSpec), pReconSpec, d_pRF),
          fourierReconSpec(pFourierReconSpec) {
        initialize();

        mInitialized = true;
    };

    /**
     * @brief Destructor. Releases GPU and host resources.
     */
    ~FourierImaging();

    /**
     * @brief Move constructor.
     * @param x Rvalue reference to another FourierImaging object.
     */
    FourierImaging(FourierImaging &&x) noexcept;

    /**
     * @brief Move-assignment operator.
     * @param x Rvalue reference to another FourierImaging object.
     * @return Reference to this object.
     */
    FourierImaging &operator=(FourierImaging &&x) noexcept;

    /**
     * @brief Initialize variables/structs.
     */
    void initialize();

    /**
     * @brief Initialize variables/structs in GPU memory.
     */
    void initGPU();

    /**
     * @brief Clear variables/structs in GPU memory.
     */
    void clearGPU();

    /**
     * @brief Beamform the RF.
     */
    void process();
};

}  // namespace Beamform
