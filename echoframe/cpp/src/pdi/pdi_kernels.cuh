/**
 * @file pdi_kernels.cuh
 * @author your name (you@domain.com)
 * @brief CUDA Kernel declarations for PDI
 * @details This file contains the declarations of CUDA kernels used for
 * Power Doppler Imaging (PDI) processing. The kernels include functions for
 * thresholding singular values, converting real arrays to complex arrays,
 * calculating absolute values of complex matrices, and cropping 2D matrices.
 * @version 0.1
 * @date 2025-01-30
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include <string>

/**
 * @brief Removes first "threshold" singular values on the GPU
 *
 * @param s         Pointer to float array of singular values (device memory)
 * @param threshold Number of values to zero
 */
__global__ void threshold_singular_values(float *s, int32_t threshold);

/**
 * @brief Converts a real array to complex array (imag part = 0) on the GPU
 *
 * @param src Pointer to float array (device memory)
 * @param dst Pointer to float2 array (device memory)
 * @param n   Number of columns (nRepeats or Ensemble size)
 */
__global__ void copyRealToComplex(const float *src, float2 *dst, int n);

/**
 * @brief Calculates absolute values of a complex matrix (device memory)
 *
 * @param in  Pointer to float2 array (complex input)
 * @param out Pointer to float array (m x n)
 * @param m   Number of rows (nz x nx)
 * @param n   Number of columns (nRepeats or Ensemble size)
 */
__global__ void absComplex(float2 *in, float *out, int m, int n);

/**
 * @brief Crops a 2D matrix from (nSamples x nChannels) to a smaller region
 *
 * @param input                Original device array
 * @param output               Cropped device array
 * @param nChannels            Full number of columns in original
 * @param nSamples             Full number of rows in original
 * @param totalSizeCropped     Size of the flattened cropped region
 * @param nSamplesReduced     Cropped rows
 * @param nChannelsReduced    Cropped columns
 * @param nSamplesCropTop    Number of rows cropped from the top
 * @param nSamplesCropBot    Number of rows cropped from the bottom
 * @param nChannelsCropLeft  Number of columns cropped from the left
 * @param nChannelsCropRight Number of columns cropped from the right
 */
__global__ void cropPDIkernel(float *input, float *output, int32_t nChannels,
                              int32_t nSamples, int32_t totalSizeCropped,
                              int32_t nSamplesReduced,
                              int32_t nChannelsReduced,
                              int32_t nSamplesCropTop,
                              int32_t nSamplesCropBot,
                              int32_t nChannelsCropLeft,
                              int32_t nChannelsCropRight);
