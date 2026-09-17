/**
 * @file mex_resources_conversions.h
 * @author BrainEcho Lab
 * @brief MATLAB-to-Native Resource Conversion Utilities (Header)
 * @details This header declares functions for converting MATLAB mxArray
 * resource structures into native EchoFrame C++ structures. These utilities are
 * used by the EchoFrame MEX interface to initialize and update core processing
 * resources, storage specifications, and experiment parameters from MATLAB
 * inputs.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include "../beamformer/echoframe_resources_bundle.h"
#include "matrix.h"
#include "mex.h"

// command position
#define INPUT_CMD_POS 0

// init
#define INIT_INPUT_RCV_POS 1
#define INIT_INPUT_RECON_POS 2
#define INIT_INPUT_PDI_POS 3
#define INIT_INPUT_BFSTORE_POS 4
#define INIT_INPUT_PDISTORE_POS 5
#define INIT_INPUT_RFTIMETAGSTORE_POS 6
#define INIT_INPUT_RFSTORE_POS 7

// process
#define PROCESS_INPUT_RF_POS 1
#define PROCESS_SAVE_FLAG 2
// Slot 3 carries the new threshold for both 'updatePDIthreshold&process'
// (upper/tissue) and 'updatePDInoiseThreshold&process' (lower/noise).
#define PROCESS_INPUT_UPDATE_SVD_THRESHOLD 3

// re-init storage and experiment
#define REINIT_INPUT_BFSTORE_POS 1
#define REINIT_INPUT_PDISTORE_POS 2
#define REINIT_INPUT_RFTIMETAGSTORE_POS 3
#define REINIT_INPUT_RFSTORE_POS 4
#define REINIT_INPUT_RECON_POS 5
#define REINIT_INPUT_PDISPEC_POS 6

namespace MexToNative {

/**
 * @brief Checks the presence and type of a field in a MATLAB struct.
 * @param structArray Pointer to the MATLAB struct mxArray.
 * @param fieldName Name of the field to check.
 * @param typeCheck Function pointer to a type-checking function (e.g.,
 * mxIsInt32). Pass nullptr to skip type check.
 * @param typeName Name of the expected type (for error messages).
 * @throws std::invalid_argument if the field is missing or has the wrong type.
 */
void checkField(const mxArray *structArray, const char *fieldName,
                bool (*typeCheck)(const mxArray *), const char *typeName);

/**
 * @brief Checks if a MATLAB array is a complex single-precision array.
 * @param array Pointer to the MATLAB mxArray.
 * @return true if the array is complex and single-precision, false otherwise.
 */
bool isComplexSingle(const mxArray *array);

/**
 * @brief Converts MATLAB input arrays to native EchoFrame resources (without
 * storage).
 * @param prhs Array of input mxArrays from MATLAB.
 * @param res Reference to the native EchoframeResources structure to populate.
 */
void convertMexResources(const mxArray *prhs[], EchoframeResources &res);

/**
 * @brief Converts MATLAB input arrays to native EchoFrame resources (with
 * storage).
 * @param prhs Array of input mxArrays from MATLAB.
 * @param nrhs Entries in prhs; 8 carries an RF storage spec, 7 does not.
 * @param res Reference to the native EchoframeResources structure to populate.
 */
void convertMexResourcesWithStorage(const mxArray *prhs[], int nrhs,
                                    EchoframeResources &res);

/**
 * @brief Converts MATLAB input arrays for re-initializing storage resources.
 * @param prhs Array of input mxArrays from MATLAB.
 * @param nrhs Entries in prhs; the RF storage spec is read only past
 * REINIT_INPUT_RFSTORE_POS, and RF storage is disabled without it.
 * @param res Reference to the native EchoframeResources structure to update.
 */
void convertReinitStorage(const mxArray *prhs[], int nrhs, EchoframeResources &res);

/**
 * @brief Converts MATLAB input arrays for re-initializing experiment resources.
 * @param prhs Array of input mxArrays from MATLAB.
 * @param nrhs Entries in prhs; the RF storage spec is read only past
 * REINIT_INPUT_RFSTORE_POS, and RF storage is disabled without it.
 * @param res Reference to the native EchoframeResources structure to update.
 */
void convertReinitExperiment(const mxArray *prhs[], int nrhs, EchoframeResources &res);

