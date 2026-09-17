/**
 * @file RF_formatter.h
 * @author BrainEcho Lab
 * @brief Raw RF Data Formatter (Header)
 * @details This header defines the RFFormatter class template, which provides
 * utilities for formatting raw RF data for beamforming on the GPU. It manages
 * device and host memory, handles resource initialization and cleanup, and
 * supports efficient transfer and conversion of RF data to beamformed types,
 * discarding inactive channels as needed.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include <cstdio>
#include <cstdlib>
#include <iostream>

#include <cuda.h>

#include "../cuda/cuda_error.h"
#include "beamformer_kernels.h"
#include "resources.h"

namespace Beamform {
/**
 * @brief Class for formatting raw RF data for beamforming on the GPU.
 * @tparam rfType_t Raw RF data type.
 * @tparam bfType_t Beamformed data type.
 */
template <typename rfType_t, typename bfType_t>
class RFFormatter {
   private:
    ReceiveSpec receiveSpec;          ///< Receive specification.
    std::vector<rfType_t *> h_rfRaw;  ///< Host RF buffers this object pinned.
    std::vector<const rfType_t *> h_rfSeen;  ///< Host RF buffers already tried.

    rfType_t *d_rfRaw;        ///< Device pointer to raw RF data.
    bfType_t *d_rfFormatted;  ///< Device pointer to formatted RF data.

    bool initialized{false};  ///< Initialization flag.
    bool pinHostRFBuffers{false};  ///< Page-lock incoming RF buffers.

    /// Distinct RF buffers to page-lock before giving up on the rest.
    static constexpr size_t kMaxPinnedRF = 16;

   public:
    /**
     * @brief Default constructor.
     */
    RFFormatter() = default;

    /**
     * @brief Construct a new RFFormatter with a receive spec.
     * @param pReceiveSpec Receive specification.
     */
    explicit RFFormatter(ReceiveSpec &pReceiveSpec)
        : receiveSpec(pReceiveSpec) {
        initGPU();
        initialized = true;
    }

    /**
     * @brief Destructor. Releases GPU and host resources.
     */
    ~RFFormatter() {
        if (initialized) {
            clearGPU();
        }
    }

    /**
     * @brief Move constructor.
     */
    RFFormatter(RFFormatter &&x) noexcept {
        receiveSpec = std::move(x.receiveSpec);
        h_rfRaw = x.h_rfRaw;
        h_rfSeen = x.h_rfSeen;
        pinHostRFBuffers = x.pinHostRFBuffers;
        d_rfRaw = x.d_rfRaw;
        d_rfFormatted = x.d_rfFormatted;

        initialized = x.initialized;
        x.initialized = false;
    }

    /**
     * @brief Move-assignment operator.
     */
    RFFormatter &operator=(RFFormatter &&x) noexcept {
        if (this == &x) return *this;

        // Release what this object already holds before taking x's. Page-locks
        // are process-wide and survive the pointer they cover, so leaking them
        // here leaves CUDA holding host memory the caller has since freed --
        // a later transfer from a reused address then fails. clearGPU reads
        // receiveSpec, so it has to run before the assignment below.
        if (initialized) clearGPU();

        receiveSpec = std::move(x.receiveSpec);
        h_rfRaw = x.h_rfRaw;
        h_rfSeen = x.h_rfSeen;
        pinHostRFBuffers = x.pinHostRFBuffers;
        d_rfRaw = x.d_rfRaw;
        d_rfFormatted = x.d_rfFormatted;

        initialized = x.initialized;
        x.initialized = false;

        return *this;
    }

    /**
     * @brief Initialize variables/structs in GPU memory.
     */
    void initGPU() {
        // Opt-in, and read per init: echoframe_mex calls mexLock(), so a static
        // would hold the first value for the whole MATLAB session.
        //
        // Off by default because the page-lock outlives nothing: it covers
        // memory the caller owns. An acquisition hands back the same few
        // receive frames for the whole session and can turn this on; a script
        // that processes RF it allocated per call must not, or the lock
        // survives the array and a transfer from the reused address fails.
        const char *pinEnv = std::getenv("EF_PIN_RF");
        pinHostRFBuffers = (pinEnv != nullptr && pinEnv[0] == '1');

        // Receive
        gpuErrchk(cudaMalloc(&receiveSpec.d_activeChannelMap,
                             receiveSpec.nActiveChannels * sizeof(int32_t)));
        gpuErrchk(cudaMemcpy(receiveSpec.d_activeChannelMap,
                             receiveSpec.activeChannelMap,
                             receiveSpec.nActiveChannels * sizeof(int32_t),
                             cudaMemcpyHostToDevice));

        gpuErrchk(cudaMalloc(&d_rfRaw, receiveSpec.rfSize * sizeof(rfType_t)));
        int nSamples = receiveSpec.nSamplesIQ;
        gpuErrchk(cudaMalloc(&d_rfFormatted, nSamples * receiveSpec.nTX *
                                                 receiveSpec.nRepeats *
                                                 receiveSpec.nActiveChannels *
                                                 sizeof(bfType_t)));
        //                  receiveSpec.nActiveChannels
    }

