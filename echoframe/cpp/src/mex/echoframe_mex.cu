/**
 * @file echoframe_mex.cu
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
#include "echoframe_mex.h"

#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "../efcore/echoframe_ci_interface.h"
#include "../efcore/echoframe_core.h"
#include "storage/Handler.t.hpp"

static EchoFrameHandle *ef_handle = nullptr;
static Storage::Handler<int16_t> rf_storage_handler;
static Storage::StorageSpec rf_storage_spec{};

static mxArray *buildMatlabTimings(const EchoFrame::EchoFrameTimings &timings);
static mxArray *buildStorageStats(
    const EchoFrame::EchoFrameStorageStats &core);

// RF is never staged into buffers of ours. Copying each frame cost a whole RF
// frame per slot -- about 50 ms on the clinic protocol, which put the loop over
// its acquisition period. The Verasonics acquisition ring does the same job for
// free: the hardware only reuses a receive frame after cycling through the
// others, so a deep enough ring outlasts the write, and init_storage warns when
// the depths make that impossible. Storage DMAs straight from the caller's array.

// Does the RF array handed to the callback alias a Verasonics receive frame, or
// is it a copy? The two need opposite fixes -- a deeper acquisition ring only
// helps if it aliases -- so log the data pointer per frame and read the pattern:
//
//   cycles through N distinct addresses  -> aliases a ring of N frames
//   one address every frame              -> single buffer, ring depth is a lie
//   a fresh address most frames          -> a copy; ring depth is irrelevant
//
// Off unless EF_DEBUG_RF_PTR=1. Diagnostic only.
//
// Re-read at init rather than cached for the process: mexLock keeps the module
// loaded across `clear mex`, so a once-per-process flag would ignore every
// later change in the session.
static bool rf_ptr_log_on = false;
static std::vector<const void *> rf_ptr_seen;
static std::vector<int> rf_ptr_last_frame;
static int rf_ptr_frame = 0;

static void refreshRFPointerLog() {
    const char *v = std::getenv("EF_DEBUG_RF_PTR");
    rf_ptr_log_on = (v != nullptr && v[0] == '1');
    rf_ptr_seen.clear();
    rf_ptr_last_frame.clear();
    rf_ptr_frame = 0;
}

static void logRFPointer(const void *p) {
    if (!rf_ptr_log_on) return;

    std::vector<const void *> &seen = rf_ptr_seen;
    std::vector<int> &lastFrame = rf_ptr_last_frame;
    int &frame = rf_ptr_frame;
    ++frame;

    int slot = -1;
    for (size_t i = 0; i < seen.size(); ++i) {
        if (seen[i] == p) {
            slot = static_cast<int>(i);
            break;
        }
    }
    int since = -1;
    if (slot < 0) {
        seen.push_back(p);
        lastFrame.push_back(frame);
        slot = static_cast<int>(seen.size()) - 1;
    } else {
        since = frame - lastFrame[static_cast<size_t>(slot)];
        lastFrame[static_cast<size_t>(slot)] = frame;
    }

    mexPrintf("[rfptr] frame %3d | %p | slot %d of %d distinct | ", frame, p,
              slot, static_cast<int>(seen.size()));
    if (since < 0)
        mexPrintf("NEW");
    else
        mexPrintf("reused after %d frame(s)", since);
    mexPrintf("\n");
}

static void resetRFStorage() {
    rf_storage_handler = Storage::Handler<int16_t>{};
    rf_storage_spec = Storage::StorageSpec{};
}

// Print the storage debug knobs, so a log says which configuration produced it.
static void reportStorageDebugFlags() {
    const Storage::StorageDebugFlags &f = Storage::refreshStorageDebugFlags();
    if (Storage::logAtLeast(Storage::kLogNormal))
        mexPrintf(
            "*** Storage instrumentation: stats %s | verify %s (%d probes) | "
            "write delay %d ms\n",
            f.report ? "ON " : "off", f.verify ? "ON " : "off", f.probes,
            f.delayWriteMs);
    // The delay warning is not a banner: it says the run must not be trusted as
    // data, so quiet does not get to hide it.
    if (f.delayWriteMs > 0)
        mexPrintf(
            "    EF_STORAGE_DELAY_WRITE_MS is holding every write back. This "
            "deliberately widens the\n"
            "    race window and is for testing only -- do not record real "
            "data with it set.\n");
}

static void reinitRFStorage(const Storage::StorageSpec &spec) {
    rf_storage_spec = spec;

    // EF_RF_STORAGE_BUFFERS overrides the RF write queue depth without a
    // rebuild. numberOfBuffers-1 writes may be outstanding, and that must stay
    // below the acquisition ring depth or the hardware can overwrite a buffer
    // that is still being written.
    const int depthOverride = Storage::detail::envInt("EF_RF_STORAGE_BUFFERS", 0);
    if (depthOverride > 0 && depthOverride != rf_storage_spec.nBuffers) {
        // Ungated on purpose, unlike the "*** " lines above it. Those describe
        // the configuration; this one says the queue depth is no longer the one
        // init_storage checked against the acquisition ring, which is how RF
        // gets overwritten mid-write. A recording that loses this line loses
        // the only record that the depth was moved, so quiet does not take it.
        mexPrintf("*** RF storage depth: %d -> %d (EF_RF_STORAGE_BUFFERS)\n",
                  rf_storage_spec.nBuffers, depthOverride);
        rf_storage_spec.nBuffers = depthOverride;
    }

    if (!rf_storage_spec.save) {
        rf_storage_handler = Storage::Handler<int16_t>{};
        return;
    }

    rf_storage_handler = Storage::Handler<int16_t>(
        rf_storage_spec.filepath, rf_storage_spec.dataType,
        rf_storage_spec.bufferSize, rf_storage_spec.nWritesPerBuffer,
        rf_storage_spec.maxNBuffers, rf_storage_spec.nBuffers,
        rf_storage_spec.crop, rf_storage_spec.preallocateFullFile);
}

static void efMexDispatch(int nlhs, mxArray *plhs[], int nrhs,
                          const mxArray *prhs[]) {
    // Register cleanup once per load; subsequent calls are harmless but noisy.
    static bool atexit_registered = false;
    if (!atexit_registered) {
        mexAtExit(mexAtExitCleanup);
        atexit_registered = true;
    }

    if (nrhs < 1)
        mexErrMsgTxt("At least one input argument (the command) is required.");
    if (!mxIsChar(prhs[0])) mexErrMsgTxt("Command must be a string.");

    std::string command = mxArrayToStdString(prhs[0]);

    static EchoframeResources res;

    // std::cout << "Command: " << command << std::endl;

    if (command == "init") {
        // Re-read the slot-ring flags for THIS init. mexLock keeps the module
        // loaded across `clear mex`, so anything cached for the process would
        // outlive the session it was set for and the toggle would look stuck.
        EchoFrame::refreshStorageSlotRings();
        reportStorageDebugFlags();
        refreshRFPointerLog();

        // Auto-destroy any existing instance. mexLock() prevents `clear mex`
        // from running the atExit cleanup, so without this, a second `init`
        // after `clear mex` would see a stale ef_handle and error.
        if (ef_handle) {
            EchoFrameDestroy(ef_handle);
            ef_handle = nullptr;
        }

        bool useStorage;
        if (nrhs != 8 && nrhs != 7 && nrhs != 4)
            mexErrMsgTxt(
                "Init requires 8 (with RF storage), 7 (without RF storage), or "
                "4 (without storage) arguments.");
        // Convert MATLAB structs into native EF structures:
        if (nrhs == 4) {
            MexToNative::convertMexResources(prhs, res);
            useStorage = false;
            resetRFStorage();
        } else {
            MexToNative::convertMexResourcesWithStorage(prhs, nrhs, res);
            useStorage = true;
            reinitRFStorage(res.storageSpec);
        }
        ef_handle = EchoFrameCreate(&res, useStorage);
        // Keep the MEX in memory while CUDA resources are live: MATLAB may
        // otherwise unload it between calls and destroy the cuBLAS / cuFFT
        // handles.
        if (!mexIsLocked()) mexLock();
    } else if (command == "process" ||
               command == "updatePDIthreshold&process" ||
               command == "updatePDInoiseThreshold&process") {
        if (command == "updatePDIthreshold&process") {
            // Extract new upper (tissue) threshold if required.
            res.pdiSpec.threshold =
                mxGetSingles(prhs[PROCESS_INPUT_UPDATE_SVD_THRESHOLD])[0];
            EchoFrameUpdatePDIThreshold(ef_handle, res.pdiSpec.threshold);
        } else if (command == "updatePDInoiseThreshold&process") {
            // Extract new lower (noise) threshold if required.
            res.pdiSpec.lowerThreshold =
                mxGetSingles(prhs[PROCESS_INPUT_UPDATE_SVD_THRESHOLD])[0];
            EchoFrameUpdatePDILowerThreshold(ef_handle,
                                             res.pdiSpec.lowerThreshold);
        }
        // Extract the RF buffer (fast operation).
        auto RF = mxGetBuffer<int16_t>(prhs[PROCESS_INPUT_RF_POS]);

        bool startStorage = mxGetLogicals(prhs[PROCESS_SAVE_FLAG])[0];

        // Stage only when RF is actually written; otherwise nothing is in
        // flight and the caller's pointer is used directly, as before.
        const bool storingRF = startStorage && rf_storage_spec.save;

        // The pointer Verasonics handed us, which is also the one storage
        // writes from -- nothing copies RF in between.
        logRFPointer(static_cast<const void *>(RF));

        // Call the core processing method.
        EchoFrame::EchoFrameOutputs outputs = EchoFrameProcessAndGetOutputs(
            ef_handle, RF, startStorage);

        // Store the RF buffer -- from our slot, never from MATLAB's array.
        if (storingRF) {
            rf_storage_handler.storeBuffer(RF);
        }

        buildMatlabOutput(nlhs, plhs, res, outputs.pPDI, outputs.pBmode,
                          outputs.pBFComplex);

        // Optional 4th output: per-stage timings struct (seconds).
        if (nlhs >= 4) {
            plhs[3] = buildMatlabTimings(EchoFrameGetLastTimings(ef_handle));
        }
    } else if (command == "timings") {
        if (!ef_handle) mexErrMsgTxt("EchoFrame is not initialized.");
        if (nlhs != 1) mexErrMsgTxt("timings requires exactly one output.");
        plhs[0] = buildMatlabTimings(EchoFrameGetLastTimings(ef_handle));
    } else if (command == "storage_stats") {
        if (!ef_handle) mexErrMsgTxt("EchoFrame is not initialized.");
        if (nlhs != 1) mexErrMsgTxt("storage_stats requires exactly one output.");
        plhs[0] = buildStorageStats(EchoFrameGetStorageStats(ef_handle));
    } else if (command == "re-init storage") {
        // Re-read here too: a re-init opens new files and re-sizes the rings,
        // so it must honour a flag changed since 'init'.
        EchoFrame::refreshStorageSlotRings();
        reportStorageDebugFlags();
        MexToNative::convertReinitStorage(prhs, nrhs, res);
        reinitRFStorage(res.storageSpec);
        EchoFrameReinitStorage(ef_handle, res);

    } else if (command == "re-init experiment") {
        EchoFrame::refreshStorageSlotRings();
        reportStorageDebugFlags();
        MexToNative::convertReinitExperiment(prhs, nrhs, res);
        reinitRFStorage(res.storageSpec);
        EchoFrameReinitExperiment(ef_handle, res);

    } else if (command == "init_pdi_only") {
        // Re-read for this init, as in 'init'.
        EchoFrame::refreshStorageSlotRings();
        reportStorageDebugFlags();
        if (ef_handle) {
            EchoFrameDestroy(ef_handle);
            ef_handle = nullptr;
        }

        bool useStorage;
        if (nrhs != 8 && nrhs != 7 && nrhs != 4)
            mexErrMsgTxt(
                "Init requires 8 (with RF storage), 7 (without RF storage), or "
                "4 (without storage) arguments.");
        // Convert MATLAB structs into native EF structures:
        if (nrhs == 4) {
            MexToNative::convertMexResources(prhs, res);
            useStorage = false;
            resetRFStorage();
            if (Storage::logAtLeast(Storage::kLogNormal))
                std::cout << "Using default storage" << std::endl;
        } else {
            MexToNative::convertMexResourcesWithStorage(prhs, nrhs, res);
            useStorage = true;
            reinitRFStorage(res.storageSpec);
        }
        ef_handle =
            EchoFrameCreatePDIOnly(res.pdiSpec, res.receiveSpec, res.reconSpec,
                                   res.pdiStorageSpec, useStorage);
        if (!mexIsLocked()) mexLock();

    } else if (command == "process_pdi_only") {
        if (nrhs < 3)
            mexErrMsgTxt("process_pdi_only needs BF input and storage flag.");

        auto externalBF =
            reinterpret_cast<float2 *>(mxGetComplexSingles(prhs[1]));
        bool startStorage = mxGetLogicals(prhs[2])[0];

        float *pdiResult =
            EchoFrameProcessPDIOnly(ef_handle, externalBF, startStorage);

        // Only returning PDI result
        const mwSize dims[] = {static_cast<mwSize>(res.reconSpec.nz),
                               static_cast<mwSize>(res.reconSpec.nx),
                               static_cast<mwSize>(res.pdiSpec.num_ensembles)};

        plhs[0] = mxCreateNumericArray(3, dims, mxSINGLE_CLASS, mxREAL);
        memcpy(
            mxGetSingles(plhs[0]), pdiResult,
            res.pdiSpec.total_size * res.pdiSpec.num_ensembles * sizeof(float));
    } else if (command == "destroy") {
        if (ef_handle) {
            EchoFrameDestroy(ef_handle);
            ef_handle = nullptr;
        }
        resetRFStorage();
        if (mexIsLocked()) mexUnlock();
    } else {
        mexErrMsgTxt("Unknown command.");
    }
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    // Before dispatch, so every print in this call gates on the level as it is
    // NOW rather than as it was at the last init. Only the level: the storage
    // knobs stay per-init because they configure a recording already open.
    // This is also what makes the stale-by-one class unreachable -- a print
    // before an init's own refresh can no longer see the previous init's level.
    Storage::refreshLogLevel();

    // An exception crossing into MATLAB is std::terminate, with no catchable
    // error. Storage and CUDA both throw, so translate here.
    try {
        efMexDispatch(nlhs, plhs, nrhs, prhs);
    } catch (const std::exception &e) {
        mexErrMsgTxt(e.what());
    } catch (...) {
        mexErrMsgTxt("echoframe_mex: unknown C++ exception.");
    }
}

// Cleanup function to be called when MATLAB clears the MEX file.
void mexAtExitCleanup() {
    // Unload is not a dispatch, so the refresh at the top of mexFunction never
    // runs for it: without this the line below gates on the level as of the
    // last MEX call, and a session that went quiet before `clear mex` still got
    // it. The only print site structurally outside the dispatch path.
    Storage::refreshLogLevel();
    if (Storage::logAtLeast(Storage::kLogNormal))
        mexPrintf("mexAtExit: EchoFrame resources freed.\n");
    if (ef_handle) {
        EchoFrameDestroy(ef_handle);
        ef_handle = nullptr;
    }
    resetRFStorage();
    if (mexIsLocked()) mexUnlock();
}

// Helper to convert MATLAB string to std::string.
std::string mxArrayToStdString(const mxArray *matlabStr) {
    char *cStr = mxArrayToString(matlabStr);
    std::string str(cStr);
    mxFree(cStr);
    return str;
}

template <typename bufferType_t>
bufferType_t *mxGetBuffer(const mxArray *mxBuffer) {
    bufferType_t *buffer;
    // if more buffer types are needed, specify them with an OR case
    // below
    if (std::is_same_v<bufferType_t, int16_t>) {
        buffer = static_cast<int16_t *>(mxGetInt16s(mxBuffer));
    } else
        throw std::runtime_error(
            "mxGetBuffer: buffer data type specified not "
            "implemented\n");

    return buffer;
}

// Build the MATLAB timing struct for the most recent process call.
static mxArray *buildMatlabTimings(const EchoFrame::EchoFrameTimings &timings) {
    const char *fields[] = {"rf_transfer",   "rf_formatting",  "beamforming",
                            "bf_formatting", "pdi_processing", "pdi_transfer",
                            "bf_storage",    "pdi_storage",    "total"};
    mxArray *output = mxCreateStructMatrix(1, 1, 9, fields);
    mxSetField(output, 0, "rf_transfer",
               mxCreateDoubleScalar(timings.rf_transfer));
    mxSetField(output, 0, "rf_formatting",
               mxCreateDoubleScalar(timings.rf_formatting));
    mxSetField(output, 0, "beamforming",
               mxCreateDoubleScalar(timings.beamforming));
    mxSetField(output, 0, "bf_formatting",
               mxCreateDoubleScalar(timings.bf_formatting));
    mxSetField(output, 0, "pdi_processing",
               mxCreateDoubleScalar(timings.pdi_processing));
    mxSetField(output, 0, "pdi_transfer",
               mxCreateDoubleScalar(timings.pdi_transfer));
    mxSetField(output, 0, "bf_storage",
               mxCreateDoubleScalar(timings.bf_storage));
    mxSetField(output, 0, "pdi_storage",
               mxCreateDoubleScalar(timings.pdi_storage));
    mxSetField(output, 0, "total", mxCreateDoubleScalar(timings.total));
    return output;
}

// One stream's write instrumentation as a MATLAB struct.
static mxArray *buildStreamStats(const EchoFrame::EchoFrameStreamStats &s) {
    const char *fields[] = {"saving",         "writes",
                            "buffersQueued",  "latencyMeanMs",
                            "latencyMaxMs",   "peakInFlight",
                            "queueCapacity",  "slotRingDepth",
                            "blockedTotalMs", "blockedMaxMs",
                            "verified",       "corrupted"};
    mxArray *o = mxCreateStructMatrix(1, 1, 12, fields);
    mxSetField(o, 0, "saving", mxCreateLogicalScalar(s.saving));
    mxSetField(o, 0, "writes",
               mxCreateDoubleScalar(static_cast<double>(s.writes)));
    mxSetField(o, 0, "buffersQueued",
               mxCreateDoubleScalar(static_cast<double>(s.buffersQueued)));
    mxSetField(o, 0, "latencyMeanMs", mxCreateDoubleScalar(s.latencyMeanMs));
    mxSetField(o, 0, "latencyMaxMs", mxCreateDoubleScalar(s.latencyMaxMs));
    mxSetField(o, 0, "peakInFlight", mxCreateDoubleScalar(s.peakInFlight));
    mxSetField(o, 0, "queueCapacity", mxCreateDoubleScalar(s.queueCapacity));
    mxSetField(o, 0, "slotRingDepth", mxCreateDoubleScalar(s.slotRingDepth));
    mxSetField(o, 0, "blockedTotalMs", mxCreateDoubleScalar(s.blockedTotalMs));
    mxSetField(o, 0, "blockedMaxMs", mxCreateDoubleScalar(s.blockedMaxMs));
    mxSetField(o, 0, "verified",
               mxCreateDoubleScalar(static_cast<double>(s.verified)));
    mxSetField(o, 0, "corrupted",
               mxCreateDoubleScalar(static_cast<double>(s.corrupted)));
    return o;
}

// All four streams. RF is written by this MEX rather than the core, so it is
// assembled here from the handler we own.
static mxArray *buildStorageStats(
    const EchoFrame::EchoFrameStorageStats &core) {
    const char *fields[] = {"rf", "bf", "pdi", "timetag"};
    mxArray *o = mxCreateStructMatrix(1, 1, 4, fields);
    mxSetField(o, 0, "rf",
               buildStreamStats(EchoFrame::makeStreamStats(rf_storage_handler,
                                                           rf_storage_spec)));
    mxSetField(o, 0, "bf", buildStreamStats(core.bf));
    mxSetField(o, 0, "pdi", buildStreamStats(core.pdi));
    mxSetField(o, 0, "timetag", buildStreamStats(core.timetag));
    return o;
}

// New helper function to build the MATLAB output arrays from GPU data.
static void buildMatlabOutput(int nlhs, mxArray *plhs[],
                              const EchoframeResources &res, float *pPDIResult,
                              float *pBmodeResult, float2 *pBFComplexResult) {
    // Create a 3D MATLAB array for the PDI output:
    const mwSize dims[] = {static_cast<mwSize>(res.reconSpec.nz),
                           static_cast<mwSize>(res.reconSpec.nx),
                           static_cast<mwSize>(res.pdiSpec.num_ensembles)};
    // Create a 2D MATLAB array for the B-mode output:
    const mwSize dims1[] = {static_cast<mwSize>(res.reconSpec.nz),
                            static_cast<mwSize>(res.reconSpec.nx)};

    // Allocate the MATLAB output arrays and copy data from GPU memory
    // buffers.
    plhs[0] = mxCreateNumericArray(3, dims, mxSINGLE_CLASS, mxREAL);
    plhs[1] = mxCreateNumericArray(2, dims1, mxSINGLE_CLASS, mxREAL);

    memcpy(mxGetSingles(plhs[0]), pPDIResult,
           res.pdiSpec.total_size * res.pdiSpec.num_ensembles * sizeof(float));
    memcpy(mxGetSingles(plhs[1]), pBmodeResult,
           res.reconSpec.totalSize * sizeof(float));

    // If three or more outputs are requested, allocate the complex beamformed
    // output (plhs[2]). A fourth output (timings struct) is handled by the
    // caller after this function returns.
    if (nlhs >= 3) {
        const mwSize dims2[] = {static_cast<mwSize>(res.reconSpec.nz),
                                static_cast<mwSize>(res.reconSpec.nx),
                                static_cast<mwSize>(res.receiveSpec.nRepeats)};
        plhs[2] = mxCreateNumericArray(3, dims2, mxSINGLE_CLASS, mxCOMPLEX);
        memcpy(mxGetComplexSingles(plhs[2]), pBFComplexResult,
               res.reconSpec.totalSize * res.receiveSpec.nRepeats *
                   sizeof(float2));
    }
}
