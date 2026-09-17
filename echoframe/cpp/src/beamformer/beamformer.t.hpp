/**
 * @file beamformer.t.hpp
 * @author BrainEcho Lab
 * @brief Beamformer Base Class Template Implementations
 * @details This file implements the template member functions for the
 * Beamformer base class in EchoFrame. It provides move semantics,
 * initialization checks, GPU memory management, and resource cleanup for
 * derived beamformer classes. These implementations support efficient and safe
 * management of GPU resources during beamforming operations.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "beamformer.h"

#include <iostream>

#include <gsl/gsl>

#include "../cuda/cuda_error.h"
#include "beamformer_kernels.h"

namespace Beamform {

template <typename bfType_t>

/**
 * @brief Move constructor for Beamformer.
 * @tparam bfType_t Beamformed data type.
 * @param x Rvalue reference to another Beamformer.
 */
Beamformer<bfType_t>::Beamformer(Beamformer &&x) noexcept {
    receiveSpec = std::move(x.receiveSpec);
    reconSpec = std::move(x.reconSpec);

    d_rfFormatted = x.d_rfFormatted;
    d_RF = x.d_RF;
    d_BF = x.d_BF;

    mUsedGPUMem = x.mUsedGPUMem;

    initialized = x.initialized;
    x.initialized = false;
}

/**
 * @brief Move-assignment operator for Beamformer.
 * @tparam bfType_t Beamformed data type.
 * @param x Rvalue reference to another Beamformer.
 * @return Reference to this Beamformer.
 */
template <typename bfType_t>
Beamformer<bfType_t> &Beamformer<bfType_t>::operator=(Beamformer &&x) noexcept {
    receiveSpec = std::move(x.receiveSpec);
    reconSpec = std::move(x.reconSpec);

    d_rfFormatted = x.d_rfFormatted;
    d_RF = x.d_RF;
    d_BF = x.d_BF;

    mUsedGPUMem = x.mUsedGPUMem;

    initialized = x.initialized;
    x.initialized = false;

    return *this;
}

/**
 * @brief Check if the Beamformer object has been initialized.
 * @tparam bfType_t Beamformed data type.
 * @return true if initialized, false otherwise.
 */
template <typename bfType_t>
bool Beamformer<bfType_t>::checkInitialized() {
    return initialized;
}

/**
 * @brief Destructor for Beamformer. Releases GPU resources if initialized.
 * @tparam bfType_t Beamformed data type.
 */
template <typename bfType_t>
Beamformer<bfType_t>::~Beamformer() {
    if (initialized) {
        clearGPUBase();
    }
}

/**
 * @brief Free GPU memory allocated for beamformed data.
 * @tparam bfType_t Beamformed data type.
 */
template <typename bfType_t>
void Beamformer<bfType_t>::clearGPUBase() {
    gpuErrchk(cudaFree(d_BF));
}

/**
 * @brief Allocate GPU memory for beamformed data.
 * @tparam bfType_t Beamformed data type.
 */
template <typename bfType_t>
void Beamformer<bfType_t>::initGPUBase() {
    // BF
    gpuErrchk(cudaMalloc(&d_BF, reconSpec.ensembleSize * reconSpec.totalSize *
                                    sizeof(bfType_t)));
}
}  // namespace Beamform