    /**
     * @brief Clear variables/structs in GPU memory.
     */
    void clearGPU() {
        gpuErrchk(cudaFree(receiveSpec.d_activeChannelMap));

        // unpin the pinned memory
        for (auto &pinnedRFPtr : h_rfRaw) {
            gpuErrchk(cudaHostUnregister(pinnedRFPtr));
        }
        h_rfRaw.clear();
        h_rfSeen.clear();

        gpuErrchk(cudaFree(d_rfRaw));
        gpuErrchk(cudaFree(d_rfFormatted));
    }

    /**
     * @brief Page-lock a host RF buffer the first time it is seen.
     * @param pRF Pointer to raw RF data.
     * @details The acquisition cycles through a fixed set of receive buffers,
     * so the same few pointers come back frame after frame. Page-locking each
     * one lets the transfer run at pinned bandwidth; an unregistered buffer is
     * copied through a driver bounce buffer at roughly half the rate. A buffer
     * that cannot be registered is left alone and still transfers correctly.
     *
     * The caller must outlive this object: the buffers are unregistered in
     * clearGPU, which is too late if they have already been freed.
     */
    void pinHostRF(const rfType_t *pRF) {
        if (!pinHostRFBuffers || pRF == nullptr) return;
        for (const auto *seen : h_rfSeen)
            if (seen == pRF) return;
        if (h_rfSeen.size() >= kMaxPinnedRF) return;
        h_rfSeen.push_back(pRF);

        auto *base = const_cast<rfType_t *>(pRF);
        const cudaError_t err =
            cudaHostRegister(base, receiveSpec.rfSize * sizeof(rfType_t),
                             cudaHostRegisterDefault);
        if (err == cudaSuccess) {
            h_rfRaw.push_back(base);
            std::cout << "RF host buffer " << h_rfRaw.size()
                      << " page-locked.\n";
            return;
        }
        // Someone else registered it: the transfer is fast either way, and
        // unregistering a buffer we did not register is not ours to do.
        if (err != cudaErrorHostMemoryAlreadyRegistered) {
            std::cout << "RFFormatter: could not page-lock the RF buffer ("
                      << cudaGetErrorString(err)
                      << "), transferring unpinned.\n";
            pinHostRFBuffers = false;
        }
        cudaGetLastError();
    }

    /**
     * @brief Transfer RF to GPU memory.
     * @param pRF Pointer to raw RF data.
     */
    void transferRF2GPU(const rfType_t *pRF) {
        pinHostRF(pRF);
        gpuErrchk(cudaMemcpy(d_rfRaw, pRF,
                             receiveSpec.rfSize * sizeof(rfType_t),
                             cudaMemcpyHostToDevice));
    }

    /**
     * @brief Convert RF to BF type and discard inactive channels.
     */
    void RF2BFType() {
        // Convert RF from int16 to float (complex (IQ) or not) and discard
        // inactive elements (channels).
        int threadsPerBlock = 512;
        dim3 dimBlock(threadsPerBlock, 1, 1);
        dim3 dimGrid((receiveSpec.nSamplesIQ) * receiveSpec.nTX *
                             receiveSpec.nRepeats / threadsPerBlock +
                         1,
                     1, 1);

        formatRf_kernel<<<dimGrid, dimBlock>>>(d_rfFormatted, d_rfRaw,
                                               receiveSpec);
        gpuErrchk(cudaPeekAtLastError());
    }

    /**
     * @brief Transfer RF to GPU and format the channels (if applicable).
     * @param pRF Pointer to raw RF data.
     */
    void formatRF(const rfType_t *pRF) {
        transferRF2GPU(pRF);
        RF2BFType();
    }

    /**
     * @brief Copy formatted RF data from device to host.
     * @param formatted Host pointer to receive formatted data.
     */
    void GPU2Host(bfType_t *formatted) {
        int nSamples = receiveSpec.nSamplesIQ;
        gpuErrchk(cudaMemcpy(formatted, d_rfFormatted,
                             nSamples * receiveSpec.nTX * receiveSpec.nRepeats *
                                 receiveSpec.nActiveChannels * sizeof(bfType_t),
                             cudaMemcpyDeviceToHost));
    }

    /**
     * @brief Get pointer to formatted RF data on device.
     * @return bfType_t* Device pointer to formatted RF data.
     */
    bfType_t *getFormattedRF() { return d_rfFormatted; }
};
}  // namespace Beamform
