/**
 * @file echoframe_ci_interface.cpp
 * @author BrainEcho Lab
 * @brief EchoFrame CI Interface Implementation
 * @details This file defines the interface for the EchoFrame CI, used
 * primarily for the EchoFrame MEX and Python bindings.
 * @details The EchoFrame CI interface provides a C-compatible API for use with
 * the Matlab MEX code and Python binding. It allows for the creation,
 * destruction, and processing of EchoFrame objects, as well as the
 * reinitialization of storage and live experiments.
 * @version 0.1
 * @date 2025-05-21
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "echoframe_ci_interface.h"

using namespace EchoFrame;

struct EchoFrameHandle {
    EchoFrameCore core;
};

EchoFrameHandle *EchoFrameCreate(const EchoframeResources *res,
                                 bool useStorage) {
    return new EchoFrameHandle{EchoFrameCore(*res, useStorage)};
}

void EchoFrameDestroy(EchoFrameHandle *handle) { delete handle; }

void EchoFrameProcess(EchoFrameHandle *handle, const int16_t *RF,
                      const bool startStorage) {
    handle->core.process(RF, startStorage);
}

EchoFrame::EchoFrameOutputs EchoFrameProcessAndGetOutputs(
    EchoFrameHandle *handle, const int16_t *RF, const bool startStorage) {
    return handle->core.processAndGetOutputs(RF, startStorage);
}

void EchoFrameReinitStorage(EchoFrameHandle *handle,
                            const EchoframeResources &newRes) {
    handle->core.reinitStorage(newRes);
}

void EchoFrameReinitExperiment(EchoFrameHandle *handle,
                               const EchoframeResources &newRes) {
    handle->core.reinitExperiment(newRes);
}

void EchoFrameUpdatePDIThreshold(EchoFrameHandle *handle,
                                 const float newThreshold) {
    handle->core.updatePDIThreshold(newThreshold);
}

void EchoFrameUpdatePDILowerThreshold(EchoFrameHandle *handle,
                                      const float newLowerThreshold) {
    handle->core.updatePDILowerThreshold(newLowerThreshold);
}

EchoFrameHandle *EchoFrameCreatePDIOnly(
    const PDI::PDISpec &pdiSpec, const Beamform::ReceiveSpec &receiveSpec,
    const Beamform::ReconSpec &reconSpec,
    const Storage::StorageSpec &pdiStorageSpec, bool useStorage) {
    return new EchoFrameHandle{EchoFrameCore(pdiSpec, receiveSpec, reconSpec,
                                             pdiStorageSpec, useStorage)};
}

float *EchoFrameProcessPDIOnly(EchoFrameHandle *handle,
                               const float2 *externalBF, bool startStorage) {
    return handle->core.processPDIOnly(externalBF, startStorage);
}

EchoFrame::EchoFrameTimings EchoFrameGetLastTimings(EchoFrameHandle *handle) {
    return handle->core.getLastTimings();
}

EchoFrame::EchoFrameStorageStats EchoFrameGetStorageStats(
    EchoFrameHandle *handle) {
    return handle->core.getStorageStats();
}
