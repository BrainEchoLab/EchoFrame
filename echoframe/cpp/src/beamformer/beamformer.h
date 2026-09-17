/**
 * @file beamformer.h
 * @author BrainEcho Lab
 * @brief Beamformer Base Class (Header)
 * @details This header defines the Beamformer class template, which provides a
 * base interface and common functionality for beamforming operations in
 * EchoFrame. It manages resource specifications, GPU memory, and initialization
 * logic for derived beamformer implementations.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <utility>

#include "resources.h"

namespace Beamform {
/**
 * @brief Base class template for beamforming operations.
 * @tparam bfType_t Beamformed data type.
 */
template <typename bfType_t>
class Beamformer {
   private:
   protected:
    ReceiveSpec receiveSpec;  ///< Receive specification.
    ReconSpec reconSpec;      ///< Reconstruction specification.

    bfType_t *d_rfFormatted;  ///< Device pointer to formatted RF data.
    bfType_t *d_RF;           ///< Device pointer to RF data.
    bfType_t *d_BF;           ///< Device pointer to beamformed data.

    size_t mUsedGPUMem{0};  ///< Amount of GPU memory used.

    bool initialized{false};  ///< Initialization flag.

   public:
    /**
     * @brief Default constructor.
     */
    Beamformer() = default;

    /**
     * @brief Construct a new Beamformer with resource specs and device RF
     * pointer.
     * @param pReceiveSpec Receive specification.
     * @param pReconSpec Reconstruction specification.
     * @param d_pRF Device pointer to formatted RF data.
     */
    Beamformer(ReceiveSpec pReceiveSpec, ReconSpec pReconSpec, bfType_t *d_pRF)
        : receiveSpec(std::move(pReceiveSpec)),
          reconSpec(std::move(pReconSpec)),
          d_rfFormatted(d_pRF) {
        // configure final number of samples

        receiveSpec.nFastTimeSamples = receiveSpec.nSamplesIQ;

        receiveSpec.nSlowTimeSamples = receiveSpec.nRepeats;

        d_RF = d_rfFormatted;

        initGPUBase();

        initialized = true;
    };

    /**
     * @brief Destructor. Releases GPU and host resources.
     * Virtual so that `delete` through a Beamformer* runs the derived
     * destructor (e.g. FourierImaging::~FourierImaging()).
     */
    virtual ~Beamformer();

    /**
     * @brief Move constructor.
     */
    Beamformer(Beamformer &&x) noexcept;

    /**
     * @brief Move-assignment operator.
     */
    Beamformer &operator=(Beamformer &&x) noexcept;

    /**
     * @brief Check that the object has been initialized.
     * @return true if initialized, false otherwise.
     */
    bool checkInitialized();

    /**
     * @brief Initialize variables/structs (to be implemented by derived
     * classes).
     */
    virtual void initialize() {};

    /**
     * @brief Initialize variables/structs in GPU memory.
     */
    void initGPUBase();

    /**
     * @brief Clear variables/structs in GPU memory
     */
    void clearGPUBase();

    /**
     * @brief Beamform the RF (to be implemented by derived classes).
     */
    virtual void process() {};

    /**
     * @brief Get the beamformed data in time domain (device pointer).
     * @return bfType_t* Device pointer to beamformed data.
     */
    bfType_t *getBF() { return d_BF; };

    /**
     * @brief Get the beamformed data in frequency domain (device pointer).
     * @return bfType_t* Device pointer to frequency domain BF data, or nullptr
     * if not implemented.
     */
    virtual bfType_t *getBFFreq() { return nullptr; };
};
}  // namespace Beamform
