/**
 * @file load_specs_from_mat.cpp
 * @author BrainEcho Lab
 * @brief MATLAB .mat File Resource Loader
 * @details This file implements functions to load EchoFrame scan and processing
 * specifications from a MATLAB .mat file using the matio library. It provides
 * utilities for extracting scalar, vector, and string fields, converting MATLAB
 * arrays to C++ row-major order, and populating EchoFrame resource structures
 * for batch or offline processing.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "load_specs_from_mat.hpp"

#include <matio.h>

#include <algorithm>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Utility to check presence of a struct field
static void validateField(matvar_t *s, const char *fld) {
    matvar_t *f = Mat_VarGetStructFieldByName(s, fld, 0);
    if (!f || !f->data) {
        std::ostringstream oss;
        oss << "Missing or empty field '" << fld << "'.";
        throw std::runtime_error(oss.str());
    }
}

// Validate ReceiveSpec struct fields
static void validateReceiveMatStruct(matvar_t *s) {
    validateField(s, "nSamples");
    validateField(s, "nSamplesIQ");
    validateField(s, "nTransmissions");
    validateField(s, "nRepeats");
    validateField(s, "nChannels");
    validateField(s, "nElements");
    validateField(s, "channel2ElementMap");
    validateField(s, "Fs");
}

// Validate ReconSpec struct fields
static void validateReconMatStruct(matvar_t *s) {
    validateField(s, "croppingROI");
    validateField(s, "nz");
    validateField(s, "nx");
    validateField(s, "zAxis");
    validateField(s, "xAxis");
    validateField(s, "filterFrequencies");
    validateField(s, "getBF");
    validateField(s, "getPDI");
    validateField(s, "cropBF");
}

// Validate PDISpec struct fields
static void validatePDIMatStruct(matvar_t *s) {
    validateField(s, "ensembleSize");
    validateField(s, "threshold");
    validateField(s, "shiftSize");
    validateField(s, "cropPDI");
    validateField(s, "svdMethod");
}

// Validate FourierReconSpec struct fields
static void validateFourierMatStruct(matvar_t *s) {
    validateField(s, "delayIndices");
    validateField(s, "interpolationWeights");
    validateField(s, "frequencyAxis");
    validateField(s, "planewaveDelays");
    validateField(s, "tgcVector");
}

template <typename T>
static T scalar(matvar_t *s, const char *fld) {
    matvar_t *f = Mat_VarGetStructFieldByName(s, fld, 0);
    if (!f || !f->data)
        throw std::runtime_error("Missing field " + std::string(fld));

    switch (f->data_type) {
        case MAT_T_INT8:
            return static_cast<T>(*static_cast<int8_t *>(f->data));
        case MAT_T_UINT8:
            return static_cast<T>(*static_cast<uint8_t *>(f->data));
        case MAT_T_INT16:
            return static_cast<T>(*static_cast<int16_t *>(f->data));
        case MAT_T_UINT16:
            return static_cast<T>(*static_cast<uint16_t *>(f->data));
        case MAT_T_INT32:
            return static_cast<T>(*static_cast<int32_t *>(f->data));
        case MAT_T_UINT32:
            return static_cast<T>(*static_cast<uint32_t *>(f->data));
        case MAT_T_INT64:
            return static_cast<T>(*static_cast<int64_t *>(f->data));
        case MAT_T_UINT64:
            return static_cast<T>(*static_cast<uint64_t *>(f->data));
        case MAT_T_SINGLE:
            return static_cast<T>(*static_cast<float *>(f->data));
        case MAT_T_DOUBLE:
            return static_cast<T>(*static_cast<double *>(f->data));
        default:
            throw std::runtime_error("Field " + std::string(fld) +
                                     " has unsupported matio data_type");
    }
}

template <typename T>
static std::vector<T> vec(matvar_t *s, const char *fld) {
    matvar_t *f = Mat_VarGetStructFieldByName(s, fld, 0);
    if (!f || !f->data)
        throw std::runtime_error("Missing field " + std::string(fld));
    size_t n = f->nbytes / sizeof(T);
    const T *p = static_cast<const T *>(f->data);
    return {p, p + n};
}

static std::string str(matvar_t *s, const char *fld) {
    matvar_t *f = Mat_VarGetStructFieldByName(s, fld, 0);
    if (!f || !f->data)
        throw std::runtime_error("Missing field " + std::string(fld));

    std::string out;

    if (f->data_type == MAT_T_UINT16) {
        /* MATLAB stores char arrays as UTF-16 code units */
        const auto *u = static_cast<const uint16_t *>(f->data);
        size_t n = f->nbytes / sizeof(uint16_t);
        for (size_t i = 0; i < n && u[i] != 0; ++i)
            out.push_back(static_cast<char>(u[i] & 0x00FF));  // assume ASCII
    } else if (f->data_type == MAT_T_UINT8 || f->data_type == MAT_T_INT8) {
        const char *p = static_cast<const char *>(f->data);
        size_t n = f->nbytes;
        if (n && p[n - 1] == '\0') --n;  // drop terminator
        out.assign(p, n);
    } else
        throw std::runtime_error("Field " + std::string(fld) +
                                 " has unsupported string type");

    /* trim leading/trailing ASCII whitespace */
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    out.erase(out.begin(), std::find_if(out.begin(), out.end(), notSpace));
    out.erase(std::find_if(out.rbegin(), out.rend(), notSpace).base(),
              out.end());
    return out;
}

