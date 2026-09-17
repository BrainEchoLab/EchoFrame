/**
 * @file echoframe_mex.h
 * @author BrainEcho Lab
 * @brief EchoFrame MATLAB MEX Interface
 * @details This file implements the MATLAB MEX gateway for the EchoFrame core.
 * It provides the entry point for MATLAB to interact with the EchoFrame
 * C++/CUDA backend, supporting initialization, processing, storage management,
 * and destruction of EchoFrame objects.
 * @details The MEX interface translates MATLAB data structures and commands
 * into native EchoFrame operations, enabling high-performance ultrasound
 * processing from MATLAB.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */
#pragma once

#include <string>

#include "matrix.h"
#include "mex.h"
#include "mex_resources_conversions.h"  // Our conversion layer.

/**
 * @brief MATLAB MEX entry point for EchoFrame.
 * @param nlhs Number of expected output mxArrays.
 * @param plhs Array of pointers to output mxArrays.
 * @param nrhs Number of input mxArrays.
 * @param prhs Array of pointers to input mxArrays.
 */
void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]);

/**
 * @brief Cleanup function called when MATLAB clears the MEX file.
 */
void mexAtExitCleanup();

/**
 * @brief Converts a MATLAB string mxArray to an std::string.
 * @param matlabStr Pointer to the MATLAB string mxArray.
 * @return Converted std::string.
 */
std::string mxArrayToStdString(const mxArray *matlabStr);

/**
 * @brief Retrieves a typed buffer pointer from a MATLAB mxArray.
 * @tparam bufferType_t The type of buffer to retrieve.
 * @param mxBuffer Pointer to the MATLAB mxArray containing the buffer.
 * @return Pointer to the buffer of type bufferType_t.
 */
template <typename bufferType_t>
bufferType_t *mxGetBuffer(const mxArray *mxBuffer);

/**
 * @brief Builds MATLAB output arrays from EchoFrame GPU results.
 * @param nlhs Number of expected output mxArrays.
 * @param plhs Array of pointers to output mxArrays.
 * @param res EchoFrame resource specification.
 * @param pPDIResult Pointer to PDI result data.
 * @param pBmodeResult Pointer to B-mode result data.
 * @param pBFComplexResult Pointer to complex beamformed result data.
 */
static void buildMatlabOutput(int nlhs, mxArray *plhs[],
                              const EchoframeResources &res, float *pPDIResult,
                              float *pBmodeResult, float2 *pBFComplexResult);
