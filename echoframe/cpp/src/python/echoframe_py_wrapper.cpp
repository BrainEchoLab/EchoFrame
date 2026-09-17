/**
 * @file echoframe_py_wrapper.cpp
 * @author BrainEcho Lab
 * @brief Python Bindings for EchoFrame CUDA Core
 * @details This file implements the Python bindings for the EchoFrame CUDA
 * backend using pybind11. It exposes the main EchoFrame resource structures and
 * processing functions to Python, enabling seamless integration with
 * Python-based workflows. The wrapper provides a high-level EchoFrame class for
 * resource management, processing, storage reinitialization, and parameter
 * updates from Python.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include "../beamformer/beamformer.t.hpp"
#include "../efcore/echoframe_ci_interface.h"
#include "../pdi/pdi_spec.h"

namespace py = pybind11;
using i16 = int16_t;
using namespace EchoFrame;

/* forward decl of binder from the conversion file */
void bind_converters(py::module_ &m);

/* ---- tiny macro to expose fields quickly ---- */
#define RW(cls, field) .def_readwrite(#field, &cls::field)

/* ─────────── bind structs for IDE autocomplete ──────────────────────────── */
static void bind_specs(py::module_ &m) {
    /* ---- ReceiveSpec ---------------------------------------------------- */
    py::class_<Beamform::ReceiveSpec>(m, "ReceiveSpec")
        .def(py::init<>())

        /* RF dimensions */
        RW(Beamform::ReceiveSpec, nSamples)
            RW(Beamform::ReceiveSpec, nSamplesIQ)
                RW(Beamform::ReceiveSpec, nSlowTimeSamples)
                    RW(Beamform::ReceiveSpec, nChannels)
                        RW(Beamform::ReceiveSpec, nTX)
                            RW(Beamform::ReceiveSpec, nRepeats)
                                RW(Beamform::ReceiveSpec, nFastTimeSamples)
                                    RW(Beamform::ReceiveSpec, rfSize)
                                        RW(Beamform::ReceiveSpec, mNRows)

        /* flags & frequencies */
        RW(Beamform::ReceiveSpec, sampleMode) RW(Beamform::ReceiveSpec, Fs)

        /* misc */
        RW(Beamform::ReceiveSpec, nActiveChannels)
        .def_readwrite("initialized", &Beamform::ReceiveSpec::initialized);

    /* ---- ReconSpec ------------------------------------------------------ */
    py::class_<Beamform::ReconSpec>(m, "ReconSpec")
        .def(py::init<>())

        /* basic dims */
        RW(Beamform::ReconSpec, ensembleSize) RW(Beamform::ReconSpec, nz)
            RW(Beamform::ReconSpec, nx) RW(Beamform::ReconSpec, totalSize)

        /* cropping info */
        RW(Beamform::ReconSpec, nSamplesReduced)
            RW(Beamform::ReconSpec, nChannelsReduced)
                RW(Beamform::ReconSpec, nSamplesCropTop)
                    RW(Beamform::ReconSpec, nSamplesCropBot)
                        RW(Beamform::ReconSpec, nChannelsCropLeft)
                            RW(Beamform::ReconSpec, nChannelsCropRight)
                                RW(Beamform::ReconSpec, totalSizeCropped)
                                    RW(Beamform::ReconSpec, cropBF)

        /* behaviour flags */
        RW(Beamform::ReconSpec, filterFrequencies)
            RW(Beamform::ReconSpec, getBF) RW(Beamform::ReconSpec, getPDI)

        .def_readwrite("initialized", &Beamform::ReconSpec::initialized);
}

/* ─────────────── EchoFrame RAII wrapper ────────────────────────────────── */
class EchoFrameWrapper {
   public:
    EchoFrameWrapper(const EchoframeResources &res, bool use_storage)
        : res_(res) {
        handle_ = EchoFrameCreate(&res_, use_storage);
        if (!handle_) throw std::runtime_error("EchoFrameCreate failed");
    }
    ~EchoFrameWrapper() {
        if (handle_) EchoFrameDestroy(handle_);
    }

    py::tuple process(
        py::array_t<i16, py::array::c_style | py::array::forcecast> rf,
        bool start_storage = false) {
        if (rf.ndim() != 1)
            throw std::runtime_error("RF buffer must be 1-D int16");

        auto out =
            EchoFrameProcessAndGetOutputs(handle_, rf.data(0), start_storage);

        auto pdi_shape = std::array<std::ptrdiff_t, 3>{
            res_.reconSpec.nz, res_.reconSpec.nx, res_.pdiSpec.num_ensembles};
        auto bmode_shape =
            std::array<std::ptrdiff_t, 2>{res_.reconSpec.nz, res_.reconSpec.nx};
        auto bf_shape = std::array<std::ptrdiff_t, 3>{
            res_.reconSpec.nz, res_.reconSpec.nx, res_.receiveSpec.nRepeats};

        py::array pdi = py::array_t<float>(pdi_shape);
        py::array bmode = py::array_t<float>(bmode_shape);
        py::array bfcmp = py::array_t<std::complex<float>>(bf_shape);

        std::memcpy(pdi.mutable_data(), out.pPDI, pdi.nbytes());
        std::memcpy(bmode.mutable_data(), out.pBmode, bmode.nbytes());
        std::memcpy(bfcmp.mutable_data(), out.pBFComplex, bfcmp.nbytes());

        return py::make_tuple(pdi, bmode, bfcmp);
    }

    void reinit_storage(const EchoframeResources &r) {
        res_ = r;
        EchoFrameReinitStorage(handle_, res_);
    }
    void reinit_experiment(const EchoframeResources &r) {
        res_ = r;
        EchoFrameReinitExperiment(handle_, res_);
    }
    void update_pdi_threshold(float t) {
        res_.pdiSpec.threshold = t;
        EchoFrameUpdatePDIThreshold(handle_, t);
    }

   private:
    EchoframeResources res_;
    EchoFrameHandle *handle_{};
};

/* ─────────────── module definition ─────────────────────────────────────── */
PYBIND11_MODULE(echoframe, m) {
    m.doc() = "Python bindings for EchoFrame CUDA core";

    bind_specs(m);       // structs & enums
    bind_converters(m);  // dict -> Resources helpers

    py::class_<EchoframeResources>(m, "Resources")
        .def(py::init<>())
        .def_readwrite("receiveSpec", &EchoframeResources::receiveSpec)
        .def_readwrite("reconSpec", &EchoframeResources::reconSpec)
        .def_readwrite("pdiSpec", &EchoframeResources::pdiSpec)
        .def_readwrite("bfStorageSpec", &EchoframeResources::bfStorageSpec)
        .def_readwrite("pdiStorageSpec", &EchoframeResources::pdiStorageSpec)
        .def_readwrite("rfTimeTagStorageSpec",
                       &EchoframeResources::rfTimeTagStorageSpec)
        .def_readwrite("fourierReconSpec",
                       &EchoframeResources::fourierReconSpec);

    py::class_<EchoFrameWrapper>(m, "EchoFrame")
        .def(py::init<const EchoframeResources &, bool>(), py::arg("resources"),
             py::arg("use_storage") = false)
        .def("process", &EchoFrameWrapper::process, py::arg("rf_buffer"),
             py::arg("start_storage") = false)
        .def("reinit_storage", &EchoFrameWrapper::reinit_storage)
        .def("reinit_experiment", &EchoFrameWrapper::reinit_experiment)
        .def("update_pdi_threshold", &EchoFrameWrapper::update_pdi_threshold);
}
