//
// Created by petros on 30/03/2022.
//

#include "storage.h"

#include <stdexcept>

#include "../storage/Handler.t.hpp"
#include "../utils/mathelper.h"

#define INPUT_CMD_POS 0
#define INPUT_STORE_POS 1

void checkNrArgs(int nlhs, int nrhs) {
    if (nlhs != 0) {
        throw std::runtime_error("Error: no outputs are expected.\n");
    }

    if (nrhs < 2) {
        throw std::runtime_error(
            "Error: at least 2 input arguments are expected\n");
    }
}

void deduceBufferType(const mxArray *storageStruct, std::string &rfType) {
    // check receive struct
    checkStruct(storageStruct, "StorageSpec");

    // RF data type
    checkFieldChar(storageStruct, "dataType");
    rfType = mxArrayToString(mxGetField(storageStruct, 0, "dataType"));
}

void checkInitArgs(int nInputs, const mxArray *inputs[]) {
    // check number of inputs
    int nInputsExpected = 2;
    if (nInputsExpected != nInputs) {
        throw std::runtime_error(std::to_string(nInputsExpected) +
                                 " inputs are expected.\n");
    }

    checkStruct(inputs[INPUT_STORE_POS], "StorageSpec");
    checkStorageStruct(inputs[INPUT_STORE_POS]);
}

void checkStorageStruct(const mxArray *storageStruct) {
    checkFieldLogical(storageStruct, "save");
    checkFieldLogical(storageStruct, "crop");
    checkFieldLogical(storageStruct, "preallocateFullFile");
    checkFieldInt32(storageStruct, "maxNumberBuffers");
    checkFieldInt32(storageStruct, "numberOfBuffers");
    checkFieldUint64(storageStruct, "bufferSize");
    checkFieldChar(storageStruct, "dataType");
    checkFieldChar(storageStruct, "filepath");
}

void initStorageStruct(Storage::StorageSpec &storageSpec,
                       const mxArray *storageStruct) {
    storageSpec.save = mxGetLogicals(mxGetField(storageStruct, 0, "save"))[0];
    storageSpec.crop = mxGetLogicals(mxGetField(storageStruct, 0, "crop"))[0];
    storageSpec.preallocateFullFile =
        mxGetLogicals(mxGetField(storageStruct, 0, "preallocateFullFile"))[0];
    storageSpec.filepath =
        mxArrayToString(mxGetField(storageStruct, 0, "filepath"));
    storageSpec.dataType =
        mxArrayToString(mxGetField(storageStruct, 0, "dataType"));
    storageSpec.nWritesPerBuffer = WRITES_PER_BUFFER;
    storageSpec.maxNBuffers =
        mxGetInt32s(mxGetField(storageStruct, 0, "maxNumberBuffers"))[0];
    storageSpec.nBuffers =
        mxGetInt32s(mxGetField(storageStruct, 0, "numberOfBuffers"))[0];
    storageSpec.bufferSize =
        mxGetUint64s(mxGetField(storageStruct, 0, "bufferSize"))[0];
}

void checkReInitArgs(int nInputs) {
    // check number of inputs
    int nInputsExpected = 2;
    if (nInputsExpected != nInputs) {
        throw std::runtime_error(std::to_string(nInputsExpected) +
                                 " inputs are expected.\n");
    }
}

void checkStoreArgs(int nInputs, const mxArray *inputs[],
                    uint64_t bufferSizeExpected) {
    // check number of inputs
    int nInputsExpected = 2;
    if (nInputsExpected != nInputs) {
        throw std::runtime_error(std::to_string(nInputsExpected) +
                                 " inputs are expected.\n");
    }

    int inputNr = 1;
    if (!mxIsInt16(inputs[inputNr]) || mxIsComplex(inputs[inputNr]))
        throw std::invalid_argument(
            " (" + std::to_string(inputNr + 1) +
            ") is of invalid data type: must be int16_t*.\n");

    // get the size of the buffer
    auto nRows = mxGetM(inputs[inputNr]);
    auto nCols = mxGetN(inputs[inputNr]);

    // compare the received buffer size with the expected data size
    auto bufferSize = nRows * nCols;
    if (bufferSizeExpected != bufferSize) {
        throw std::invalid_argument(
            std::string("Incorrect buffer size.\nExpected: ") +
            std::to_string(bufferSizeExpected) +
            "\nReceived: " + std::to_string(bufferSize) + "\n");
    }
}

template <typename bufferType_t>
void doStorage(int nInputs, const mxArray *inputs[], std::string &command) {
    static Storage::Handler<bufferType_t> storageHandler;

    static Storage::StorageSpec storageSpec{};

    if (command == "init") {
        checkInitArgs(nInputs, inputs);
        initStorageStruct(storageSpec, inputs[INPUT_STORE_POS]);
        storageHandler = std::move(Storage::Handler<bufferType_t>(
            storageSpec.filepath, storageSpec.dataType, storageSpec.bufferSize,
            storageSpec.nWritesPerBuffer, storageSpec.maxNBuffers,
            storageSpec.nBuffers, storageSpec.crop,
            storageSpec.preallocateFullFile));
    } else if (command == "re-init") {
        checkInitArgs(nInputs, inputs);
        initStorageStruct(storageSpec, inputs[INPUT_STORE_POS]);
        storageHandler = std::move(Storage::Handler<bufferType_t>(
            storageSpec.filepath, storageSpec.dataType, storageSpec.bufferSize,
            storageSpec.nWritesPerBuffer, storageSpec.maxNBuffers,
            storageSpec.nBuffers, storageSpec.crop,
            storageSpec.preallocateFullFile));
        // storageHandler.switchFile();
    } else if (command == "store") {
        checkStoreArgs(nInputs, inputs, storageSpec.bufferSize);
        auto buffer = static_cast<int16_t *>(mxGetInt16s(inputs[1]));
        storageHandler.storeBuffer(buffer);
    } else
        throw std::runtime_error("Unknown command (1) specified\n");
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    // get command sent from MATLAB
    if (!mxIsChar(prhs[INPUT_CMD_POS]) || mxIsComplex(prhs[INPUT_CMD_POS])) {
        throw std::invalid_argument(
            "Command (1) is of invalid data type: must be char*.\n");
    }
    std::string command = mxArrayToString(prhs[INPUT_CMD_POS]);

    // get buffer data type
    static std::string rfType;
    if (command == "init") {
        deduceBufferType(prhs[INPUT_STORE_POS], rfType);
    }

    // Implement more rf types below if that is desirable in the future
    if (rfType == "int16") {
        // Implement more buffer types below if that is desirable in the future
        // (need to add option in MATLAB too for that)
        doStorage<int16_t>(nrhs, prhs, command);
    } else
        throw std::runtime_error("RF data type unknown or not specified\n");
}
