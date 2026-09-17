/**
 * @file echoframe_core.cu
 * @author BrainEcho Lab
 * @brief this file contains the implementation of the EchoFrameCore class.
 * @details This class is the main interface for the EchoFrame library, handling
 * the initialization, processing, and management of the EchoFrame pipeline.
 * * It includes methods for beamforming, PDI processing, and storage
 * management.
 * @version 0.1
 * @date 2025-06-20
 *
 * @copyright Copyright (c) 2025
 *
 */

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

#include <stdio.h>

#include "echoframe_core.h"
#define WIN32_LEAN_AND_MEAN
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <future>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>

#include <cuda_bf16.h>
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <gsl/gsl>

#include "../../libs/Storage/src/storage/Handler.t.hpp"
#include "../beamformer/beamformer.t.hpp"
#include "../beamformer/fourier_imaging/fourier_imaging.t.hpp"
#include "../cuda/cuda_error.h"

namespace EchoFrame {

namespace {
bool envFlag(const char *name, bool fallback) {
    const char *v = std::getenv(name);
    if (v == nullptr || v[0] == '\0') return fallback;
    return v[0] == '1';
}

/// Where banners and lifecycle chatter go: std::cout at normal and above, and
/// nowhere at EF_LOG_LEVEL=quiet. A stream rather than an `if` around each
/// block so a banner added later cannot forget the gate. Warnings and errors
/// keep writing to std::cout directly -- quiet does not hide those.
std::ostream &banner() {
    static std::ostream discard(nullptr);  // no streambuf: writes go nowhere
    return Storage::logAtLeast(Storage::kLogNormal) ? std::cout : discard;
}
}  // namespace

namespace {
// Cached per init, not per process: echoframe_mex calls mexLock(), so `clear
// mex` does not unload the module and a function-local static would freeze
// these for the whole MATLAB session -- changing the environment and re-running
// would then silently do nothing.
bool g_ringsRead = false;
bool g_ringBF = false, g_ringPDI = false, g_ringTag = false;
}  // namespace

void refreshStorageSlotRings() {
    // The log level first, because the report below goes through banner() and
    // this runs before echoframe_mex's reportStorageDebugFlags(). Without this
    // the block printed against whatever level the previous init left behind --
    // and on a freshly loaded module that is the kLogNormal default, so
    // EF_LOG_LEVEL=quiet did not suppress it at all. Refreshing twice per init
    // is free; reading a stale level is not.
    Storage::refreshStorageDebugFlags();

    // PDI and time-tag rings are on by default: with nBuffers slots a slot
    // cannot be reused while its write is still running, and their slots are
    // small enough that the memory costs little.
    //
    // BF is opt-in. Its slot is a whole beamformed frame, so a ring costs one
    // per slot. Turn it on with EF_STORAGE_SLOT_RINGS_BF=1 if stored BF is
    // suspect: a clinic run with it off corrupted 27 of 80 stored buffers
    // during a disk stall that the ringed streams came through clean.
    //
    // RF has no ring. Staging it costs a whole frame per slot -- about 50 ms on
    // the clinic protocol, which put the loop over its acquisition period -- and
    // the acquisition ring already does the job for free: the hardware only
    // reuses a receive frame after cycling through the others, so a deep enough
    // ring outlasts the write. init_storage warns when the depths make that
    // impossible.
    //
    // EF_STORAGE_SLOT_RINGS forces every stream to one value when set; the
    // per-stream flags always win over it.
    const char *global = std::getenv("EF_STORAGE_SLOT_RINGS");
    const bool globalSet = (global != nullptr && global[0] != '\0');
    const bool globalOn = globalSet && global[0] == '1';

    g_ringBF = envFlag("EF_STORAGE_SLOT_RINGS_BF", globalSet ? globalOn : false);
    g_ringPDI =
        envFlag("EF_STORAGE_SLOT_RINGS_PDI", globalSet ? globalOn : true);
    g_ringTag =
        envFlag("EF_STORAGE_SLOT_RINGS_TIMETAG", globalSet ? globalOn : true);
    g_ringsRead = true;

    auto word = [](bool b) { return b ? "ON " : "off"; };
    banner() << "*** Storage slot rings:  BF " << word(g_ringBF) << " | PDI "
             << word(g_ringPDI) << " | timetag " << word(g_ringTag)
             << "  (RF: none, see below)\n";
    if (!g_ringBF || !g_ringPDI || !g_ringTag)
        banner() << "    Streams marked off use one buffer and can be "
                    "corrupted by writes still in flight.\n"
                    "    Per-stream: EF_STORAGE_SLOT_RINGS_{BF,PDI,TIMETAG}"
                    "; EF_STORAGE_SLOT_RINGS sets all at once.\n";
    banner() << "    RF is unstaged: it is protected by the acquisition "
                "ring instead, which holds only while\n"
                "    RF writes in flight stay below "
                "Resource.RcvBuffer(1).numFrames.\n";
    banner() << std::flush;
}

bool storageSlotRingsEnabled(StorageStream stream) {
    if (!g_ringsRead) refreshStorageSlotRings();
    switch (stream) {
        case StorageStream::BF: return g_ringBF;
        case StorageStream::PDI: return g_ringPDI;
        case StorageStream::RFTimeTag: return g_ringTag;
    }
    return false;
}

namespace {
// Slots a producer needs in its output ring: nBuffers when the stream is
// saved and its ring is on, 1 otherwise.
int storageSlotsFor(const Storage::StorageSpec &spec, StorageStream stream) {
    if (!spec.save || !storageSlotRingsEnabled(stream)) return 1;
    return std::max(1, spec.nBuffers);
}
}  // namespace

EchoFrameCore::EchoFrameCore(const EchoframeResources &res, bool useStorage)
    : resources(res),
      beamformerPtr(nullptr),
      pdiObject(nullptr),
      storageInitialized(useStorage),
      isPDIOnlyMode(false) {
    // mTimeTagsCount has to be set before the ring is allocated.
    //
    // O_DIRECT requires a sector/page-aligned buffer address. cudaMallocHost is
    // not documented to guarantee page alignment, so check it here rather than
    // let a violation surface later as an aio_error two layers away.
    mTimeTagsCount =
        static_cast<size_t>(res.receiveSpec.nRepeats) * res.receiveSpec.nTX;
    resizeTimeTagRing(storageSlotsFor(res.rfTimeTagStorageSpec, StorageStream::RFTimeTag));

    // Initialization banner
    banner() << "+--------------------------- INITIALIZING ECHOFRAME "
                "---------------------------+"
             << std::endl;
    banner() << "| Initializing EchoFrame...                                  "
                "             |"
             << std::endl;
    banner() << "+------------------------------------------------------------"
                "----------------+"
             << std::endl;

    printGPUInfo();

    if (storageInitialized) {
        initStorage(resources, bfStorageHandler, pdiStorageHandler,
                    rfTimeTagStorageHandler);
    }

    prepare_beamform<int16_t, float2, float>(resources, rfFormatter,
                                             bfFormatter, &beamformerPtr);

    if (pdiObject) {
        delete pdiObject;
    }
    pdiObject = new PDI::PDI(resources.pdiSpec, resources.receiveSpec,
                             resources.reconSpec, false);
    pdiObject->setStorageSlots(storageSlotsFor(resources.pdiStorageSpec, StorageStream::PDI));

    banner() << "+----------------------------- ECHOFRAME INITIALIZED "
                "-----------------------------+"
             << std::endl;
}

EchoFrameCore::EchoFrameCore(const PDI::PDISpec &pdiSpec,
                             const Beamform::ReceiveSpec &receiveSpec,
                             const Beamform::ReconSpec &reconSpec,
                             const Storage::StorageSpec &pdiStorageSpec,
                             bool useStorage)
    : beamformerPtr(nullptr),
      pdiObject(nullptr),
      storageInitialized(useStorage),
      isPDIOnlyMode(true),
      resources(),                 // empty initialization
      rfFormatter(),               // empty initialization
      bfFormatter(),               // empty initialization
      bfStorageHandler(),          // empty initialization
      rfTimeTagStorageHandler() {  // empty initialization {
    resources.pdiSpec = pdiSpec;
    resources.receiveSpec = receiveSpec;
    resources.reconSpec = reconSpec;
    resources.pdiStorageSpec = pdiStorageSpec;

    // Initialization banner for PDI-only
    banner() << "+-------------------- INITIALIZING ECHOFRAME (PDI-only) "
                "--------------------+"
             << std::endl;
    banner() << "| Initializing EchoFrame (PDI processing mode)...            "
                "                |"
             << std::endl;
    banner() << "+------------------------------------------------------------"
                "-----------------+"
             << std::endl;
    if (pdiObject) {
        delete pdiObject;
    }
    pdiObject = new PDI::PDI(resources.pdiSpec, resources.receiveSpec,
                             resources.reconSpec, true);
    pdiObject->setStorageSlots(storageSlotsFor(resources.pdiStorageSpec, StorageStream::PDI));

    if (storageInitialized && resources.pdiStorageSpec.save) {
        pdiStorageHandler = Storage::Handler<float>(
            resources.pdiStorageSpec.filepath,
            resources.pdiStorageSpec.dataType,
            resources.pdiStorageSpec.bufferSize,
            resources.pdiStorageSpec.nWritesPerBuffer,
            resources.pdiStorageSpec.maxNBuffers,
            resources.pdiStorageSpec.nBuffers, resources.pdiStorageSpec.crop,
            resources.pdiStorageSpec.preallocateFullFile);
    }

    banner() << "+----------------------- ECHOFRAME PDI-ONLY INITIALIZED "
                "-----------------------+"
             << std::endl;
}

void EchoFrameCore::resizeTimeTagRing(int nSlots) {
    if (nSlots < 1) nSlots = 1;
    if (nSlots == mTimeTagsSlots && mTimeTagsBase != nullptr) return;

    // Every slot must be page-aligned for O_DIRECT, not just the base.
    // cudaMallocHost is not documented to guarantee it, so check rather than
    // let it resurface as an aio_error two layers away.
    constexpr uintptr_t kAssumedPageAlignment = 4096;
    constexpr size_t kTagsPerPage = kAssumedPageAlignment / sizeof(double);

    mTimeTagsSlots = nSlots;
    mTimeTagsSlot = 0;
    mTimeTagsStride =
        ((mTimeTagsCount + kTagsPerPage - 1) / kTagsPerPage) * kTagsPerPage;

    if (mTimeTagsBase) {
        gpuErrchk(cudaFreeHost(mTimeTagsBase));
        mTimeTagsBase = nullptr;
        mTimeTags = nullptr;
    }
    gpuErrchk(cudaMallocHost(&mTimeTagsBase,
                             static_cast<size_t>(mTimeTagsSlots) *
                                 mTimeTagsStride * sizeof(double)));
    mTimeTags = mTimeTagsBase;

    if (reinterpret_cast<uintptr_t>(mTimeTags) % kAssumedPageAlignment != 0) {
        cudaFreeHost(mTimeTagsBase);
        mTimeTagsBase = nullptr;
        mTimeTags = nullptr;
        throw std::runtime_error(
            "EchoFrameCore: cudaMallocHost returned a buffer not aligned to "
            "the assumed page size (" +
            std::to_string(kAssumedPageAlignment) +
            " bytes) -- the mTimeTags O_DIRECT alignment assumption no "
            "longer holds on this platform/driver.");
    }
}

EchoFrameCore::~EchoFrameCore() {
    banner() << "+----------------------------- DESTROYING ECHOFRAME "
                "-----------------------------+"
             << std::endl;

    // Before anything a write might still be reading is freed. The handlers are
    // members, so their own destructors run after this body -- by which point
    // the time-tag ring and the PDI buffers below are already gone.
    // Caught rather than propagated: this is a destructor, and an escaping
    // exception here would terminate the process instead of reporting.
    try {
        bfStorageHandler.finishWrites();
        pdiStorageHandler.finishWrites();
        rfTimeTagStorageHandler.finishWrites();
    } catch (const std::exception &e) {
        std::cerr << "[storage] could not complete pending writes: " << e.what()
                  << "\n";
    }

    if (mTimeTagsBase) {
        gpuErrchk(cudaFreeHost(mTimeTagsBase));
        mTimeTagsBase = nullptr;
        mTimeTags = nullptr;
    }
    if (pdiObject) {
        delete pdiObject;
        pdiObject = nullptr;
    }
    if (!isPDIOnlyMode && beamformerPtr) {
        banner() << "Cleaning up beamformer..." << std::endl;
        delete beamformerPtr;  // virtual ~Beamformer routes to FourierImaging
        banner() << "Beamformer cleaned up." << std::endl;
        beamformerPtr = nullptr;
        banner() << "Beamformer pointer set to nullptr." << std::endl;
    }

    banner() << "+----------------------- ECHOFRAME DESTRUCTOR COMPLETE "
                "------------------------+"
             << std::endl;
}

void EchoFrameCore::process(const int16_t *RF, const bool startStorage) {
    if (!beamformerPtr)
        throw std::runtime_error(
            "EchoFrame not initialized. Call 'initialize' first.");

    // Ensure the device that owns our CUDA handles is current. Cheap safety
    // net; under normal conditions this is already the case.
    cudaSetDevice(0);

    // Prime storage events so elapsedTime() always returns a valid number
    // even when storage is disabled this frame. doStorage may overwrite.
    eventTimer.start("BFStorage");
    eventTimer.stop("BFStorage");
    eventTimer.start("PDIStorage");
    eventTimer.stop("PDIStorage");

    eventTimer.start("TotalTime");
    using std::chrono::duration;
    using std::chrono::duration_cast;
    using std::chrono::high_resolution_clock;
    using std::chrono::milliseconds;

    computeTimeTags(RF, resources.receiveSpec);
    eventTimer.start("RFTransfer");
    rfFormatter.transferRF2GPU(RF);
    eventTimer.stop("RFTransfer");
    eventTimer.start("RFFormatting");
    rfFormatter.RF2BFType();
    eventTimer.stop("RFFormatting");
    eventTimer.start("Beamforming");
    beamformerPtr->process();
    eventTimer.stop("Beamforming");
    eventTimer.start("BFFormatting");
    bfFormatter.BF2OutputType(beamformerPtr->getBF(),
                              resources.reconSpec.cropBF);
    bfFormatter.getOutputBmode();
    bfFormatter.getComplexOutput();
    eventTimer.stop("BFFormatting");
    eventTimer.start("PDIProcessing");
    pdiObject->runPDI(bfFormatter.getOutputPointer());
    eventTimer.stop("PDIProcessing");
    eventTimer.start("PDITransfer");
    float *pdiResult = pdiObject->getResults();
    mLastPDIResult = pdiResult;
    eventTimer.stop("PDITransfer");
    // Perform storage operations if required.
    doStorage(storageInitialized, startStorage, resources.bfStorageSpec,
              bfStorageHandler, bfFormatter, resources.pdiStorageSpec,
              pdiStorageHandler, pdiObject, pdiResult,
              resources.rfTimeTagStorageSpec, rfTimeTagStorageHandler,
              mTimeTags, eventTimer);
    eventTimer.stop("TotalTime");

#if ENABLE_CUDA_TIMING
    printTimingInfo(eventTimer);
#endif
}

EchoFrameOutputs EchoFrameCore::processAndGetOutputs(const int16_t *RF,
                                                     const bool startStorage) {
    process(RF, startStorage);
    return {bfFormatter.pinnedBmode, bfFormatter.pinnedBF, mLastPDIResult};
}

float *EchoFrameCore::processPDIOnly(const float2 *externalBF_host,
                                     bool startStorage) {
    if (!pdiObject) throw std::runtime_error("PDI object not initialized.");
    eventTimer.start("ExternalBFTransfer");
    pdiObject->transferExternalBFToGPU(externalBF_host);
    eventTimer.stop("ExternalBFTransfer");

    eventTimer.start("PDIProcessing");
    pdiObject->runExternalBFPDI();
    eventTimer.stop("PDIProcessing");

    eventTimer.start("PDITransfer");
    float *pdiResult = pdiObject->getResults();
    eventTimer.stop("PDITransfer");

    // Optionally handle storage
    if (storageInitialized && startStorage && resources.pdiStorageSpec.save) {
        eventTimer.start("PDIStorage");
        if (resources.pdiStorageSpec.crop) {
            pdiStorageHandler.storeBuffer(pdiObject->getCroppedResults());
        } else {
            pdiStorageHandler.storeBuffer(pdiResult);
        }
        eventTimer.stop("PDIStorage");
    }

#if ENABLE_CUDA_TIMING
    printTimingInfo(eventTimer);
#endif

    return pdiResult;
}

void EchoFrameCore::reinitStorage(const EchoframeResources &newRes) {
    resources.reconSpec = newRes.reconSpec;
    resources.pdiSpec = newRes.pdiSpec;

    resources.bfStorageSpec = newRes.bfStorageSpec;
    resources.pdiStorageSpec = newRes.pdiStorageSpec;
    resources.rfTimeTagStorageSpec = newRes.rfTimeTagStorageSpec;

    initStorage(resources, bfStorageHandler, pdiStorageHandler,
                rfTimeTagStorageHandler);

    storageInitialized = true;

    // Saving may have just been switched on; resize before updateCropSpecs()
    // reallocates the cropped ring.
    bfFormatter.setStorageSlots(storageSlotsFor(resources.bfStorageSpec, StorageStream::BF),
                                resources.bfStorageSpec.crop);
    resizeTimeTagRing(storageSlotsFor(resources.rfTimeTagStorageSpec, StorageStream::RFTimeTag));

    if (resources.bfStorageSpec.crop) {
        bfFormatter.updateCropSpecs(resources.reconSpec);
    }

    if (resources.pdiStorageSpec.crop) {
        if (pdiObject != nullptr) {
            delete pdiObject;
            pdiObject = nullptr;
        }

        pdiObject = new PDI::PDI(resources.pdiSpec, resources.receiveSpec,
                                 resources.reconSpec);
    }
    if (pdiObject != nullptr)
        pdiObject->setStorageSlots(storageSlotsFor(resources.pdiStorageSpec, StorageStream::PDI));
}

void EchoFrameCore::reinitExperiment(const EchoframeResources &newRes) {
    // Temporary storage handler objects.
    Storage::Handler<float2> newBFStorageHandler;
    Storage::Handler<float> newPDIStorageHandler;
    Storage::Handler<double> newRFTimeTagStorageHandler;

    resources.bfStorageSpec = newRes.bfStorageSpec;
    resources.pdiStorageSpec = newRes.pdiStorageSpec;
    resources.rfTimeTagStorageSpec = newRes.rfTimeTagStorageSpec;

    // Initialize the new storage handlers with the updated storage specs.
    initStorage(resources, newBFStorageHandler, newPDIStorageHandler,
                newRFTimeTagStorageHandler);
    storageInitialized = true;

    bfStorageHandler = std::move(newBFStorageHandler);
    pdiStorageHandler = std::move(newPDIStorageHandler);
    rfTimeTagStorageHandler = std::move(newRFTimeTagStorageHandler);

    // The new specs may enable or disable saving; re-size the rings to match.
    bfFormatter.setStorageSlots(storageSlotsFor(resources.bfStorageSpec, StorageStream::BF),
                                resources.bfStorageSpec.crop);
    if (pdiObject != nullptr)
        pdiObject->setStorageSlots(storageSlotsFor(resources.pdiStorageSpec, StorageStream::PDI));
    resizeTimeTagRing(storageSlotsFor(resources.rfTimeTagStorageSpec, StorageStream::RFTimeTag));
}

void EchoFrameCore::updatePDIThreshold(const float newThreshold) {
    resources.pdiSpec.threshold = newThreshold;
    pdiObject->updateThreshold(resources.pdiSpec.threshold);
}

void EchoFrameCore::updatePDILowerThreshold(const float newLowerThreshold) {
    resources.pdiSpec.lowerThreshold = newLowerThreshold;
    pdiObject->updateLowerThreshold(resources.pdiSpec.lowerThreshold);
}

EchoFrameTimings EchoFrameCore::getLastTimings() {
    EchoFrameTimings t{};
    t.rf_transfer    = eventTimer.elapsedTime("RFTransfer");
    t.rf_formatting  = eventTimer.elapsedTime("RFFormatting");
    t.beamforming    = eventTimer.elapsedTime("Beamforming");
    t.bf_formatting  = eventTimer.elapsedTime("BFFormatting");
    t.pdi_processing = eventTimer.elapsedTime("PDIProcessing");
    t.pdi_transfer   = eventTimer.elapsedTime("PDITransfer");
    t.bf_storage     = eventTimer.elapsedTime("BFStorage");  // queueing, not the write
    t.pdi_storage    = eventTimer.elapsedTime("PDIStorage");
    t.total          = eventTimer.elapsedTime("TotalTime");
    return t;
}

EchoFrameStorageStats EchoFrameCore::getStorageStats() const {
    EchoFrameStorageStats s{};
    s.bf = makeStreamStats(
        bfStorageHandler, resources.bfStorageSpec,
        storageSlotsFor(resources.bfStorageSpec, StorageStream::BF));
    s.pdi = makeStreamStats(
        pdiStorageHandler, resources.pdiStorageSpec,
        storageSlotsFor(resources.pdiStorageSpec, StorageStream::PDI));
    s.timetag = makeStreamStats(
        rfTimeTagStorageHandler, resources.rfTimeTagStorageSpec,
        storageSlotsFor(resources.rfTimeTagStorageSpec,
                        StorageStream::RFTimeTag));
    return s;
}

template <typename rfType_t, typename bfType_t, typename outputType_t>
void EchoFrameCore::prepare_beamform(
    EchoframeResources &resources,
    Beamform::RFFormatter<rfType_t, bfType_t> &rfFormatter,
    Beamform::BFFormatter<bfType_t, outputType_t> &bfFormatter,
    Beamform::Beamformer<bfType_t> **beamformerPtr) {
    rfFormatter = std::move(Beamform::RFFormatter<rfType_t, bfType_t>(
        resources.receiveSpec));

    bfFormatter = std::move(Beamform::BFFormatter<bfType_t, outputType_t>(
        resources.receiveSpec, resources.reconSpec,
        resources.reconSpec.totalSize * resources.reconSpec.ensembleSize,
        resources.reconSpec.totalSizeCropped * resources.reconSpec.ensembleSize));

    // Size the BF ring before initializeResources() allocates the cropped one.
    bfFormatter.setStorageSlots(storageSlotsFor(resources.bfStorageSpec, StorageStream::BF),
                                resources.bfStorageSpec.crop);

    bfFormatter.initializeResources();

    // Heap-allocate so each init gets a fresh instance sized for the current
    // specs; a static instance could only be sized once per MEX load. Owned by
    // EchoFrameCore::beamformerPtr and deleted in the destructor.
    *beamformerPtr = new Beamform::FourierImaging<bfType_t>(
        std::move(resources.receiveSpec), resources.reconSpec,
        std::move(resources.fourierReconSpec), rfFormatter.getFormattedRF());
}

template <typename bfType_t, typename outputType_t>
void EchoFrameCore::initStorage(
    EchoframeResources &resources, Storage::Handler<bfType_t> &bfStorageHandler,
    Storage::Handler<outputType_t> &pdiStorageHandler,
    Storage::Handler<double> &rfTimeTagStorageHandler) {
    if (resources.bfStorageSpec.save) {
        bfStorageHandler = std::move(Storage::Handler<float2>(
            resources.bfStorageSpec.filepath, resources.bfStorageSpec.dataType,
            resources.bfStorageSpec.bufferSize,
            resources.bfStorageSpec.nWritesPerBuffer,
            resources.bfStorageSpec.maxNBuffers,
            resources.bfStorageSpec.nBuffers, resources.bfStorageSpec.crop,
            resources.bfStorageSpec.preallocateFullFile));
    }

    if (resources.pdiStorageSpec.save) {
        pdiStorageHandler = std::move(Storage::Handler<float>(
            resources.pdiStorageSpec.filepath,
            resources.pdiStorageSpec.dataType,
            resources.pdiStorageSpec.bufferSize,
            resources.pdiStorageSpec.nWritesPerBuffer,
            resources.pdiStorageSpec.maxNBuffers,
            resources.pdiStorageSpec.nBuffers, resources.pdiStorageSpec.crop,
            resources.pdiStorageSpec.preallocateFullFile));
    }

    if (resources.rfTimeTagStorageSpec.save) {
        rfTimeTagStorageHandler = std::move(Storage::Handler<double>(
            resources.rfTimeTagStorageSpec.filepath,
            resources.rfTimeTagStorageSpec.dataType,
            resources.rfTimeTagStorageSpec.bufferSize,
            resources.rfTimeTagStorageSpec.nWritesPerBuffer,
            resources.rfTimeTagStorageSpec.maxNBuffers,
            resources.rfTimeTagStorageSpec.nBuffers,
            resources.rfTimeTagStorageSpec.crop,
            resources.rfTimeTagStorageSpec.preallocateFullFile));
    }
}

// Fills mTimeTags with one timestamp per (repeat, TX) pair. The buffer is a
// persistent member rather than a per-call allocation: aio_write holds a raw
// pointer into it until the write completes.
void EchoFrameCore::computeTimeTags(const int16_t *RF,
                                    const Beamform::ReceiveSpec &receiveSpec) {
    // Advance before filling, so mTimeTags names this frame's buffer.
    mTimeTagsSlot = (mTimeTagsSlot + 1) % mTimeTagsSlots;
    mTimeTags =
        mTimeTagsBase + static_cast<size_t>(mTimeTagsSlot) * mTimeTagsStride;

    for (int k = 0; k < receiveSpec.nRepeats; ++k) {
        for (int i = 0; i < receiveSpec.nTX; ++i) {
            int index = k * receiveSpec.nTX + i;
            int baseIndex = k * receiveSpec.nSamples * receiveSpec.nTX +
                            i * receiveSpec.nSamples;
            double W1 = static_cast<double>(RF[baseIndex]);
            double W2 = static_cast<double>(RF[baseIndex + 1]);
            if (W1 < 0) W1 += 65536;
            if (W2 < 0) W2 += 65536;
            mTimeTags[index] = (W1 + 65536 * W2) / 4e4;
        }
    }
}

void EchoFrameCore::doStorage(bool storageInitialized, bool startStorage,
                              const Storage::StorageSpec &bfStorageSpec,
                              Storage::Handler<float2> &bfStorageHandler,
                              Beamform::BFFormatter<float2, float> &bfFormatter,
                              const Storage::StorageSpec &pdiStorageSpec,
                              Storage::Handler<float> &pdiStorageHandler,
                              PDI::PDI *pdiObject, float *pdiResult,
                              const Storage::StorageSpec &rfTimeTagStorageSpec,
                              Storage::Handler<double> &rfTimeTagStorageHandler,
                              double *ts, CudaEventTimer &eventTimer) {
    if (!startStorage) return;
    if (!storageInitialized) {
        std::cout << "Warning: Storage requested but not initialized. Cannot "
                     "store data."
                  << std::endl;
        return;
    }
    if (bfStorageSpec.save) {
        eventTimer.start("BFStorage");
        if (bfStorageSpec.crop) {
            bfFormatter.getCroppedBF();
            bfStorageHandler.storeBuffer(bfFormatter.pinnedBFCropped);
        } else {
            bfStorageHandler.storeBuffer(bfFormatter.pinnedBF);
        }
        eventTimer.stop("BFStorage");
    }
    if (pdiStorageSpec.save) {
        eventTimer.start("PDIStorage");
        if (pdiStorageSpec.crop) {
            pdiStorageHandler.storeBuffer(pdiObject->getCroppedResults());
        } else {
            pdiStorageHandler.storeBuffer(pdiResult);
        }
        eventTimer.stop("PDIStorage");
    }
    if (rfTimeTagStorageSpec.save) {
        rfTimeTagStorageHandler.storeBuffer(ts);
    }
}

// Helper to print GPU information (VRAM, name, compute capability)
// At the very bottom of EchoFrameCore.hpp, **outside** of the class
// declaration:
inline void EchoFrameCore::printGPUInfo() {
    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);
    if (err != cudaSuccess) {
        std::cerr << "[GPU INFO] Failed to get CUDA device count: "
                  << cudaGetErrorString(err) << std::endl;
        return;
    }
    // Top border
    banner() << "+-------------------------------------- GPU INFO "
                "--------------------------------------+"
             << std::endl;
    for (int dev = 0; dev < deviceCount; ++dev) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, dev);
        banner() << "| Device " << dev << ": " << prop.name;
        // pad to width
        banner() << std::string(80 - std::string("| Device ").size() -
                                    std::to_string(dev).size() -
                                    std::strlen(prop.name),
                                ' ')
                 << "|" << std::endl;
        banner() << "|    VRAM: " << (prop.totalGlobalMem / (1024 * 1024))
                 << " MB";
        banner() << std::string(
                        80 - std::string("|    VRAM: ").size() -
                            std::to_string(prop.totalGlobalMem / (1024 * 1024))
                                .size() -
                            3,
                        ' ')
                 << "|" << std::endl;
        banner() << "|    Compute Capability: " << prop.major << "."
                 << prop.minor;
        banner() << std::string(
                        80 - std::string("|    Compute Capability: ").size() -
                            std::to_string(prop.major).size() -
                            std::to_string(prop.minor).size() - 1,
                        ' ')
                 << "|" << std::endl;
    }
    // Bottom border
    banner() << "+------------------------------------------------------------"
                "------------------------+"
             << std::endl;
}

#if ENABLE_CUDA_TIMING
// -----------------------------------------------------------------------------
// printTimingInfo: prints timing measurements.
void EchoFrameCore::printTimingInfo(CudaEventTimer &timer) {
    // Five lines per processed frame, which is most of what an acquisition
    // console shows. ENABLE_CUDA_TIMING decides whether the events are recorded
    // at all -- a build decision -- and the log level decides whether they are
    // printed, so a timing build can still run quiet without being rebuilt.
    if (!Storage::logAtLeast(Storage::kLogTrace)) return;

    std::cout << "RF Formatting time: " << timer.elapsedTime("RFFormatting")
              << " seconds\n";
    std::cout << "Beamforming time: " << timer.elapsedTime("Beamforming")
              << " seconds\n";
    std::cout << "BF Formatting time: " << timer.elapsedTime("BFFormatting")
              << " seconds\n";
    std::cout << "PDI Processing time: " << timer.elapsedTime("PDIProcessing")
              << " seconds\n";
    std::cout << "PDI Transfer time: " << timer.elapsedTime("PDITransfer")
              << " seconds\n";
}
#endif
};  // namespace EchoFrame
