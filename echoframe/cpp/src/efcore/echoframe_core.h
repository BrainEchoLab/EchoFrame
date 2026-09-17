/**
 * @file echoframe_core.h
 * @author BrainEcho Lab
 * @brief  Header file of core class for EchoFrame processing pipeline.
 * This file contains the declaration of the EchoFrameCore class.
 * @details
 * The EchoFrameCore class is responsible for managing the processing pipeline
 * of the EchoFrame system, including beamforming, PDI processing, and storage
 * management. It provides methods for initializing the system, processing RF
 * data, and retrieving outputs. 
 * @version 0.1
 * @date 2025-06-20
 *
 * @copyright Copyright (c) 2025
 *
 */
#pragma once

// Project-specific includes
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../../libs/Storage/src/storage/Handler.h"
#include "../beamformer/BF_formatter.h"
#include "../beamformer/RF_formatter.h"
#include "../beamformer/echoframe_resources_bundle.h"
#include "../beamformer/fourier_imaging/fourier_imaging.h"
#include "../cuda/cuda_event_timer.hpp"
#include "../pdi/pdi_class.cuh"

namespace EchoFrame {

/**
 * @brief Streams that can rotate through a storage slot ring.
 * @details RF is not one of them. Staging it cost a whole RF frame per slot,
 * and the Verasonics acquisition ring already protects it -- see
 * refreshStorageSlotRings().
 */
enum class StorageStream { BF, PDI, RFTimeTag };

/**
 * @brief Whether one stream rotates through a slot ring.
 * @details PDI and time-tags default ON: with nBuffers slots a slot cannot be
 * reused while its write is still running, and their slots are small. BF
 * defaults off -- its slot is a whole beamformed frame. Set
 * EF_STORAGE_SLOT_RINGS to force all three to one value, or override a single
 * stream with EF_STORAGE_SLOT_RINGS_BF / _PDI / _TIMETAG, which always win.
 * Re-read at every init.
 */
bool storageSlotRingsEnabled(StorageStream stream);

/**
 * @brief Re-read the slot-ring environment variables.
 * @details Called at init. echoframe_mex calls mexLock(), so the module
 * survives `clear mex` and a value cached for the process would outlive the
 * session it was set for.
 */
void refreshStorageSlotRings();

/**
 * @struct EchoFrameOutputs
 * @brief Structure holding pointers to output data from the EchoFrame pipeline.
 */
struct EchoFrameOutputs {
    float *pBmode;  ///< Pointer to B‑mode output (real data)
    float2 *
        pBFComplex;  ///< Pointer to complex beamformed (BF) data (using float2)
    float *pPDI;     ///< Pointer to PDI results (real data)
};

/**
 * @struct EchoFrameTimings
 * @brief Per-stage timings (seconds) for the last process() call.
 *
 * Measured with CUDA events on the default stream. "Storage" stages report
 * near-zero when storage is disabled.
 */
struct EchoFrameTimings {
    float rf_transfer;     ///< Host-to-device RF transfer.
    float rf_formatting;   ///< RF format kernel.
    float beamforming;     ///< Fourier beamforming stage.
    float bf_formatting;   ///< BF post-formatting (B-mode, complex output).
    float pdi_processing;  ///< PDI SVD / covariance decomposition.
    float pdi_transfer;    ///< PDI device-to-host transfer.
    float bf_storage;      ///< BF storage (0 if save disabled).
    float pdi_storage;     ///< PDI storage (0 if save disabled).
    float total;           ///< Total process() wall time.
};

/**
 * @struct EchoFrameStreamStats
 * @brief Write instrumentation for one storage stream.
 *
 * @details The bf_storage / pdi_storage timings measure how long storeBuffer
 * took to queue a write. These are the completion numbers instead: how long
 * the disk held the source buffer, and how close the queue came to full.
 */
struct EchoFrameStreamStats {
    bool saving;                     ///< Whether this stream is being written.
    unsigned long long writes;       ///< Completed writes.
    unsigned long long buffersQueued;  ///< storeBuffer calls accepted.
    double latencyMeanMs;            ///< Mean queue-to-completion time.
    double latencyMaxMs;             ///< Worst queue-to-completion time.
    int peakInFlight;                ///< Highest concurrent outstanding writes.
    int queueCapacity;               ///< nBuffers-1: most that may be outstanding.
    int slotRingDepth;               ///< Producer slot-ring depth: nBuffers
                                     ///< with the ring on, 1 with it off.
    double blockedTotalMs;           ///< Time storeBuffer waited for a slot.
    double blockedMaxMs;             ///< Worst single wait.
    unsigned long long verified;     ///< Writes checked by EF_STORAGE_VERIFY.
    unsigned long long corrupted;    ///< Of those, sources that changed in flight.
};

/**
 * @struct EchoFrameStorageStats
 * @brief Write instrumentation for the streams the core owns. RF is written
 * by echoframe_mex and reported alongside these.
 */
struct EchoFrameStorageStats {
    EchoFrameStreamStats bf;
    EchoFrameStreamStats pdi;
    EchoFrameStreamStats timetag;
};

/**
 * @brief Fill an EchoFrameStreamStats from a handler's write instrumentation.
 */
template <typename bufferType_t>
inline EchoFrameStreamStats makeStreamStats(
    const Storage::Handler<bufferType_t> &handler,
    const Storage::StorageSpec &spec, int slotRingDepth = 1) {
    const Storage::WriteStats w = handler.getWriteStats();
    EchoFrameStreamStats s{};
    s.saving = spec.save;
    s.writes = w.completed;
    s.buffersQueued = static_cast<unsigned long long>(handler.getBuffersQueued());
    s.latencyMeanMs = w.latencyMeanMs();
    s.latencyMaxMs = w.latencyMaxMs;
    s.peakInFlight = w.outstandingHighWater;
    s.queueCapacity = spec.nBuffers > 1 ? spec.nBuffers - 1 : 1;
    s.slotRingDepth = slotRingDepth;
    s.blockedTotalMs = w.blockedSumMs;
    s.blockedMaxMs = w.blockedMaxMs;
    s.verified = w.verified;
    s.corrupted = w.corrupted;
    return s;
}

// EchoFrameCore class declaration.
class EchoFrameCore {
   public:
    /**
     * @brief Constructs the EchoFrameCore with full resources.
     * @param res Resource bundle for EchoFrame.
     * @param useStorage Whether to enable storage.
     */
    EchoFrameCore(const EchoframeResources &res, bool useStorage);

