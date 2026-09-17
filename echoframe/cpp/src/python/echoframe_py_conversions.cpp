/**
 * @file echoframe_py_conversions.cpp
 * @author BrainEcho Lab
 * @brief Python-to-Native Resource Conversion Utilities
 * @details This file implements helper functions for converting Python
 * dictionaries (typically from pybind11) into native EchoFrame C++ resource
 * structures. These utilities enable the creation and initialization of
 * EchoframeResources objects from Python, supporting seamless integration with
 * Python-based workflows and bindings.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include <pybind11/complex.h>
#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <iostream>

#include "../../libs/Storage/src/storage/storage_spec.h"
#include "../beamformer/echoframe_resources_bundle.h"  // ReceiveSpec, ReconSpec
#include "../efcore/echoframe_ci_interface.h"          // EchoframeResources

namespace py = pybind11;
using namespace Beamform;   // for ReceiveSpec, ReconSpec
using namespace EchoFrame;  // for EchoframeResources

/* ----------------------------- tiny helpers ------------------------------ */

template <typename T>
T scalar_or_first(const py::handle &obj, const char *field_name) {
    // Fast path: plain scalar
    if (!py::isinstance<py::array>(obj)) return obj.cast<T>();

    // ndarray path
    py::array arr = py::cast<py::array>(obj);
    if (arr.size() != 1)
        throw std::runtime_error(std::string(field_name) +
                                 " must be scalar or length-1 array");

    // Make sure the data are of the right dtype and contiguous
    py::array_t<T, py::array::c_style | py::array::forcecast> one(arr);
    return *one.data();
}

static PDI::SVDMethod string_to_method_pdi(const std::string &s) {
    if (s == "Full") return PDI::Full;
    if (s == "Covariance") return PDI::CovarianceEig;
    throw std::runtime_error("PDISpec.method: unknown value '" + s + "'");
}

/* --------------------------- ReceiveSpec ---------------------------------- */
static ReceiveSpec to_receive(const py::dict &d) {
    ReceiveSpec r;
    r.nSamples = scalar_or_first<int32_t>(d["nSamples"], "nSamples");
    r.nSamplesIQ = scalar_or_first<int32_t>(d["nSamplesIQ"], "nSamplesIQ");
    r.nTX = scalar_or_first<int32_t>(d["nTransmissions"], "nTransmissions");
    r.nRepeats = scalar_or_first<int32_t>(d["nRepeats"], "nRepeats");
    r.nChannels = scalar_or_first<int32_t>(d["nChannels"], "nChannels");
    r.nActiveChannels = scalar_or_first<int32_t>(d["nElements"], "nElements");
    auto ac = d["channel2ElementMap"].cast<py::array_t<int32_t>>();
    r.activeChannelMap = const_cast<int32_t *>(ac.data());
    r.Fs = scalar_or_first<float>(d["Fs"], "Fs");
    r.rfSize =
        static_cast<int64_t>(r.nSamples) * r.nChannels * r.nTX * r.nRepeats;
    r.mNRows = r.nSamples * r.nTX * r.nRepeats;

    r.initialized = true;
    return r;
}

static ReconSpec to_recon(const py::dict &d, const ReceiveSpec &rs) {
    ReconSpec r;
    r.nz = scalar_or_first<int32_t>(d["nz"], "nz");
    r.nx = scalar_or_first<int32_t>(d["nx"], "nx");
    r.totalSize = r.nz * r.nx;

    r.ensembleSize = rs.nRepeats;

    // Cropping dimensions init
    auto roi = d["croppingROI"].cast<std::vector<int32_t>>();
    auto zAxis = d["zAxis"].cast<std::vector<double>>();
    auto xAxis = d["xAxis"].cast<std::vector<double>>();

    r.zSpacing = zAxis.at(1) - zAxis.at(0);
    r.xSpacing = xAxis.at(1) - xAxis.at(0);

    r.nSamplesCropTop = roi.at(0);
    r.nSamplesCropBot = roi.at(1);
    r.nChannelsCropLeft = roi.at(2);
    r.nChannelsCropRight = roi.at(3);
    r.nSamplesReduced = r.nSamplesCropBot - r.nSamplesCropTop + 1;
    r.nChannelsReduced = r.nChannelsCropRight - r.nChannelsCropLeft + 1;
    r.totalSizeCropped = r.nSamplesReduced * r.nChannelsReduced;

    r.filterFrequencies =
        scalar_or_first<bool>(d["filterFrequencies"], "filterFrequencies");

    r.getBF = scalar_or_first<bool>(d["getBF"], "getBF");
    r.getPDI = scalar_or_first<bool>(d["getPDI"], "getPDI");
    r.cropBF = scalar_or_first<bool>(d["cropBF"], "cropBF");
    r.initialized = true;
    return r;
}

