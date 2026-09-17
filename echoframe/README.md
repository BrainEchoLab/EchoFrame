# echoframe/

The `echoframe/` directory holds the main components of EchoFrame, split into `cpp/`
(the C++/CUDA processing core) and `matlab/` (the MATLAB helpers that build the
spec structs, precompute reconstruction tables, and manage storage around it).

## Directory Structure

### 1. cpp/

The C++/CUDA code that powers EchoFrame's real-time beamforming and Power Doppler
Imaging (PDI). Sources live under `cpp/src/`, organized into:

- **beamformer/** — the Fourier (f-k) beamforming pipeline: raw RF → coherent BF.
- **pdi/** — Power Doppler Imaging via SVD tissue filtering.
- **efcore/** — `EchoFrameCore` (the pipeline controller) and the C interface used
  by the MATLAB and Python bindings.
- **cuda/** — CUDA error handling and event-based timing helpers.
- **mex/** — the MATLAB MEX gateway (`echoframe_mex`).
- **python/** — the pybind11 module.
- **echoframe_cli/** — the standalone command-line tool.
- **utils/** — shared math helpers.

The build is CMake + vcpkg driven (`cpp/src/CMakeLists.txt`, `cpp/src/vcpkg.json`)
with `EF_BUILD_MEX` / `EF_BUILD_PYTHON` / `EF_BUILD_CLI` options — see the main
README and `cpp/README.md` for build instructions.

### 2. matlab/

MATLAB helpers that build the spec structs, precompute reconstruction tables, and
manage storage around the compiled `echoframe_mex`, split into `core/` (the
library), `tests/`, `benchmarks/` and `examples/`.

See [`matlab/README.md`](./matlab/README.md) for the folder-by-folder index and the
spec-struct field tables; each folder documents its own contents.

Note that `initialize_image_reconstruction.m` only derives sizes and precomputes
the reconstruction tables from the spec structs; the compiled
`echoframe_mex('init', …)` is a separate step.

## Usage Overview

Build the C++/CUDA code with CMake + vcpkg (see the main README), then from MATLAB
set `ECHOFRAME_PATH`, call `initialize_image_reconstruction` +
`echoframe_validate_structs` to prepare the specs, and `echoframe_mex('init', …)`
to initialise the pipeline. See `matlab/examples/` for runnable end-to-end scripts.

## Notes

- **Compatibility:** needs an NVIDIA GPU and a compatible CUDA toolkit.
- For more detail, see the README under `cpp/` and the example scripts under
  `matlab/examples/`.