    /**
     * @brief Constructs the EchoFrameCore for PDI-only mode.
     * @param pdiSpec PDI specification.
     * @param receiveSpec Receive specification for beamforming.
     * @param reconSpec Reconstruction specification for beamforming.
     * @param pdiStorageSpec Storage specification for PDI.
     * @param useStorage Whether to enable storage.
     */
    EchoFrameCore(const PDI::PDISpec &pdiSpec,
                  const Beamform::ReceiveSpec &receiveSpec,
                  const Beamform::ReconSpec &reconSpec,
                  const Storage::StorageSpec &pdiStorageSpec, bool useStorage);
    /**
     * @brief Destructor for EchoFrameCore.
     */
    ~EchoFrameCore();

    /**
     * @brief Processes a frame of RF data.
     * @param RF Pointer to RF data.
     * @param startStorage Whether to start storage for this frame.
     */
    void process(const int16_t *RF, const bool startStorage);

    /**
     * @brief Processes RF data and returns output pointers.
     * @param RF Pointer to RF data.
     * @param startStorage Whether to start storage for this frame.
     * @return EchoFrameOutputs EchoFrameOutputs struct containing pointers to
     * outputs.
     */
    EchoFrameOutputs processAndGetOutputs(const int16_t *RF,
                                          const bool startStorage);
    /**
     * @brief Processes externally beamformed data in PDI-only mode.
     * @param externalBF_host Pointer to external beamformed data.
     * @param startStorage Whether to start storage for this frame.
     * @return float* Pointer to PDI result.
     */
    float *processPDIOnly(const float2 *externalBF_host, bool startStorage);

    /**
     * @brief Reinitializes storage with new resources.
     * @param newRes New resource bundle.
     */
    void reinitStorage(const EchoframeResources &newRes);

    /**
     * @brief Reinitializes the experiment with new resources.
     * @param newRes New resource bundle.
     */
    void reinitExperiment(const EchoframeResources &newRes);

    /**
     * @brief Updates the PDI threshold value.
     * @param newThreshold New threshold value.
     */
    void updatePDIThreshold(const float newThreshold);

    /**
     * @brief Updates the PDI lower (noise) threshold value.
     * @param newLowerThreshold New lower threshold value.
     */
    void updatePDILowerThreshold(const float newLowerThreshold);

    /**
     * @brief Returns the timing breakdown of the most recent process() call.
     * @return EchoFrameTimings in seconds per stage.
     */
    EchoFrameTimings getLastTimings();

    /**
     * @brief Write instrumentation for the BF, PDI and time-tag streams.
     * @return EchoFrameStorageStats, zeroed for streams that are not saving.
     */
    EchoFrameStorageStats getStorageStats() const;

   private:
    // Member variables.
    EchoframeResources resources;  // Bundled native resources.
    bool storageInitialized;       // Whether storage is initialized.

    // RF and BF formatters objects.
    Beamform::RFFormatter<int16_t, float2> rfFormatter;
    Beamform::BFFormatter<float2, float> bfFormatter;

    // Beamformer and PDI processing objects.
    Beamform::Beamformer<float2> *beamformerPtr;
    PDI::PDI *pdiObject;

    // Storage handlers and specifications.
    Storage::Handler<float2> bfStorageHandler;
    Storage::StorageSpec bfStorageSpec;
    Storage::Handler<float> pdiStorageHandler;
    Storage::StorageSpec pdiStorageSpec;
    Storage::Handler<double> rfTimeTagStorageHandler;
    Storage::StorageSpec rfTimeTagStorageSpec;

