# EchoFrame Agent Guidelines

## Project map

- `echoframe/cpp/src/` is the C++17/CUDA core and CMake project.
  - `beamformer/` and `pdi/` implement the GPU pipelines.
  - `efcore/` is the core controller and C-compatible interface.
  - `mex/`, `python/`, and `echoframe_cli/` are the MATLAB, Python, and CLI front ends.
- `echoframe/matlab/` is the MATLAB side, split by role:
  - `core/` - the library (`imaging/`, `storage/`, `reading/`, `verasonics/`, `setup/`).
  - `tests/` - the `verify_*` harnesses, with `data/` and `reference/`.
  - `benchmarks/` and `examples/`.
- `echoframe/python/` holds `core/` helper modules, `examples/` and `tests/`.
- `echoframe/cpp/libs/` contains submodules/external code; do not modify it unless the task explicitly requires it.
- `build_scripts/` holds the developer helper scripts (Windows build, vcpkg setup, build verification). `justfile` stays at the root because `just` searches upward for it.
- `binaries/` holds the prebuilt per-CUDA/MATLAB build zips offered in the README.
- `README.md` is the canonical setup guide, and `build_scripts/build_echoframe.bat` lists the supported Windows build combinations. For Linux, `docker/` carries a known-good Ubuntu 22.04 / CUDA 12.8 environment.

Initialize submodules before building:

```bash
git submodule update --init
```

## Build and validation

Build all front ends by default: CLI, MATLAB MEX, and Python. Do not disable an interface merely because the change appears local.

```bash
cmake -S echoframe/cpp/src -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DEF_BUILD_CLI=ON \
  -DEF_BUILD_MEX=ON \
  -DEF_BUILD_PYTHON=ON \
  -DMatlab_ROOT_DIR="$HOME/MATLAB/R2024a" \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++
cmake --build build -j"$(nproc)"
```

`CMAKE_CUDA_ARCHITECTURES` is not passed here because `CMakeLists.txt` sets it
from the toolkit version and overrides anything given on the command line:
`61;75;86;89;90` on CUDA 12.4+, `75;80;86;89;90;100;103;121` on CUDA 13+.

The CLI also requires Matio, HDF5, and ZLIB. On Windows, use the vcpkg and Visual Studio 2022 configuration in `README.md` or `build_scripts/build_echoframe.bat`.

`build_scripts/build_echoframe.bat` must be run from an **elevated** terminal: it switches the Visual Studio CUDA integration by renaming files under `Program Files`. A non-elevated run leaves whichever integration was already active, and the mismatch against `CUDA_PATH` surfaces much later as `nvcc fatal : Unsupported gpu architecture`. The two must agree.

On Windows the CLI's vcpkg dependencies must build against the dynamic CRT so they match the MEX and Python modules. Set `VCPKG_ROOT` before configuring, then configure with the `default` CMake preset (`cmake --preset default` from `echoframe/cpp/src`) or pass `-DVCPKG_TARGET_TRIPLET=x64-windows-static-md`. Passing an explicit `-DCMAKE_TOOLCHAIN_FILE` skips the automatic triplet selection, so set the triplet yourself in that case.

There are automated tests: the `verify_*` harnesses in `echoframe/matlab/tests/` (each errors out on any mismatch, so a clean run is a pass), a `pytest` suite in `echoframe/python/tests/`, and `echoframe/matlab/run_all_matlab.m` to drive the MATLAB side. Most harnesses need a GPU **and** an elevated MATLAB; the two `*_headless.m` ones and `pytest` need neither, which is why those are all that `.github/workflows/` can run. See `echoframe/matlab/tests/README.md` for what each one proves.

MATLAB loads the MEX from `echoframe/cpp/src/build/Release/`. The Quick Start commands in `README.md` configure into exactly that tree, so a build made that way needs no copying. `build_scripts/build_echoframe.bat` deliberately does not: it builds one tree per CUDA/MATLAB combination as `build_<CONFIG>/` and packages each into `binaries/`. After running it, copy the artifacts across or set `MEX_DIR` to pin the build under test. Do not treat generated `build*/` files as source edits.

## Source and binding rules

- Keep C++17 and CUDA code in `echoframe/cpp/src/`; CMake intentionally compiles some `.cpp` files as CUDA because they transitively use kernel-launch syntax.
- A change to a core resource structure or C interface may require matching changes in both `mex/` conversions and `python/` conversions. Trace all callers before editing the shared interface.
- Preserve CUDA error handling and GPU resource lifetime behavior. Check errors at CUDA/MATLAB/Python trust boundaries.
- Keep MATLAB, Python, and CLI behavior aligned when changing shared pipeline semantics.

## Style and tests

- Format touched C++/CUDA headers and sources with:

  ```bash
  clang-format -i path/to/file
  ```

  The style file is `echoframe/cpp/.clang-format` (Google-based, four-space indent, right-aligned pointers).
- Prefer focused, readable functions and existing project patterns over new abstractions.
- Comments say what the code does and what constraint it satisfies, not why it was changed. Keep them short and match the density of the surrounding file. Change history and "this used to be X" belong in the commit message, not in the source. Copied-code provenance and hardware constraints are worth a line. End comments with a period. Use `TODO:` for incomplete work, not as a note to self.
- Add a small regression check for new non-trivial behavior. It must fail on an incorrect result, cover relevant edge/error cases, and use small deterministic data. Do not add tests solely for coverage.

## Environment traps

- **Anything that touches storage needs an elevated MATLAB.** `Handler::init` calls `assignPriviledges()` before it opens a file; without `SeManageVolumePrivilege` it throws and calls `std::terminate()`, which takes the whole MATLAB session down rather than failing the call. A hard requirement on Windows, not an optimisation; on Linux it is a documented no-op.

## Commits and pull requests

Use Conventional Commit messages:

```text
<type>(<scope>): <short summary>
```

Use `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, or `chore`. Choose a component scope such as `beamformer`, `pdi`, `efcore`, `mex`, `python`, `cli`, `cmake`, `matlab`, `examples`, or `docs`.

Examples:

```text
fix(beamformer): validate receive aperture dimensions
build(cmake): enable CUDA compilation for CLI sources
docs(matlab): clarify reconstruction setup
```

Keep commits focused. In a PR, state the affected interfaces and the build/example validation run.