/* ---------------------------------------------------------------
   Convert MATLAB column-major buffer  →  row-major (C-order) index
   idxR = Σ  i_k * StrR[k]       with   StrR[k] = Π_{j>k} dims[j]
   ---------------------------------------------------------------*/
static size_t col2row(size_t idxC, const size_t *dims, size_t rank) {
    size_t idxR = 0, strideR = 1;

    for (size_t k = rank; k-- > 0;) {
        size_t i_k = idxC % dims[k];
        idxC /= dims[k];
        idxR += i_k * strideR;
        strideR *= dims[k];
    }
    return idxR;
}

template <typename T>
static std::vector<T> vecRowMajor(matvar_t *v) {
    if (!v || v->isComplex)
        throw std::runtime_error("vecRowMajor expects *real* array");

    const T *src = static_cast<const T *>(v->data);
    size_t n = v->nbytes / sizeof(T);

    std::vector<T> dst(n);
    for (size_t i = 0; i < n; ++i) dst[col2row(i, v->dims, v->rank)] = src[i];
    return dst;
}

/* --------------------------------------------------------------------
   Flatten a *real* MATLAB array (column-major) into row-major (C order)
   Works for rank 1…N, any numeric element type.
   ------------------------------------------------------------------ */
static std::vector<float2> vecCplxRowMajor(matvar_t *v) {
    if (!v || !v->isComplex || v->class_type != MAT_C_SINGLE)
        throw std::runtime_error("expected complex-single");

    auto *split = static_cast<mat_complex_split_t *>(v->data);
    const float *re = static_cast<const float *>(split->Re);
    const float *im = static_cast<const float *>(split->Im);
    size_t n = v->nbytes / sizeof(float);  // real-float count

    std::vector<float2> dst(n);
    for (size_t i = 0; i < n; ++i) {
        size_t j = col2row(i, v->dims, v->rank);
        dst[j].x = re[i];
        dst[j].y = im[i];
    }
    return dst;
}

