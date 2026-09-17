/**
 * @file echoframe_resources_bundle.h
 * @author BrainEcho Lab
 * @brief  Bundle of resources for the EchoFrame object.
 * @details This file defines the EchoframeResources structure, which contains
 * the specifications for various components of the EchoFrame system, including
 * receive, recon, PDI, Fourier reconstruction, and storage specifications.
 * @details The EchoframeResources structure is used to initialize the EchoFrame
 * object and is passed to the EchoFrameCore class for processing. It allows for
 * flexible configuration of the EchoFrame system, enabling different imaging
 * modalities and storage options.
 * @version 0.1
 * @date 2025-05-26
 *
 * @copyright Copyright (c) 2025
 *
 */
#pragma once
#include <string>
#include <vector>

#include "../../libs/Storage/src/storage/storage_spec.h"
#include "../pdi/pdi_spec.h"
#include "./fourier_imaging/fourier_recon_spec.h"
#include "resources.h"

struct EchoframeResources {
    Beamform::ReceiveSpec
        receiveSpec;  ///< RF data acquisition and transducer properties.
    Beamform::ReconSpec
        reconSpec;         ///< Reconstruction parameters and output options.
    PDI::PDISpec pdiSpec;  ///< Power Doppler Imaging specification.
    Beamform::FourierReconSpec
        fourierReconSpec;  ///< Fourier reconstruction specification.
    Storage::StorageSpec storageSpec;  ///< General storage specification.
    Storage::StorageSpec
        pdiStorageSpec;  ///< Storage specification for PDI data.
    Storage::StorageSpec
        rfTimeTagStorageSpec;  ///< Storage specification for RF time tags.
    Storage::StorageSpec
        bfStorageSpec;  ///< Storage specification for beamformed data.
};
