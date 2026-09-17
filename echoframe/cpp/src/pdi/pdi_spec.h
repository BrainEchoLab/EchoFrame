/**
 * @file pdi_spec.h
 * @author BrainEcho Lab
 * @brief PDI Specification Header
 * @details This file defines the PDI specification structure used in the
 * @version 0.1
 * @date 2025-05-21
 *
 * @copyright Copyright (c) 2025
 *
 */
#pragma once

namespace PDI {
enum SVDMethod { Full, CovarianceEig };

/** @struct PDISpec
 * @brief This structure is used to define the parameters for the PDI
 * @details The PDISpec structure contains the following members:
 * - ensemble_size: The size of the ensemble.
 * - threshold: The upper (tissue) reject threshold, as a 0-1 fraction.
 * - lowerThreshold: The lower (noise) reject threshold, as a 0-1 fraction
 *   (0 = no noise reject).
 * - shiftSize: The size of the shift.
 * - num_ensembles: The number of ensembles.
 * - cropPDI: A boolean value indicating whether to crop the PDI.
 * - method: The SVD method to be used (Full or CovarianceEig).
 * - total_size: The total size of the data.
 */
struct PDISpec {
    int32_t ensemble_size;
    float threshold;
    float lowerThreshold{0.0f};
    int32_t shiftSize;
    int32_t num_ensembles;
    bool cropPDI{false};
    SVDMethod method{};
    int32_t total_size;
};
}  // namespace PDI