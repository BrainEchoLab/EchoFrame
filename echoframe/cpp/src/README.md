# echoframe/cpp/src

The `src/` directory contains the core source code of the EchoFrame project, implementing the key algorithms and processing pipelines for ultrasound beamforming, imaging, and Doppler processing. The codebase is modular and object-oriented, with each subdirectory focused on a specific aspect of the system's functionality.

- **CMakeLists.txt**: Automates the build process for the EchoFrame core library and MEX interface, supporting MATLAB, Python and standalone workflows.

## Directory Structure

### 1. beamformer/
Implements the core beamforming algorithms and supporting infrastructure.

- **beamformer.h / beamformer.t.hpp**: Defines the `Beamformer` class template, providing a base interface and common functionality for beamforming operations, including resource management and GPU memory handling.
- **beamformer_kernels.cu / beamformer_kernels.h**: CUDA kernels for RF data formatting, conversion, magnitude computation, and cropping.
- **BF_formatter.h**: Converts beamformed data to various output formats (real, half, bfloat16, B-mode) and manages GPU/host memory for output.
- **RF_formatter.h**: Formats raw RF data for beamforming, manages device/host memory, and handles efficient transfer and conversion.
- **resources.h**: Declares the `ReceiveSpec` and `ReconSpec` structures for RF data acquisition and reconstruction.
- **echoframe_resources_bundle.h**: Bundles all resource specifications (receive, recon, PDI, Fourier, storage) for initializing and configuring the EchoFrame system.
- **fourier_imaging/**: Implements Fourier-based beamforming and reconstruction (see below).

### 2. beamformer/fourier_imaging/
Implements advanced Fourier-based beamforming and reconstruction.

- **fourier_imaging.h / fourier_imaging.t.hpp**: Defines the `FourierImaging` class template, managing cuFFT plans and GPU memory for frequency-domain processing.
- **fourier_imaging_kernels.cuh / fourier_imaging_kernels.cu**: CUDA kernels for TGC, delay application, interpolation, compounding, and scaling in Fourier imaging workflows.
- **fourier_recon_spec.h**: Defines the `FourierReconSpec` structure for Fourier-based reconstruction parameters and GPU pointers.

### 3. pdi/
Implements Power Doppler Imaging (PDI) using GPU acceleration.

- **pdi_class.cuh / pdi_class.cu**: Declares and implements the `PDI` class for Power Doppler Imaging, supporting SVD and covariance methods.
- **pdi_spec.h**: Defines the `PDISpec` structure for PDI algorithm parameters.
- **pdi_kernels.cuh / pdi_kernels.cu**: CUDA kernels for thresholding, conversion, and cropping in PDI processing.

### 4. cuda/
CUDA utility headers for error handling and GPU timing.

- **cuda_error.h**: Exception classes, macros, and helpers for robust error checking and reporting with CUDA and related libraries.
- **cuda_event_timer.hpp**: Utility for timing CUDA GPU operations using named event pairs.

### 5. efcore/
Core pipeline controller and C/C++ interface for EchoFrame.

- **echoframe_core.h / echoframe_core.cu**: Declares and implements the `EchoFrameCore` class, managing beamforming, PDI, and storage.
- **echoframe_ci_interface.h / echoframe_ci_interface.cpp**: C-compatible interface for integration with MATLAB MEX and Python bindings.

### 6. echoframe_cli/
Command-line interface (CLI) utilities for batch/offline processing.

- **cli.cpp**: Main CLI application for batch processing and benchmarking.
- **read_rf.hpp / read_rf.cpp**: Functions for reading RF acquisition data and headers from binary files.
- **load_specs_from_mat.hpp / load_specs_from_mat.cpp**: Functions for loading scan and processing specifications from MATLAB `.mat` files.

### 7. mex/
CUDA source and header files for building the MATLAB MEX interface.

- **echoframe_mex.cu / echoframe_mex.h**: Implements the MATLAB MEX gateway for the EchoFrame core.
- **mex_resources_conversions.h / mex_resources_conversions.cpp**: Functions for converting MATLAB `mxArray` resource structures into native EchoFrame C++ structures.

### 8. python/
Python bindings and integration layer for the EchoFrame backend.

- **__init__.py**: Python shim for the C++/CUDA extension, manages CUDA DLL paths on Windows.
- **echoframe_py_wrapper.cpp**: Python bindings for the EchoFrame backend using pybind11.
- **echoframe_py_conversions.cpp**: Helper functions for converting Python dictionaries to native EchoFrame resource structures.

## Further Information

For detailed information about specific algorithms or classes, refer to the README files within each subdirectory (`beamformer/`, `cuda/`, `pdi/`, `efcore/`, `echoframe_cli/`, `mex/`, `python/`). These documents provide in-depth explanations of the logic and usage of the components contained within