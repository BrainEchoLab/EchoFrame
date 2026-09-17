/**
 * @file load_specs_from_mat.hpp
 * @author BrainEcho Lab
 * @brief MATLAB .mat File Resource Loader (Header)
 * @details This header declares functions for loading EchoFrame scan and
 * processing specifications from a MATLAB .mat file using the matio library. It
 * provides an interface for extracting ReceiveSpec, ReconSpec, and PDISpec
 * structures from MATLAB files and populating native EchoFrame resource
 * structures.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once
#include <string>

#include "../efcore/echoframe_core.h"  // EchoframeResources

/**
 * @brief Fill the three Specs inside @p res from ReceiveSpec, ReconSpec, and
 * PDISpec structs stored in a MATLAB -v7.3 file.
 * @param matFile Path to the MATLAB .mat file.
 * @param res Reference to the EchoframeResources structure to populate.
 * @throws std::runtime_error on any problem.
 *
 * The .mat file should be produced with:
 *   save(..., 'ReceiveSpec','ReconSpec','PDISpec','-v7.3')
 */
void loadSpecsFromMat(const std::string &matFile, EchoframeResources &res);
