/**
 * @file mex_resources_conversions.cpp
 * @author BrainEcho Lab
 * @brief MATLAB-to-Native Resource Conversion Utilities
 * @details This file implements conversion functions that translate MATLAB
 * mxArray resource structures into native EchoFrame C++ structures. These
 * utilities are used by the EchoFrame MEX interface to initialize and update
 * core processing resources, storage specifications, and experiment parameters
 * from MATLAB inputs.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "mex_resources_conversions.h"

#include <math.h>

#include <iostream>
#include <sstream>
#include <stdexcept>

namespace MexToNative {

static void disableStorageSpec(Storage::StorageSpec &storageSpec) {
    storageSpec = Storage::StorageSpec{};
}

// Utility to check presence and type of a field
void checkField(const mxArray *structArray, const char *fieldName,
                bool (*typeCheck)(const mxArray *), const char *typeName) {
    mxArray *fieldPtr =
        mxGetField(const_cast<mxArray *>(structArray), 0, fieldName);
    if (!fieldPtr) {
        std::ostringstream oss;
        oss << "Missing field '" << fieldName << "'.";
        throw std::invalid_argument(oss.str());
    }
    if (typeCheck && !typeCheck(fieldPtr)) {
        std::ostringstream oss;
        oss << "Field '" << fieldName << "' must be " << typeName << ".";
        throw std::invalid_argument(oss.str());
    }
}

// Helper: check for complex single arrays
bool isComplexSingle(const mxArray *array) {
    return mxIsComplex(array) && mxIsSingle(array);
}

// Validate ReceiveSpec struct
void validateReceiveStruct(const mxArray *s) {
    checkField(s, "nSamples", mxIsInt32, "int32");
    checkField(s, "nSamplesIQ", mxIsInt32, "int32");
    checkField(s, "nTransmissions", mxIsInt32, "int32");
    checkField(s, "nRepeats", mxIsInt32, "int32");
    checkField(s, "nChannels", mxIsInt32, "int32");
    checkField(s, "nElements", mxIsInt32, "int32");
    checkField(s, "channel2ElementMap", mxIsInt32, "int32 array");
    checkField(s, "Fs", mxIsSingle, "single");
}

void convertMexResources(const mxArray *prhs[], EchoframeResources &res) {
    // Initialization code for Receive, Recon, and PDI structs
    convertReceiveStruct(res.receiveSpec, prhs[INIT_INPUT_RCV_POS]);
    convertReconStruct(res.reconSpec, res.receiveSpec,
                       prhs[INIT_INPUT_RECON_POS]);
    convertPDISpec(res.pdiSpec, res.receiveSpec, res.reconSpec,
                   prhs[INIT_INPUT_PDI_POS]);

    convertFourierReconSpecStructs(res.fourierReconSpec,
                                   prhs[INIT_INPUT_RECON_POS]);
    disableStorageSpec(res.storageSpec);
}

void convertMexResourcesWithStorage(const mxArray *prhs[], int nrhs,
                                    EchoframeResources &res) {
    // Initialization code for Receive, Recon, and PDI structs
    convertReceiveStruct(res.receiveSpec, prhs[INIT_INPUT_RCV_POS]);
    convertReconStruct(res.reconSpec, res.receiveSpec,
                       prhs[INIT_INPUT_RECON_POS]);
    convertPDISpec(res.pdiSpec, res.receiveSpec, res.reconSpec,
                   prhs[INIT_INPUT_PDI_POS]);

    convertFourierReconSpecStructs(res.fourierReconSpec,
                                   prhs[INIT_INPUT_RECON_POS]);
    // Storage initialization
    convertStorageStruct(res.bfStorageSpec, prhs[INIT_INPUT_BFSTORE_POS]);
    convertStorageStruct(res.pdiStorageSpec, prhs[INIT_INPUT_PDISTORE_POS]);
    convertStorageStruct(res.rfTimeTagStorageSpec,
                         prhs[INIT_INPUT_RFTIMETAGSTORE_POS]);
    if (nrhs > INIT_INPUT_RFSTORE_POS) {
        convertStorageStruct(res.storageSpec, prhs[INIT_INPUT_RFSTORE_POS]);
    } else {
        disableStorageSpec(res.storageSpec);
    }
}

void convertReinitStorage(const mxArray *prhs[], int nrhs, EchoframeResources &res) {
    // Initialization code for Receive, Recon, and PDI structs
    convertStorageStruct(res.bfStorageSpec, prhs[REINIT_INPUT_BFSTORE_POS]);
    convertStorageStruct(res.pdiStorageSpec, prhs[REINIT_INPUT_PDISTORE_POS]);
    convertStorageStruct(res.rfTimeTagStorageSpec,
                         prhs[REINIT_INPUT_RFTIMETAGSTORE_POS]);
    if (nrhs > REINIT_INPUT_RFSTORE_POS) {
        convertStorageStruct(res.storageSpec, prhs[REINIT_INPUT_RFSTORE_POS]);
    } else {
        disableStorageSpec(res.storageSpec);
    }

    // Re-initialize the Recon and PDI spec only if crop is enabled
    if (res.bfStorageSpec.crop) {
        convertReconStruct(res.reconSpec, res.receiveSpec,
                           prhs[REINIT_INPUT_RECON_POS]);
        convertFourierReconSpecStructs(res.fourierReconSpec,
                                       prhs[REINIT_INPUT_RECON_POS]);
    }
    if (res.pdiStorageSpec.crop) {
        convertReconStruct(res.reconSpec, res.receiveSpec,
                           prhs[REINIT_INPUT_RECON_POS]);
        convertPDISpec(res.pdiSpec, res.receiveSpec, res.reconSpec,
                       prhs[REINIT_INPUT_PDISPEC_POS]);
    }
}

void convertReinitExperiment(const mxArray *prhs[], int nrhs, EchoframeResources &res) {
    // Initialization code for Receive, Recon, and PDI structs
    convertStorageStruct(res.bfStorageSpec, prhs[REINIT_INPUT_BFSTORE_POS]);
    convertStorageStruct(res.pdiStorageSpec, prhs[REINIT_INPUT_PDISTORE_POS]);
    convertStorageStruct(res.rfTimeTagStorageSpec,
                         prhs[REINIT_INPUT_RFTIMETAGSTORE_POS]);
    if (nrhs > REINIT_INPUT_RFSTORE_POS) {
        convertStorageStruct(res.storageSpec, prhs[REINIT_INPUT_RFSTORE_POS]);
    } else {
        disableStorageSpec(res.storageSpec);
    }
}

void convertReceiveStruct(Beamform::ReceiveSpec &receiveSpec,
                          const mxArray *receiveStruct) {
    validateReceiveStruct(receiveStruct);

    receiveSpec.nSamples =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nSamples"))[0];
    receiveSpec.nSamplesIQ =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nSamplesIQ"))[0];
    receiveSpec.nTX =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nTransmissions"))[0];
    receiveSpec.nRepeats =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nRepeats"))[0];
    receiveSpec.nChannels =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nChannels"))[0];
    receiveSpec.nActiveChannels =
        mxGetInt32s(mxGetField(receiveStruct, 0, "nElements"))[0];
    receiveSpec.activeChannelMap =
        mxGetInt32s(mxGetField(receiveStruct, 0, "channel2ElementMap"));
    receiveSpec.Fs = mxGetSingles(mxGetField(receiveStruct, 0, "Fs"))[0];

    receiveSpec.rfSize = static_cast<int64_t>(receiveSpec.nSamples) *
                         static_cast<int64_t>(receiveSpec.nChannels) *
                         static_cast<int64_t>(receiveSpec.nTX) *
                         static_cast<int64_t>(receiveSpec.nRepeats);
    receiveSpec.mNRows =
        receiveSpec.nSamples * receiveSpec.nTX * receiveSpec.nRepeats;
}

// Validate ReconSpec struct
void validateReconStruct(const mxArray *s) {
    checkField(s, "croppingROI", mxIsInt32, "int32 vector of length 4");
    checkField(s, "nz", mxIsInt32, "int32");
    checkField(s, "nx", mxIsInt32, "int32");
    checkField(s, "zAxis", mxIsDouble, "double vector of length >=2");
    checkField(s, "xAxis", mxIsDouble, "double vector of length >=2");
    checkField(s, "filterFrequencies", mxIsLogical, "logical");
    checkField(s, "getBF", mxIsLogical, "logical");
    checkField(s, "getPDI", mxIsLogical, "logical");
    checkField(s, "cropBF", mxIsLogical, "logical");
}

void convertReconStruct(Beamform::ReconSpec &reconSpec,
                        const Beamform::ReceiveSpec &receiveSpec,
                        const mxArray *reconStruct) {
    validateReconStruct(reconStruct);

    // Cropping dimensions init
    // Get the croppingROI field from the reconStruct
    int32_t *croppingROI =
        mxGetInt32s(mxGetField(reconStruct, 0, "croppingROI"));

    // Assign values from the croppingROI vector
    reconSpec.nSamplesCropTop = croppingROI[0];     // Top crop
    reconSpec.nSamplesCropBot = croppingROI[1];     // Bottom crop
    reconSpec.nChannelsCropLeft = croppingROI[2];   // Left crop
    reconSpec.nChannelsCropRight = croppingROI[3];  // Right crop

    reconSpec.nSamplesReduced =
        reconSpec.nSamplesCropBot - reconSpec.nSamplesCropTop + 1;
    reconSpec.nChannelsReduced =
        reconSpec.nChannelsCropRight - reconSpec.nChannelsCropLeft + 1;

    reconSpec.nz = mxGetInt32s(mxGetField(reconStruct, 0, "nz"))[0];
    reconSpec.nx = mxGetInt32s(mxGetField(reconStruct, 0, "nx"))[0];
    reconSpec.totalSize = reconSpec.nz * reconSpec.nx;

    reconSpec.zSpacing = mxGetDoubles(mxGetField(reconStruct, 0, "zAxis"))[1] -
                         mxGetDoubles(mxGetField(reconStruct, 0, "zAxis"))[0];
    reconSpec.xSpacing = mxGetDoubles(mxGetField(reconStruct, 0, "xAxis"))[1] -
                         mxGetDoubles(mxGetField(reconStruct, 0, "xAxis"))[0];

    reconSpec.totalSizeCropped =
        reconSpec.nSamplesReduced * reconSpec.nChannelsReduced;

    reconSpec.filterFrequencies =
        mxGetLogicals(mxGetField(reconStruct, 0, "filterFrequencies"))[0];
    reconSpec.getBF = mxGetLogicals(mxGetField(reconStruct, 0, "getBF"))[0];
    reconSpec.getPDI = mxGetLogicals(mxGetField(reconStruct, 0, "getPDI"))[0];
    reconSpec.cropBF = mxGetLogicals(mxGetField(reconStruct, 0, "cropBF"))[0];

    reconSpec.ensembleSize = receiveSpec.nRepeats;
}

// Validate PDISpec struct
void validatePDIStruct(const mxArray *s) {
    checkField(s, "ensembleSize", mxIsInt32, "int32");
    checkField(s, "threshold", mxIsSingle, "single");
    checkField(s, "shiftSize", mxIsInt32, "int32");
    checkField(s, "cropPDI", mxIsLogical, "logical");
    checkField(s, "svdMethod", mxIsChar, "char");
}

void convertPDISpec(PDI::PDISpec &pdiSpec,
                    const Beamform::ReceiveSpec &receiveSpec,
                    const Beamform::ReconSpec &reconSpec,
                    const mxArray *pdiStruct) {
    validatePDIStruct(pdiStruct);
    pdiSpec.ensemble_size =
        mxGetInt32s(mxGetField(pdiStruct, 0, "ensembleSize"))[0];
    pdiSpec.threshold = mxGetSingles(mxGetField(pdiStruct, 0, "threshold"))[0];
    // Optional lower (noise) threshold: default 0 when the field is absent, so
    // specs / ScanParameters.mat written before this field still init.
    const mxArray *lowerField = mxGetField(pdiStruct, 0, "lowerThreshold");
    pdiSpec.lowerThreshold =
        (lowerField && mxIsSingle(lowerField)) ? mxGetSingles(lowerField)[0]
                                               : 0.0f;
    pdiSpec.shiftSize = mxGetInt32s(mxGetField(pdiStruct, 0, "shiftSize"))[0];
    pdiSpec.cropPDI = mxGetLogicals(mxGetField(pdiStruct, 0, "cropPDI"))[0];

    pdiSpec.num_ensembles = std::max<int32_t>(
        0,
        (receiveSpec.nRepeats - pdiSpec.ensemble_size) / pdiSpec.shiftSize + 1);
    pdiSpec.total_size = reconSpec.totalSize;

    std::string SVDMethodStr(
        mxArrayToString(mxGetField(pdiStruct, 0, "svdMethod")));

    if (SVDMethodStr == "Full") {
        pdiSpec.method = PDI::Full;
    } else {
        pdiSpec.method = PDI::CovarianceEig;
    }
}

// Validate FourierReconSpec-specific fields
void validateFourierReconStruct(const mxArray *s) {
    checkField(s, "delayIndices", mxIsInt32, "int32 array");
    checkField(s, "interpolationWeights", isComplexSingle,
               "complex single array");
    checkField(s, "frequencyAxis", mxIsSingle, "single array");
    checkField(s, "planewaveDelays", mxIsSingle, "single array");
    checkField(s, "tgcVector", mxIsSingle, "single array");
}

void convertFourierReconSpecStructs(
    Beamform::FourierReconSpec &fourierReconSpec, const mxArray *reconStruct) {
    validateFourierReconStruct(reconStruct);
    fourierReconSpec.delayIndices =
        mxGetInt32s(mxGetField(reconStruct, 0, "delayIndices"));
    fourierReconSpec.interpolationWeights =
        reinterpret_cast<float2 *>(mxGetComplexSingles(
            mxGetField(reconStruct, 0, "interpolationWeights")));
    fourierReconSpec.frequencyAxis =
        mxGetSingles(mxGetField(reconStruct, 0, "frequencyAxis"));
    fourierReconSpec.planewaveDelays =
        mxGetSingles(mxGetField(reconStruct, 0, "planewaveDelays"));
    fourierReconSpec.tgcVector =
        mxGetSingles(mxGetField(reconStruct, 0, "tgcVector"));
}

// Validate StorageSpec struct
void validateStorageStruct(const mxArray *s) {
    checkField(s, "save", mxIsLogical, "logical");
    checkField(s, "crop", mxIsLogical, "logical");
    checkField(s, "preallocateFullFile", mxIsLogical, "logical");
    checkField(s, "filepath", mxIsChar, "char");
    checkField(s, "dataType", mxIsChar, "char");
    checkField(s, "maxNumberBuffers", mxIsInt32, "int32");
    checkField(s, "numberOfBuffers", mxIsInt32, "int32");
    checkField(s, "bufferSize", mxIsUint64, "uint64");
}

void convertStorageStruct(Storage::StorageSpec &storageSpec,
                          const mxArray *storageStruct) {
    validateStorageStruct(storageStruct);
    storageSpec.save = mxGetLogicals(mxGetField(storageStruct, 0, "save"))[0];
    storageSpec.crop = mxGetLogicals(mxGetField(storageStruct, 0, "crop"))[0];
    storageSpec.preallocateFullFile =
        mxGetLogicals(mxGetField(storageStruct, 0, "preallocateFullFile"))[0];
    storageSpec.filepath =
        mxArrayToString(mxGetField(storageStruct, 0, "filepath"));
    storageSpec.dataType =
        mxArrayToString(mxGetField(storageStruct, 0, "dataType"));
    storageSpec.nWritesPerBuffer = 1;
    storageSpec.maxNBuffers =
        mxGetInt32s(mxGetField(storageStruct, 0, "maxNumberBuffers"))[0];
    storageSpec.nBuffers =
        mxGetInt32s(mxGetField(storageStruct, 0, "numberOfBuffers"))[0];
    storageSpec.bufferSize =
        mxGetUint64s(mxGetField(storageStruct, 0, "bufferSize"))[0];
}

// Function to print all parameters in Beamform::ReceiveSpec.
void printReceiveSpec(const Beamform::ReceiveSpec &receiveSpec) {
    std::cout << "----- ReceiveSpec -----" << std::endl;
    std::cout << "nSamples: " << receiveSpec.nSamples << std::endl;
    std::cout << "nSamplesIQ: " << receiveSpec.nSamplesIQ << std::endl;
    std::cout << "nTX: " << receiveSpec.nTX << std::endl;
    std::cout << "nRepeats: " << receiveSpec.nRepeats << std::endl;
    std::cout << "nChannels: " << receiveSpec.nChannels << std::endl;
    std::cout << "nActiveChannels: " << receiveSpec.nActiveChannels
              << std::endl;

    std::cout << "activeChannelMap: ";
    for (int i = 0; i < receiveSpec.nActiveChannels; i++) {
        std::cout << receiveSpec.activeChannelMap[i] << " ";
    }
    std::cout << std::endl;

    std::cout << "Fs: " << receiveSpec.Fs << std::endl;
    std::cout << "rfSize: " << receiveSpec.rfSize << std::endl;
    std::cout << "mNRows: " << receiveSpec.mNRows << std::endl;
    std::cout << std::endl;
}

// Function to print all parameters in Beamform::ReconSpec.
void printReconSpec(const Beamform::ReconSpec &reconSpec) {
    std::cout << "----- ReconSpec -----" << std::endl;
    std::cout << "nSamplesCropTop: " << reconSpec.nSamplesCropTop << std::endl;
    std::cout << "nSamplesCropBot: " << reconSpec.nSamplesCropBot << std::endl;
    std::cout << "nChannelsCropLeft: " << reconSpec.nChannelsCropLeft
              << std::endl;
    std::cout << "nChannelsCropRight: " << reconSpec.nChannelsCropRight
              << std::endl;
    std::cout << "nSamplesReduced: " << reconSpec.nSamplesReduced << std::endl;
    std::cout << "nChannelsReduced: " << reconSpec.nChannelsReduced
              << std::endl;
    std::cout << "totalSize: " << reconSpec.totalSize << std::endl;

    std::cout << "nz: " << reconSpec.nz << std::endl;
    std::cout << "nx: " << reconSpec.nx << std::endl;

    std::cout << "totalSizeCropped: " << reconSpec.totalSizeCropped
              << std::endl;
    std::cout << "filterFrequencies: "
              << (reconSpec.filterFrequencies ? "true" : "false") << std::endl;
    std::cout << "getBF: " << (reconSpec.getBF ? "true" : "false") << std::endl;
    std::cout << "getPDI: " << (reconSpec.getPDI ? "true" : "false")
              << std::endl;
    std::cout << "cropBF: " << (reconSpec.cropBF ? "true" : "false")
              << std::endl;
    std::cout << "ensembleSize: " << reconSpec.ensembleSize << std::endl;
    std::cout << std::endl;
}

// Function to print all parameters in PDI::PDISpec.
void printPDISpec(const PDI::PDISpec &pdiSpec) {
    std::cout << "----- PDISpec -----" << std::endl;
    std::cout << "ensemble_size: " << pdiSpec.ensemble_size << std::endl;
    std::cout << "threshold: " << pdiSpec.threshold << std::endl;
    std::cout << "lowerThreshold: " << pdiSpec.lowerThreshold << std::endl;
    std::cout << "shiftSize: " << pdiSpec.shiftSize << std::endl;
    std::cout << "cropPDI: " << (pdiSpec.cropPDI ? "true" : "false")
              << std::endl;
    std::cout << "num_ensembles: " << pdiSpec.num_ensembles << std::endl;
    std::cout << "total_size: " << pdiSpec.total_size << std::endl;

    std::cout << "method: ";
    switch (pdiSpec.method) {
        case PDI::Full:
            std::cout << "Full";
            break;
        case PDI::CovarianceEig:
            std::cout << "CovarianceEig";
            break;
        default:
            std::cout << "Unknown";
            break;
    }
    std::cout << std::endl << std::endl;
}

}  // namespace MexToNative