    // CUDA event timer.
    CudaEventTimer eventTimer;

    // Boolean flag for PDI-only mode.
    bool isPDIOnlyMode;

    // Pre-allocated time tag buffer, kept alive across calls so async I/O
    // (aio_write) never races a deallocation. cudaMallocHost rather than
    // std::vector because O_DIRECT needs a page-aligned address, which
    // alignof(double) does not give; the constructor verifies the alignment.
    // mTimeTags is a view into the ring, not the allocation: free mTimeTagsBase.

    // PDI slot process() stored, so processAndGetOutputs returns that buffer
    // rather than calling getResults() again -- each call advances the PDI
    // slot ring, and a second advance per frame wraps it before the write
    // from the first has drained.
    float *mLastPDIResult{nullptr};

    double *mTimeTags{nullptr};
    double *mTimeTagsBase{nullptr};
    size_t mTimeTagsCount{0};
    size_t mTimeTagsStride{0};
    int mTimeTagsSlots{1};
    int mTimeTagsSlot{0};

    /**
     * @brief (Re)allocate the time-tag slot ring.
     * @param nSlots Number of slots; the time-tag storage handler's nBuffers
     * when time tags are saved, 1 otherwise.
     * @details Requires mTimeTagsCount to be set. Throws if the allocation
     * is not page-aligned.
     */
    void resizeTimeTagRing(int nSlots);

    // Forward declarations for helper functions used in the pipeline.

    /**
     * @brief Prepares the beamforming pipeline.
     * @tparam rfType_t RF data type.
     * @tparam bfType_t Beamformed data type.
     * @tparam outputType_t Output data type.
     * @param resources Resource bundle.
     * @param rfFormatter RF formatter.
     * @param bfFormatter Beamforming formatter.
     * @param beamformerPtr Pointer to beamformer pointer.
     */
    template <typename rfType_t, typename bfType_t, typename outputType_t>
    void prepare_beamform(
        EchoframeResources &resources,
        Beamform::RFFormatter<rfType_t, bfType_t> &rfFormatter,
        Beamform::BFFormatter<bfType_t, outputType_t> &bfFormatter,
        Beamform::Beamformer<bfType_t> **beamformerPtr);

    /**
     * @brief Initializes storage handlers.
     * @tparam bfType_t Beamformed data type.
     * @tparam outputType_t Output data type.
     * @param resources Resource bundle.
     * @param bfStorageHandler Handler for beamformed data storage.
     * @param pdiStorageHandler Handler for PDI storage.
     * @param rfTimeTagStorageHandler Handler for RF time tag storage.
     */
    template <typename bfType_t, typename outputType_t>
    void initStorage(EchoframeResources &resources,
                     Storage::Handler<bfType_t> &bfStorageHandler,
                     Storage::Handler<outputType_t> &pdiStorageHandler,
                     Storage::Handler<double> &rfTimeTagStorageHandler);

    /**
     * @brief Computes time tags for RF data into the pre-allocated mTimeTags
     * buffer. Using a persistent member buffer avoids a use-after-free race
     * between async I/O (aio_write) and the per-call heap deallocation.
     * @param RF Pointer to RF data.
     * @param receiveSpec Receive specification.
     */
    void computeTimeTags(const int16_t *RF,
                         const Beamform::ReceiveSpec &receiveSpec);

    /**
     * @brief Handles storage of processing results.
     * @param storageInitialized Whether storage is initialized.
     * @param startStorage Whether to start storage for this frame.
     * @param bfStorageSpec Storage spec for beamformed data.
     * @param bfStorageHandler Handler for beamformed data storage.
     * @param bfFormatter Beamforming formatter.
     * @param pdiStorageSpec Storage spec for PDI.
     * @param pdiStorageHandler Handler for PDI storage.
     * @param pdiObject Pointer to PDI object.
     * @param pdiResult Pointer to PDI result.
     * @param rfTimeTagStorageSpec Storage spec for RF time tags.
     * @param rfTimeTagStorageHandler Handler for RF time tag storage.
     * @param ts Pointer to time tags.
     * @param eventTimer CUDA event timer.
     */
    void doStorage(bool storageInitialized, bool startStorage,
                   const Storage::StorageSpec &bfStorageSpec,
                   Storage::Handler<float2> &bfStorageHandler,
                   Beamform::BFFormatter<float2, float> &bfFormatter,
                   const Storage::StorageSpec &pdiStorageSpec,
                   Storage::Handler<float> &pdiStorageHandler,
                   PDI::PDI *pdiObject, float *pdiResult,
                   const Storage::StorageSpec &rfTimeTagStorageSpec,
                   Storage::Handler<double> &rfTimeTagStorageHandler,
                   double *ts, CudaEventTimer &eventTimer);
    /**
     * @brief Prints GPU information.
     */
    inline void printGPUInfo();
#if ENABLE_CUDA_TIMING
    /**
     * @brief Prints CUDA timing information.
     * @param timer CUDA event timer.
     */
    void printTimingInfo(CudaEventTimer &timer);
#endif
};
}  // namespace EchoFrame