void loadSpecsFromMat(const std::string &matFile, EchoframeResources &res) {
    mat_t *fp = Mat_Open(matFile.c_str(), MAT_ACC_RDONLY);
    if (!fp) throw std::runtime_error("Cannot open " + matFile);

    auto Rm = std::unique_ptr<matvar_t, decltype(&Mat_VarFree)>(
        Mat_VarRead(fp, "ReceiveSpec"), Mat_VarFree);
    auto Pm = std::unique_ptr<matvar_t, decltype(&Mat_VarFree)>(
        Mat_VarRead(fp, "ReconSpec"), Mat_VarFree);
    auto Dm = std::unique_ptr<matvar_t, decltype(&Mat_VarFree)>(
        Mat_VarRead(fp, "PDISpec"), Mat_VarFree);
    if (!Rm || !Pm || !Dm || Rm->class_type != MAT_C_STRUCT ||
        Pm->class_type != MAT_C_STRUCT || Dm->class_type != MAT_C_STRUCT)
        throw std::runtime_error("Missing or invalid structs in mat file");

    // Validate each struct
    validateReceiveMatStruct(Rm.get());
    validateReconMatStruct(Pm.get());
    validatePDIMatStruct(Dm.get());

    /* ---------- ReceiveSpec ---------- */
    auto &R = res.receiveSpec;
    static std::vector<int32_t> channelMap;
    channelMap = vec<int32_t>(Rm.get(), "channel2ElementMap");
    R.nSamples = scalar<int32_t>(Rm.get(), "nSamples");
    R.nSamplesIQ = scalar<int32_t>(Rm.get(), "nSamplesIQ");
    R.nTX = scalar<int32_t>(Rm.get(), "nTransmissions");
    R.nRepeats = scalar<int32_t>(Rm.get(), "nRepeats");
    R.nChannels = scalar<int32_t>(Rm.get(), "nChannels");
    R.nActiveChannels = scalar<int32_t>(Rm.get(), "nElements");
    R.activeChannelMap = channelMap.data();
    R.Fs = scalar<float>(Rm.get(), "Fs");

    R.rfSize =
        static_cast<int64_t>(R.nSamples) * R.nChannels * R.nTX * R.nRepeats;
    R.mNRows = R.nSamples * R.nTX * R.nRepeats;

    /* ----------- ReconSpec ----------- */
    auto &P = res.reconSpec;
    static std::vector<int32_t> crop = vec<int32_t>(Pm.get(), "croppingROI");
    static std::vector<double> zAxis = vec<double>(Pm.get(), "zAxis");
    static std::vector<double> xAxis = vec<double>(Pm.get(), "xAxis");

    P.nSamplesCropTop = crop[0];
    P.nSamplesCropBot = crop[1];
    P.nChannelsCropLeft = crop[2];
    P.nChannelsCropRight = crop[3];
    P.nSamplesReduced = P.nSamplesCropBot - P.nSamplesCropTop + 1;
    P.nChannelsReduced = P.nChannelsCropRight - P.nChannelsCropLeft + 1;
    P.nz = scalar<int32_t>(Pm.get(), "nz");
    P.nx = scalar<int32_t>(Pm.get(), "nx");
    P.zSpacing = zAxis.at(1) - zAxis.at(0);
    P.xSpacing = xAxis.at(1) - xAxis.at(0);
    P.totalSize = P.nz * P.nx;
    P.totalSizeCropped = P.nSamplesReduced * P.nChannelsReduced;
    P.filterFrequencies = scalar<uint8_t>(Pm.get(), "filterFrequencies");
    P.getBF = scalar<uint8_t>(Pm.get(), "getBF");
    P.getPDI = scalar<uint8_t>(Pm.get(), "getPDI");
    P.cropBF = scalar<uint8_t>(Pm.get(), "cropBF");
    P.ensembleSize = R.nRepeats;

    validateFourierMatStruct(Pm.get());

    auto &F = res.fourierReconSpec;

    static auto delayIdx = vecRowMajor<int32_t>(
        Mat_VarGetStructFieldByName(Pm.get(), "delayIndices", 0));

    static auto interpW = vecCplxRowMajor(
        Mat_VarGetStructFieldByName(Pm.get(), "interpolationWeights", 0));
    static auto freqAxis = vec<float>(Pm.get(), "frequencyAxis");
    static auto pwDelays = vec<float>(Pm.get(), "planewaveDelays");
    static auto tgc = vec<float>(Pm.get(), "tgcVector");

    F.delayIndices = delayIdx.data();
    F.interpolationWeights = interpW.data();
    F.frequencyAxis = freqAxis.data();
    F.planewaveDelays = pwDelays.data();
    F.tgcVector = tgc.data();

    /* ------------ PDISpec ------------ */
    auto &D = res.pdiSpec;
    D.ensemble_size = scalar<int32_t>(Dm.get(), "ensembleSize");
    D.threshold = scalar<float>(Dm.get(), "threshold");
    D.shiftSize = scalar<int32_t>(Dm.get(), "shiftSize");
    D.cropPDI = scalar<uint8_t>(Dm.get(), "cropPDI");
    std::string svdm = str(Dm.get(), "svdMethod");
    D.method = (svdm == "Full") ? PDI::Full : PDI::CovarianceEig;
    D.num_ensembles =
        std::max<int32_t>(0, (R.nRepeats - D.ensemble_size) / D.shiftSize + 1);
    D.total_size = P.totalSize;

    Mat_Close(fp);
}
