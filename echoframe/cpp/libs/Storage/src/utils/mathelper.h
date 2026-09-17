//
// Created by petros on 1/17/22.
//

#ifndef CUBE_C_MATHELPER_H
#define CUBE_C_MATHELPER_H

#include <string>
#include "mex.h"

void checkStruct(const mxArray *structPtr, std::string stageMsg);

void checkFieldInt32(const mxArray *aPtr, const char *field);

void checkFieldUint32(const mxArray *aPtr, const char *field);

void checkFieldUint64(const mxArray *aPtr, const char *field);

void checkFieldInt16(const mxArray *aPtr, const char *field);

void checkFieldSingle(const mxArray *aPtr, const char *field);

void checkFieldComplexSingle(const mxArray *aPtr, const char *field);

void checkFieldLogical(const mxArray *aPtr, const char *field);

void checkFieldChar(const mxArray *aPtr, const char *field);

#endif //CUBE_C_MATHELPER_H
