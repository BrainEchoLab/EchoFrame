/**
 * @file echoframe_ci_interface.h
 * @author BrainEcho Lab
 * @brief EchoFrame CI Interface Header
 * @details This file declares the interface for the EchoFrame CI interface
 * module.
 * @version 0.1
 * @date 2025-05-21
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once

#include "../beamformer/echoframe_resources_bundle.h"
#include "echoframe_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief EchoFrameHandle is a handle to the EchoFrame object.
 *
 */
typedef struct EchoFrameHandle EchoFrameHandle;

/**
 * @brief EchoFrameCreate creates an EchoFrame object.
 *
 * @param res Bundle of resources for the EchoFrame object.
 * @param useStorage bool if storage should be used or not.
 * @return EchoFrameHandle* Handle to the created EchoFrame object.
 */
EchoFrameHandle *EchoFrameCreate(const EchoframeResources *res,
                                 bool useStorage);

/**
 * @brief EchoFrameDestroy destroys the EchoFrame object.
 *
 * @param handle Handle to the EchoFrame object to be destroyed.
 */
void EchoFrameDestroy(EchoFrameHandle *handle);

/**
 * @brief EchoFrameProcess processes the RF data.
 *
 * @param handle Handle to the EchoFrame object.
 * @param RF RF data to be processed.
 * @param startStorage bool if storage should be started or not.
 */
void EchoFrameProcess(EchoFrameHandle *handle, const int16_t *RF,
                      const bool startStorage);

/**
 * @brief EchoFrameProcessAndGetOutputs processes the RF data and returns the
 * BF, B-mode and PDI outputs.
 *
 * @param handle Handle to the EchoFrame object.
 * @param RF RF data to be processed.
 * @param startStorage bool if storage should be started or not.
 * @return EchoFrame::EchoFrameOutputs Bundled outputs of the processing.
 */
EchoFrame::EchoFrameOutputs EchoFrameProcessAndGetOutputs(
    EchoFrameHandle *handle, const int16_t *RF, const bool startStorage);

/**
 * @brief EchoFrameReinitStorage reinitializes the storage of the EchoFrame.
 *
 * @param handle Handle to the EchoFrame object.
 * @param newRes New resources for the EchoFrame object.
 */
void EchoFrameReinitStorage(EchoFrameHandle *handle,
                            const EchoframeResources &newRes);
/**
 * @brief EchoFrameReinitExperiment reinitializes the experiment of the
 *
 * @param handle Handle to the EchoFrame object.
 * @param newRes New resources for the EchoFrame object.
 */
void EchoFrameReinitExperiment(EchoFrameHandle *handle,
                               const EchoframeResources &newRes);
/**
 * @brief EchoFrameUpdatePDIThreshold updates the PDI threshold of the EchoFrame
 * live processing mode.
 *
 * @param handle Handle to the EchoFrame object.
 * @param newThreshold New PDI threshold value.
 */
void EchoFrameUpdatePDIThreshold(EchoFrameHandle *handle,
                                 const float newThreshold);
/**
 * @brief EchoFrameUpdatePDILowerThreshold updates the PDI lower (noise)
 * threshold of the EchoFrame live processing mode.
 *
 * @param handle Handle to the EchoFrame object.
 * @param newLowerThreshold New PDI lower threshold value.
 */
void EchoFrameUpdatePDILowerThreshold(EchoFrameHandle *handle,
                                      const float newLowerThreshold);
/**
 * @brief EchoFrameCreatePDIOnly creates an EchoFrame object for PDI processing
 * mode (i.e., BF as input).
 *
 * @param pdiSpec PDI specification.
 * @param receiveSpec Receive specification.
 * @param reconSpec Recon specification.
 * @param pdiStorageSpec Storage specification for PDI.
 * @param useStorage bool if storage should be used or not.
 * @return EchoFrameHandle* Handle to the created EchoFrame object.
 */
EchoFrameHandle *EchoFrameCreatePDIOnly(
    const PDI::PDISpec &pdiSpec, const Beamform::ReceiveSpec &receiveSpec,
    const Beamform::ReconSpec &reconSpec,
    const Storage::StorageSpec &pdiStorageSpec, bool useStorage);

/**
 * @brief EchoFrameProcessPDIOnly processes the PDI data.
 *
 * @param handle Handle to the EchoFrame object.
 * @param externalBF External BF data to be processed.
 * @param startStorage bool if storage should be started or not.
 * @return float* Pointer to the processed PDI data.
 */
float *EchoFrameProcessPDIOnly(EchoFrameHandle *handle,
                               const float2 *externalBF, bool startStorage);

/**
 * @brief EchoFrameGetLastTimings returns per-stage timings (seconds) of the
 * most recent process() call.
 *
 * @param handle Handle to the EchoFrame object.
 * @return EchoFrame::EchoFrameTimings populated timing struct.
 */
EchoFrame::EchoFrameTimings EchoFrameGetLastTimings(EchoFrameHandle *handle);

/**
 * @brief EchoFrameGetStorageStats returns per-stream write instrumentation:
 * completion latency, peak writes in flight, and back-pressure.
 *
 * @param handle Handle to the EchoFrame object.
 * @return EchoFrame::EchoFrameStorageStats populated stats struct.
 */
EchoFrame::EchoFrameStorageStats EchoFrameGetStorageStats(
    EchoFrameHandle *handle);

#ifdef __cplusplus
}
#endif
