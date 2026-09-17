//
// Created by petros on 30/03/2022.
//

#ifndef CUBE_STORAGE_MEX_STORAGE_H
#define CUBE_STORAGE_MEX_STORAGE_H

#include <mex.h>
#include <string>

#include "../storage/Handler.h"


template <typename bufferType_t>
void doStorage(int nInputs, const mxArray *inputs[], std::string &command);

void checkNrArgs(int nlhs, int nrhs);

void deduceBufferType(const mxArray *storageStruct, std::string &rfType);

void checkInitArgs(int nInputs, const mxArray *inputs[]);

void checkStorageStruct(const mxArray *storageStruct);

void initStorageStruct(Storage::StorageSpec &storageSpec, const mxArray *storageStruct);

void checkReInitArgs(int nInputs);

void checkStoreArgs(int nInputs, const mxArray *inputs[], uint64_t bufferSizeExpected);

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]);

#endif //CUBE_STORAGE_MEX_STORAGE_H
