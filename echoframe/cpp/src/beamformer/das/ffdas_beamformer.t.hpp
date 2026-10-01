/**
 * @file ffdas_beamformer.t.hpp
 * @brief ffdas-backed delay-and-sum beamformer implementation.
 */
#pragma once

#include "ffdas_beamformer.h"

#include <cstring>
#include <stdexcept>
#include <string>
#include <type_traits>

#include "../../cuda/cuda_error.h"
#include "../fourier_imaging/fourier_imaging_kernels.cuh"

namespace Beamform {

inline void ffdasErrchk(ffdas_error_t err) {
    if (err != FFDAS_SUCCESS) {
        throw std::runtime_error(std::string("ffdas error: ") +
                                 ffdas_error_string(err));
    }
}

template <typename bfType_t>
FFDASBeamformer<bfType_t>::~FFDASBeamformer() {
    if (mInitialized) clearGPU();
}

template <typename bfType_t>
void FFDASBeamformer<bfType_t>::initialize() {
    static_assert(
        std::is_same_v<bfType_t, float2>,
        "ffdas beamformer currently supports complex single IQ only.");
    initGPU();
}

template <typename bfType_t>
void FFDASBeamformer<bfType_t>::initGPU() {
    const size_t nChannels = this->receiveSpec.nActiveChannels;
    const size_t nVoxels = this->reconSpec.totalSize;
    const size_t nTx = this->receiveSpec.nTX;

    if (!dasReconSpec.channelPositions || !dasReconSpec.voxelPositions ||
        !dasReconSpec.offsets || !dasReconSpec.weights ||
        !dasReconSpec.tgcVector) {
        throw std::runtime_error(
            "DASReconSpec requires channelPositions, voxelPositions, offsets, "
            "weights, and tgcVector.");
    }

    gpuErrchk(cudaMalloc(&dasReconSpec.d_channelPositions,
                         nChannels * 3 * sizeof(float)));
    gpuErrchk(cudaMemcpy(
        dasReconSpec.d_channelPositions, dasReconSpec.channelPositions,
        nChannels * 3 * sizeof(float), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMalloc(&dasReconSpec.d_voxelPositions,
                         nVoxels * 3 * sizeof(float)));
    gpuErrchk(cudaMemcpy(dasReconSpec.d_voxelPositions,
                         dasReconSpec.voxelPositions,
                         nVoxels * 3 * sizeof(float), cudaMemcpyHostToDevice));

    gpuErrchk(
        cudaMalloc(&dasReconSpec.d_offsets, nTx * nVoxels * sizeof(float)));
    gpuErrchk(cudaMemcpy(dasReconSpec.d_offsets, dasReconSpec.offsets,
                         nTx * nVoxels * sizeof(float),
                         cudaMemcpyHostToDevice));

    gpuErrchk(
        cudaMalloc(&dasReconSpec.d_weights, nTx * nVoxels * sizeof(float)));
    gpuErrchk(cudaMemcpy(dasReconSpec.d_weights, dasReconSpec.weights,
                         nTx * nVoxels * sizeof(float),
                         cudaMemcpyHostToDevice));

    gpuErrchk(cudaMalloc(&dasReconSpec.d_tgcVector,
                         this->receiveSpec.nSamplesIQ * sizeof(float)));
    gpuErrchk(cudaMemcpy(dasReconSpec.d_tgcVector, dasReconSpec.tgcVector,
                         this->receiveSpec.nSamplesIQ * sizeof(float),
                         cudaMemcpyHostToDevice));

    if (dasReconSpec.useDirectivity) {
        if (!dasReconSpec.sourceDirections)
            throw std::runtime_error(
                "DASReconSpec.useDirectivity requires sourceDirections.");
        gpuErrchk(cudaMalloc(&dasReconSpec.d_sourceDirections,
                             nChannels * 4 * sizeof(float)));
        gpuErrchk(cudaMemcpy(
            dasReconSpec.d_sourceDirections, dasReconSpec.sourceDirections,
            nChannels * 4 * sizeof(float), cudaMemcpyHostToDevice));
    }

    ffdasErrchk(ffdas_create(&handle));

    const int64_t xDims[] = {
        this->receiveSpec.nRepeats, this->receiveSpec.nActiveChannels,
        this->receiveSpec.nTX, this->receiveSpec.nSamplesIQ};
    const int64_t xStrides[] = {
        static_cast<int64_t>(this->receiveSpec.nTX) *
            this->receiveSpec.nSamplesIQ,
        static_cast<int64_t>(this->receiveSpec.nRepeats) *
            this->receiveSpec.nTX * this->receiveSpec.nSamplesIQ,
        this->receiveSpec.nSamplesIQ, 1};
    ffdasErrchk(
        ffdas_create_tensor_desc(&xDesc, 4, xDims, xStrides, FFDAS_C_32F));

    const int64_t outDims[] = {this->reconSpec.ensembleSize, this->reconSpec.nx,
                               this->reconSpec.nz};
    const int64_t outStrides[] = {this->reconSpec.totalSize, this->reconSpec.nz,
                                  1};
    ffdasErrchk(ffdas_create_tensor_desc(&outDesc, 3, outDims, outStrides,
                                         FFDAS_C_32F));
}

template <typename bfType_t>
void FFDASBeamformer<bfType_t>::clearGPU() {
    if (xDesc) ffdas_destroy_tensor_desc(xDesc);
    if (outDesc) ffdas_destroy_tensor_desc(outDesc);
    if (handle) ffdas_destroy(handle);
    if (dasReconSpec.d_channelPositions)
        cudaFree(dasReconSpec.d_channelPositions);
    if (dasReconSpec.d_voxelPositions) cudaFree(dasReconSpec.d_voxelPositions);
    if (dasReconSpec.d_offsets) cudaFree(dasReconSpec.d_offsets);
    if (dasReconSpec.d_weights) cudaFree(dasReconSpec.d_weights);
    if (dasReconSpec.d_tgcVector) cudaFree(dasReconSpec.d_tgcVector);
    if (dasReconSpec.d_sourceDirections)
        cudaFree(dasReconSpec.d_sourceDirections);
}

template <typename bfType_t>
void FFDASBeamformer<bfType_t>::process() {
    constexpr int threadsPerBlock = 512;
    const int nRF = this->receiveSpec.nFastTimeSamples * this->receiveSpec.nTX *
                    this->receiveSpec.nSlowTimeSamples *
                    this->receiveSpec.nActiveChannels;
    TGCWeighting_kernel<<<nRF / threadsPerBlock + 1, threadsPerBlock>>>(
        this->d_RF, dasReconSpec.d_tgcVector, this->receiveSpec);
    gpuErrchk(cudaPeekAtLastError());

    const float2 beta{0.0f, 0.0f};
    ffdasErrchk(ffdas_das(
        handle, dasReconSpec.d_channelPositions,
        dasReconSpec.useDirectivity ? dasReconSpec.d_sourceDirections : nullptr,
        dasReconSpec.wavenum, xDesc, this->d_RF, dasReconSpec.d_voxelPositions,
        dasReconSpec.d_offsets, dasReconSpec.d_weights, &beta, outDesc,
        this->d_BF, static_cast<ffdas_compute_type_t>(dasReconSpec.computeType),
        static_cast<ffdas_alg_t>(dasReconSpec.algorithm)));
    gpuErrchk(cudaDeviceSynchronize());
}

}  // namespace Beamform
