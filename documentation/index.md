# EchoFrame

EchoFrame does Fourier-domain beamforming and Power Doppler (PDI) on the GPU. The
core is C++17 / CUDA, with bindings for MATLAB (mex), Python (pybind11) and a
command-line module.

These pages cover the C++ API. For build instructions and the examples, see the
repository README.

```{toctree}
:maxdepth: 2
:caption: Contents

api/index
```

## Where things live

- `echoframe/cpp/src/` — the C++ / CUDA core.
  - `efcore/` — the top-level `EchoFrameCore` class and the C handle API the
    bindings call.
  - `beamformer/` — Fourier beamforming, plus the RF and BF formatters.
  - `pdi/` — the Power Doppler stage.
  - `mex/`, `python/`, `echoframe_cli/` — the three bindings.
  - `cuda/` — error checking and timing helpers.
- `echoframe/matlab/` — the MATLAB side, split by role.
  - `core/` — the library: spec structs and the precomputed reconstruction
    tables the core reads (`imaging/`), writing recordings (`storage/`), reading
    them back (`reading/`), Verasonics conversion, and path setup.
  - `tests/` — the `verify_*` harnesses, plus `data/` and `reference/`.
  - `benchmarks/` — throughput benchmarks and the GPU-fit check.
  - `examples/` — runnable examples, each with its own README.
- `echoframe/python/` — `core/` helper modules, `examples/` and `tests/`.
- `build_scripts/` — developer helper scripts: the Windows build, vcpkg setup, and the
  build-verification harness.
- `binaries/` — prebuilt builds, one zip per CUDA/MATLAB combination.
