//
// Created by petros on 1/17/22.
//

// header
#include "mathelper.h"

// system libraries
#include "stdexcept"

void checkStruct(const mxArray *structPtr, std::string stageMsg)
{
    if (structPtr == NULL) {
        throw std::runtime_error(stageMsg + ": struct mxArray not found.\n");
    }
    // check correctness of arguments
    if (mxGetClassID(structPtr) != mxSTRUCT_CLASS) {
        throw std::invalid_argument(stageMsg + ": provided mxArray is not a structure.\n");
    }
}

void checkFieldInt32(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsInt32(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldUint32(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsUint32(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldUint64(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsUint64(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldInt16(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsInt16(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldSingle(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsSingle(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldComplexSingle(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsSingle(mxGetField(aPtr, 0, field)) || !mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldLogical(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsLogical(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}

void checkFieldChar(const mxArray *aPtr, const char *field)
{
    if (mxGetFieldNumber(aPtr, field) == -1)
        throw std::invalid_argument(std::string(field) + " field not found.\n");
    if (!mxIsChar(mxGetField(aPtr, 0, field)) || mxIsComplex(mxGetField(aPtr, 0, field)))
        throw std::invalid_argument(std::string(field) + " is of invalid data type.\n");
}