/**
 * @brief Validates the fields and types of a MATLAB ReceiveSpec struct.
 * @param s Pointer to the MATLAB struct mxArray.
 * @throws std::invalid_argument if any required field is missing or has the
 * wrong type.
 */
void validateReceiveStruct(const mxArray *s);

/**
 * @brief Converts a MATLAB ReceiveSpec struct to a native ReceiveSpec.
 * @param receiveSpec Reference to the native ReceiveSpec structure to populate.
 * @param receiveStruct Pointer to the MATLAB struct mxArray.
 */
void convertReceiveStruct(Beamform::ReceiveSpec &receiveSpec,
                          const mxArray *receiveStruct);

/**
 * @brief Validates the fields and types of a MATLAB ReconSpec struct.
 * @param s Pointer to the MATLAB struct mxArray.
 * @throws std::invalid_argument if any required field is missing or has the
 * wrong type.
 */
void validateReconStruct(const mxArray *s);

/**
 * @brief Converts a MATLAB ReconSpec struct to a native ReconSpec.
 * @param reconSpec Reference to the native ReconSpec structure to populate.
 * @param receiveSpec Reference to the native ReceiveSpec structure.
 * @param reconStruct Pointer to the MATLAB struct mxArray.
 */
void convertReconStruct(Beamform::ReconSpec &reconSpec,
                        const Beamform::ReceiveSpec &receiveSpec,
                        const mxArray *reconStruct);

/**
 * @brief Validates the fields and types of a MATLAB PDISpec struct.
 * @param s Pointer to the MATLAB struct mxArray.
 * @throws std::invalid_argument if any required field is missing or has the
 * wrong type.
 */
void validatePDIStruct(const mxArray *s);

/**
 * @brief Converts a MATLAB PDISpec struct to a native PDISpec.
 * @param pdiSpec Reference to the native PDISpec structure to populate.
 * @param receiveSpec Reference to the native ReceiveSpec structure.
 * @param reconSpec Reference to the native ReconSpec structure.
 * @param pdiStruct Pointer to the MATLAB struct mxArray.
 */
void convertPDISpec(PDI::PDISpec &pdiSpec,
                    const Beamform::ReceiveSpec &receiveSpec,
                    const Beamform::ReconSpec &reconSpec,
                    const mxArray *pdiStruct);

/**
 * @brief Validates the fields and types of a MATLAB FourierReconSpec struct.
 * @param s Pointer to the MATLAB struct mxArray.
 * @throws std::invalid_argument if any required field is missing or has the
 * wrong type.
 */
void validateFourierReconStruct(const mxArray *s);

/**
 * @brief Converts a MATLAB FourierReconSpec struct to a native
 * FourierReconSpec.
 * @param fourierReconSpec Reference to the native FourierReconSpec structure to
 * populate.
 * @param reconStruct Pointer to the MATLAB struct mxArray.
 */
void convertFourierReconSpecStructs(
    Beamform::FourierReconSpec &fourierReconSpec, const mxArray *reconStruct);

/**
 * @brief Validates the fields and types of a MATLAB StorageSpec struct.
 * @param s Pointer to the MATLAB struct mxArray.
 * @throws std::invalid_argument if any required field is missing or has the
 * wrong type.
 */
void validateStorageStruct(const mxArray *s);

/**
 * @brief Converts a MATLAB StorageSpec struct to a native StorageSpec.
 * @param storageSpec Reference to the native StorageSpec structure to populate.
 * @param storageStruct Pointer to the MATLAB struct mxArray.
 */
void convertStorageStruct(Storage::StorageSpec &storageSpec,
                          const mxArray *storageStruct);

/**
 * @brief Prints the contents of a native ReceiveSpec structure.
 * @param receiveSpec Reference to the native ReceiveSpec structure.
 */
void printReceiveSpec(const Beamform::ReceiveSpec &receiveSpec);

/**
 * @brief Prints the contents of a native ReconSpec structure.
 * @param reconSpec Reference to the native ReconSpec structure.
 */
void printReconSpec(const Beamform::ReconSpec &reconSpec);

/**
 * @brief Prints the contents of a native PDISpec structure.
 * @param pdiSpec Reference to the native PDISpec structure.
 */
void printPDISpec(const PDI::PDISpec &pdiSpec);

}  // namespace MexToNative