/* ───────────── Fourier-Imaging specific parameters ─────────────────────── */
static Beamform::FourierReconSpec to_fourier_spec(const py::dict &src) {
    Beamform::FourierReconSpec f;

    /* delay indices (int32) */
    auto di = src["delayIndices"].cast<py::array_t<int32_t>>();
    f.delayIndices = const_cast<int32_t *>(di.data());

    /* interpolation weights – complex64 -> float2 */
    /* ----- interpolation weights  ------------------------------------ */
    auto w_np =
        src["interpolationWeights"].cast<py::array_t<std::complex<float>>>();

    std::size_t n = w_np.size();
    float2 *buf = new float2[n];  // own a copy
    std::memcpy(buf, w_np.data(), n * sizeof(std::complex<float>));

    f.interpolationWeights = buf;  // *** assign pointer ***

    /* 1-D float vectors */
    auto fa = src["frequencyAxis"].cast<py::array_t<float>>();
    auto pd = src["planewaveDelays"].cast<py::array_t<float>>();
    auto tg = src["tgcVector"].cast<py::array_t<float>>();

    f.frequencyAxis = const_cast<float *>(fa.data());
    f.planewaveDelays = const_cast<float *>(pd.data());
    f.tgcVector = const_cast<float *>(tg.data());
    return f;
}

static PDI::PDISpec to_pdi(const py::dict &d, const ReconSpec &rec) {
    PDI::PDISpec p;
    p.ensemble_size =
        scalar_or_first<int32_t>(d["ensembleSize"], "ensembleSize");
    p.threshold = scalar_or_first<float>(d["threshold"], "threshold");
    p.shiftSize = scalar_or_first<int32_t>(d["shiftSize"], "shiftSize");
    p.cropPDI = scalar_or_first<bool>(d["cropPDI"], "cropPDI");
    p.num_ensembles = rec.ensembleSize / p.ensemble_size;

    p.total_size = rec.totalSize;
    if (py::isinstance<py::str>(d["svdMethod"]))
        p.method = string_to_method_pdi(d["svdMethod"].cast<std::string>());
    else
        p.method = d["svdMethod"].cast<PDI::SVDMethod>();
    return p;
}

/* ------------------------- top-level builder ----------------------------- */
static EchoframeResources make_resources(const py::dict &recv,
                                         const py::dict &recon,
                                         const py::dict &pdi) {
    EchoframeResources res;
    res.receiveSpec = to_receive(recv);
    res.reconSpec = to_recon(recon, res.receiveSpec);
    res.pdiSpec = to_pdi(pdi, res.reconSpec);

    res.fourierReconSpec = to_fourier_spec(recon);

    /*  disable storage for offline   */
    res.bfStorageSpec.save = false;
    res.pdiStorageSpec.save = false;
    res.rfTimeTagStorageSpec.save = false;
    return res;
}

/* ---------------------- expose into the same module ---------------------- */
void bind_converters(py::module_ &m) {
    m.def("make_resources", &make_resources, py::arg("receive"),
          py::arg("recon"), py::arg("pdi"),
          R"pbdoc(
Build an EchoframeResources object from three Python dicts:
  make_resources(receive_dict, recon_dict, pdi_dict) -> Resources
)pbdoc");
}
