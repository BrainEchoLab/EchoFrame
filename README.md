# EchoFrame – Ultrafast GPU fUSI Library

**CUDA‑accelerated real‑time plane‑wave beamforming with MATLAB & Python bindings**

![GPU](https://img.shields.io/badge/GPU-Min%20SM%206.1%20%28Pascal%29-brightgreen)
![CUDA Toolkit](https://img.shields.io/badge/CUDA%20Toolkit-%3E%3D12.4-orange)
![CMake](https://img.shields.io/badge/CMake-%3E%3D3.21-blue)
![MATLAB](https://img.shields.io/badge/MATLAB-%3E%3DR2022a-blueviolet)
![Python](https://img.shields.io/badge/Python-%3E%3D3.10-yellow)

---

## Overview<a name="overview"></a>

EchoFrame delivers high‑throughput **Fourier‑domain beamforming** and **Power‑Doppler (PDI)** ultrasound pipelines, fully written in **C++17 / CUDA** and wrapped for both **MATLAB** *(mex)* and **Python** *(pybind11)*.

* Real‑time performance (> 10 kFPS on RTX 40‑series)
* Self‑contained build: CMake ≥ 3.21 (used to build the project) + a recent CUDA toolkit are all you need

**Prebuilt binaries**: 

| Versions | CUDA 12.8 | CUDA 12.9 | CUDA 13.1 |
|----------|-----------|-----------|-----------|
| Matlab 2022a | :white_check_mark: | :white_check_mark: | :white_check_mark: |
| Matlab 2024a | :white_check_mark: | :white_check_mark: | :white_check_mark: |


Questions? Open an issue or e‑mail **a.demi@erasmusmc.nl**.

---

**⚠️ IMPORTANT:** For a smooth setup experience you can use any of combinations mentioned in the **Prebuilt binaries** table above in [Overview](#overview), and jump straight to [Plug and Play](#plug-play).


---

### Prerequisites<a name="prerequisites"></a>

| Component | Minimum | Notes |
|-----------|---------|-------|
| EchoFrame repository | Latest version | You can download the zip of the repository or use git clone |
| NVIDIA GPU | SM 6.1 (Pascal) | default build targets *61 75 86 89 90* |
| CUDA® Toolkit | 12.4 | `nvcc` must be in `PATH`, `CUDA_PATH` must be set |
| CMake (optional) | 3.21 | CUDA language + C++ 17 |
| MATLAB | R2022a (due to Verasonics) | for the `echoframe_mex` gateway |
| Signal Processing Toolbox | — | required by the imaging setup (`gausswin`, `tukeywin`) |
| Parallel Computing Toolbox (optional) | — | only as a `gpuDevice` fallback in `check_gpu_memory_fit` when `nvidia-smi` is not on `PATH` |
| Python (optional) | 3.10 | for the `echoframe` py module |
| Visual Studio (optional) | 2022 | to build from source (only `Visual Studio 2022` supported) | 

**ℹ️ NOTE:** EchoFrame can be used and compiled with newer **MATLAB** versions (tested up to R2025a), the R2022a limitation 
applies only to use with Verasonics Vantage Systems. The most recent version of Vantage works with R2024a.

If you want to get straight into using EchoFrame (and you have the appropriate prerequisites installed), you can head to [Plug and Play](#plug-play). If you want to edit EchoFrame's core behaviour, you will have to build it from source at [Building from scratch](#build-source).

## Plug and Play <a name="plug-play"></a>

We offer a range of pre-built binaries for EchoFrame. This means you can simply copy and paste these files into your EchoFrame repository and you will be able to run the Matlab and Python scripts without needing to build it yourself.

**⚠️ IMPORTANT:** If you do not have one of the CUDA and Matlab combinations mentioned in the **Prebuilt binaries** table in [Overview](#overview), then you may run into issues using EchoFrame with them!

You can find these binaries in the `binaries` directory. There you can pick from the available builds whichever matches your CUDA and Matlab setup. Each folder in `binaries` contains a compressed `build` folder.

Once you have the EchoFrame repository in your local machine, you can navigate to `EchoFrame\echoframe\cpp\src` and paste the **uncompressed** `build` folder inside `src`. After that, you should be good to go.

You can then explore [how to use EchoFrame](#using-echoframe).

## Building from scratch <a name="build-source"></a>

**⚠️ IMPORTANT:** Run any build actions from a terminal with administrator privileges so everything works reliably.

The **CLI module** is the only target that needs third-party libraries (Matio, HDF5 and
ZLIB). The Python module and the MEX gateway link none of them, so if you are not building
the CLI you can skip ahead.

Those libraries are declared in `echoframe/cpp/src/vcpkg.json` and installed automatically at
configure time, so there is no `vcpkg install` step to run and no version to keep in sync
by hand.

> **Windows users:** Visual Studio 2022 Community already ships with MSVC v143, CMake and Ninja. 

All the CLI build needs is a vcpkg checkout and `VCPKG_ROOT` pointing at it:

```powershell
# one-time setup of vcpkg if you haven't already
git clone https://github.com/Microsoft/vcpkg C:\vcpkg
C:\vcpkg\bootstrap-vcpkg.bat

# tell the build where it lives (persists across sessions)
setx VCPKG_ROOT C:\vcpkg
```

Open a new terminal after `setx` so `VCPKG_ROOT` is visible, then configure as usual. The
first CLI configure builds Matio and HDF5 and takes a few minutes; every configure after
that is immediate.

The location is up to you -- nothing in the build files refers to `C:\vcpkg`, so moving the
checkout only means updating `VCPKG_ROOT`.

> **Not building the CLI?** Then vcpkg is not needed at all. Configure with
> `-DEF_BUILD_CLI=OFF` and the dependency step is skipped entirely. This is what the Python
> wheel does, which is why `pip install` needs nothing but CUDA and a compiler.

## Common issues

During the setup for this application, you may run into issues with the dependencies. Before going to the next section, it is important to make sure that everything is setup properly.

### Visual Studio 2022

EchoFrame is setup to work with Visual Studio 2022. If you are planning to build EchoFrame yourself instead of following [Plug and Play](#plug-play), then you either need to use an existing Visual Studio 2022 instance, get an installer from the official [website](https://visualstudio.microsoft.com/vs/older-downloads/) (you need an active Visual Studio Subscription to access the 2022 version, as the official latest version is 2026), or you can ask us for a copy of the 2022 installer.

You should make sure you have installed Visual Studio 2022 with the optional "Desktop Development with C++" kit selected. 

### Windows path length

Windows limits paths to 260 characters unless long paths are enabled, and the Visual Studio
generator writes deeply nested intermediate paths. If the repository sits far down the
filesystem, configuring can fail with:

```
error MSB4184: ... exceeds the OS max path limit. The fully qualified file name must be
less than 260 characters.
```

Any one of these fixes it:

- Clone somewhere short, e.g. `C:\dev\EchoFrame`.
- Enable long paths: set `LongPathsEnabled` to `1` under
  `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem` (needs a reboot).
- Use the Ninja generator (`-G Ninja`), which nests far less. Note Ninja needs a
  "x64 Native Tools VS 2022" prompt so `cl.exe` is on `PATH`; the Visual Studio generator
  arranges that for you.

This affects the build tree only. vcpkg keeps its own deep `buildtrees` under `VCPKG_ROOT`,
so a short `VCPKG_ROOT` (like `C:\vcpkg`) stays safe regardless of where the repo lives.

### CUDA

CUDA should only be installed after you have setup Visual Studio. 

It is important to make sure that your ```CUDA_PATH``` variable is set correctly. 

On Windows, you can use the GUI (Graphical User Interface):
  - Press Win + X and select System (or go to Control Panel > System).
  - Click on Advanced system settings on the left side.
  - In the System Properties window, click on Environment Variables.
  - In the System variables section:
      - Look for the ```CUDA_PATH``` variable.
      - Set the variable to your desired CUDA version, your path should look something like "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9".
      - Click OK to confirm. Any changes should take effect on a new instance of any terminal window (the variable change will not take effect on an open terminal instance, so close any open ones first).

If you have multiple CUDA versions installed, make sure CMake, `nvcc`, and Visual Studio BuildCustomizations resolve to the same toolkit version. By default, this folder will be at:

```C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Microsoft\VC\v170\BuildCustomizations```.

Inside here you will find files named ```CUDA MV.mv.props```, ```CUDA MV.mv.targets```, ```CUDA MV.mv.xml```, and ```CUDA MV.mv.Version.props``` where MV is the major version of CUDA such as 12 or 13, and mv is the minor version.

You should only keep the files of the CUDA version you are planning to use to build the project. You can temporarily rename or move away the files from the other versions while building, and after you are finished you can move them back or rename them to their original names.

You can also force the toolkit version in CMake to avoid mismatches:

```powershell
cmake -S echoframe/cpp/src -B build -G "Visual Studio 17 2022" -A x64 -T cuda="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8" -DCUDAToolkit_ROOT="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
```

If you see `nvcc fatal : Unsupported gpu architecture 'compute_52'`, your selected toolkit may not support that architecture (for example, CUDA 13.x). Set an explicit supported architecture, for example:

```powershell
-DCMAKE_CUDA_ARCHITECTURES=61
```

or:

```powershell
-DCMAKE_CUDA_ARCHITECTURES=native
```

---

**ℹ️ NOTE:** You can find a clear automated batch script `build_echoframe.bat` in the `build_scripts/` folder, which might help with understanding how to avoid any issues with building. The prebuilt binaries it produces are built without `-DENABLE_CUDA_TIMING`, so they do not include the per-frame CUDA timing output. Run it from a terminal with administrator privileges so everything works reliably.

---

## Quick Start<a name="quick-start"></a>

### 🔧 Submodules
Before continuing, make sure that the submodules included in the project are properly initialized.
```bash
# make sure you are in the EchoFrame directory
git submodule init
git submodule update
```
You can continue with the rest of the build instructions if you have no errors.
Below you can find a set of commands to setup the project for both Linux and Windows.

The commands use an `echoframe/cpp/src/build/` directory, and then configure and build the project using CMake. 

### 🔧 Windows (Visual Studio 2022)

In order to compile the CLI and the complete Echoframe library use:

```powershell
# from a "x64 Native Tools VS 2022" prompt or Powershell
cd EchoFrame

#To choose between different versions of Matlab, you can change the -DMATLAB_VERSION variable. For Matlab 2022a the version is 9.12 and for Matlab 2024a the version is 24.1. This command is building with Matlab 2024a.
#If you have multiple versions of Visual Studio installed on your machine, you have to force Visual Studio 2022:

#The vcpkg toolchain is picked up from VCPKG_ROOT automatically, and the CLI's dependencies
#are installed from vcpkg.json at configure time. No toolchain or prefix path to pass here.

cmake -S echoframe/cpp/src -B echoframe/cpp/src/build -G "Visual Studio 17 2022" -A x64 -DCMAKE_BUILD_TYPE=Release -DMATLAB_VERSION="24.1" -DEF_BUILD_CLI=ON -DEF_BUILD_MEX=ON -DEF_BUILD_PYTHON=ON

#Build using all available CPU cores (MSBuild /m). Use /m:<N> to cap workers.
cmake --build echoframe/cpp/src/build --config Release -- /m
```

**ℹ️ NOTE:** If you want to build the complete library, there is no need to define `EF_BUILD_CLI` for Python, MEX and CLI. They are set to `ON` by default, the above is just to demonstrate how they would be used.

Alternatively, configure and build from the bundled preset, which applies the same flags and
pins the `x64-windows-static-md` vcpkg triplet:

```powershell
# from a "x64 Native Tools VS 2022" prompt or Powershell
cd EchoFrame/echoframe/cpp/src

cmake --preset default          # configure
cmake --build --preset default  # build
```


Compile only the MEX and Python support (no CLI), with Visual Studio 2022 being the only version you have installed:

```powershell
# from a "x64 Native Tools VS 2022" prompt or Powershell

# make sure you are in the EchoFrame directory

# With -DEF_BUILD_CLI=OFF nothing here needs vcpkg at all -- VCPKG_ROOT is not even read.

cmake -S echoframe/cpp/src -B echoframe/cpp/src/build -DCMAKE_BUILD_TYPE=Release -DMATLAB_VERSION="24.1" -DEF_BUILD_CLI=OFF -DEF_BUILD_MEX=ON -DEF_BUILD_PYTHON=ON

cmake --build echoframe/cpp/src/build --config Release
```

Both commands generate:

* `echoframe/cpp/src/build/Release/echoframe_core.<lib|dll|so>` – static/shared back‑end
* `echoframe/cpp/src/build/Release/echoframe_mex.*`            – MATLAB gateway (if enabled)
* `echoframe/cpp/src/build/Release/storage.*`                  – MATLAB RF-storage gateway (if enabled)
* `echoframe/cpp/src/build/Release/echoframe.*`                – Python extension module (if enabled)

This is the directory the MATLAB scripts load the MEX from, so nothing has to be
copied afterwards.

---

### 🔧 Linux

**⚠️ IMPORTANT:** Run this with `sudo` so everything works reliably.

```bash
# make sure you are in the EchoFrame directory
cmake -S echoframe/cpp/src -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DEF_BUILD_MEX=ON \
  -DEF_BUILD_PYTHON=ON \
  -DMatlab_ROOT_DIR="$HOME/MATLAB/R2024a" \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++ \
  -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90"
cmake --build build -j$(nproc)
```

This single build now places both MATLAB MEX files in the same folder:

* `build/echoframe_mex.mexa64`
* `build/storage.mexa64`

---

## Build Options<a name="build-options"></a>

This section is meant to clarify what changes you can make to the CMake build commands to customise what is built.

(A guide on how to setup the build can be found on the [Quick Start](#quick-start) section.)

| CMake option | Default | Purpose |
|--------------|---------|---------|
| `EF_BUILD_MEX` | **ON** | build the MATLAB `echoframe_mex` and `storage` MEX wrappers |
| `EF_BUILD_PYTHON` | **ON** | build the Python `echoframe` module |
| `EF_BUILD_CLI` | **ON** | build the EchoFrame `cli` (command line) module |
| `ENABLE_CUDA_TIMING` | **OFF** | print per-frame CUDA kernel timings from `process()` to the console |
| `CMAKE_CUDA_ARCHITECTURES` | set from the CUDA version: `61;75;86;89;90` on CUDA 12.4+, `75;80;86;89;90;100;103;121` on CUDA 13+ | compute capability list. `CMakeLists.txt` sets it after `project()`, so a value passed on the command line is replaced — edit the list there to narrow it |

Example: disabling Python in Linux:

```bash
cd EchoFrame
cmake -S echoframe/cpp/src -B build -DEF_BUILD_PYTHON=OFF
```

In addition, we also provide a `pyproject.toml` to build the Python EF wheel binding, more information can be found at [Python Setup](#python-setup).

---

## Using EchoFrame <a name="using-echoframe"></a>

### MATLAB Setup and Example (Windows)

**⚠️ IMPORTANT:** First add EchoFrame to your environmental variable by running in Matlab the script [echoframe/matlab/core/setup/setup_echoframe_paths.m](./echoframe/matlab/core/setup/setup_echoframe_paths.m) or by manually adding the 
root directory of the repo to the environment variable list.

Run logo simulation snippet matlab code [echoframe/matlab/examples/logo_simulation/logo_simulation.m](./echoframe/matlab/examples/logo_simulation/logo_simulation.m) script.

### MATLAB Setup and Example (Linux)
**⚠️ IMPORTANT:** For Linux, add your EchoFrame directory to PATH by adding the following lines to your `~/.bashrc`

```bash
export ECHOFRAME_PATH=$HOME/EchoFrame/
export PATH="$PATH:$ECHOFRAME_PATH"
```

Then run the following:

```bash
source ~/.bashrc
```

### Python Setup<a name="python-setup"></a>
After creating a fresh environment (e.g., see command below):

```bash
python -m venv "path_to_env"
```

Build the Python wheel:

```bash
cd EchoFrame/echoframe/cpp/src
pip install -e .
```

This needs only CUDA and a host compiler. The wheel builds the Python extension alone, so
it does not use vcpkg, Matio, HDF5 or ZLIB, and `VCPKG_ROOT` does not have to be set.

After editing the C++ sources, rebuild incrementally with `--no-build-isolation`
(install the build backend once, then reuse the persistent `build_py/` tree so only
changed files recompile):

```bash
pip install scikit-build-core pybind11 ninja
pip install -e . --no-build-isolation
```
Also, install the following packages used by the [echoframe/python/examples/process_echoframe_offline.py](./echoframe/python/examples/process_echoframe_offline.py):

```bash
pip install numpy
pip install h5py
pip install matplotlib
pip install scipy
```

In order to verify the succesful installation try the following in a Python console which should return no errors:

```python
import echoframe as ef
```

---

## Storage bandwidth<a name="storage-bandwidth"></a>

EchoFrame beamforms faster than most drives can absorb. When RF is saved, the drive
decides how long a recording can run.

**⚠️ IMPORTANT:** A drive that cannot sustain the required rate does not report an
error. The acquisition holds its frame period while the write queue absorbs the
excess, then slows abruptly once the queue is full and does not recover.

### What your configuration requires

Each saved stream costs bytes per frame, and the frame period is
`nTransmissions * nRepeats / txRate`:

```
RF   per frame = nSamples * nChannels * nTransmissions * nRepeats * 2   (int16)
BF   per frame = nz * nx * nRepeats * 8                                 (complex single)
PDI  per frame = nz * nx * 4

required rate  = (sum of saved streams) / frame period
```

`report_storage_demand` prints this before an acquisition starts, as
`SUSTAINED WRITE NEEDED`. Your drive has to beat it continuously.

### Measuring your drive

Use [diskspd](https://github.com/microsoft/diskspd) with the access pattern the
storage layer uses: unbuffered, write-through, a shallow queue and large blocks. You can change the -d600 variable (600 seconds) to whatever matches your desired acquisition period. 

```powershell
diskspd -c1500G -d600 -b1M -o3 -t1 -w100 -Suw -L -D D:\diskspd_probe.dat
Remove-Item D:\diskspd_probe.dat
```

| Parameter | What it does |
|-----------|--------------|
| `-c1500G` | Creates the test file at 1500 GiB. Set it larger than the run will write, otherwise the test wraps back onto blocks it has already written and measures a rewrite instead of new data. |
| `-d600` | Runs for 600 seconds, after which the file is discarded. Match it to the recording length you intend to make. |
| `-b1M` | Writes 1 MiB per operation, the same order of block size the storage layer issues. |
| `-o3` | Keeps 3 writes outstanding at once, the queue depth EchoFrame uses. |
| `-t1` | Uses one thread, as each stream is written from one thread. |
| `-w100` | 100% writes, no reads. |
| `-Suw` | `u` turns off OS buffering (`FILE_FLAG_NO_BUFFERING`), `w` writes through the drive's own cache (`FILE_FLAG_WRITE_THROUGH`). These match how EchoFrame opens its files. Without them the OS absorbs the writes into RAM and reports a rate the drive cannot hold. |
| `-L` | Records the latency distribution, including the worst single write. |
| `-D` | Records throughput per interval instead of only an average, so a rate that falls away during the run is visible. |
| `D:\diskspd_probe.dat` | The file to write. Put it on the drive you will be recording to. |

Access is sequential by default, which is what EchoFrame does, so do not add `-r`.

Read the **mean MiB/s** as the rate your drive can hold. Add `-Rxml` for the full
per-interval breakdown, which shows whether the drive starts fast and settles lower;
size your configuration against the settled figure, not the opening one.

### Choosing a configuration

Compare the rate your configuration requires against the rate you measured, and choose
a configuration that matches the drive you will record to. `benchmark_storage` in
[echoframe/matlab/benchmarks/](./echoframe/matlab/benchmarks/) answers the same
question from inside EchoFrame: its `endurance` mode writes every stream the
acquisition writes and reports how many frames pass before the drive falls behind. It
takes longer than the diskspd probe but needs no extra tool.

RF dominates the write. For a regular config in our setup:

| Stream |  Share of the write |
|--------| --------------------|
| RF | 83% |
| BF | 17% |
| PDI | under 1% |
| **Total** | **100%** |

Dropping BF removes a sixth of the load; only dropping RF removes five sixths, so plan carefully.


If your drive cannot carry RF at your frame rate, in order of what costs least:

| Change | Effect |
|--------|--------|
| Reduce `nSamples`, channels, angles or ensemble length | Reduces RF in proportion, and the reconstruction with it |
| Shorten the recording | A recording short enough to finish before the drive falls behind still completes. The per-interval output tells you how long that is |
| Stripe across several NVMe drives, or fit an SSD rated for that sustained write | The only option that keeps full RF at full rate |

---

## Examples<a name="examples"></a>

| Folder | What it shows |
|--------|-----------|
| [echoframe/matlab/examples/logo_simulation/](./echoframe/matlab/examples/logo_simulation/) | end-to-end offline example, no hardware or stored data needed |
| [echoframe/matlab/examples/process_echoframe_data/](./echoframe/matlab/examples/process_echoframe_data/) | replay stored RF or BF data offline from MATLAB |
| [echoframe/matlab/examples/verasonics/](./echoframe/matlab/examples/verasonics/) | live Verasonics acquisition, and processing a saved workspace |
| [echoframe/python/examples/](./echoframe/python/examples/) | the same offline replay from Python |
| [echoframe/matlab/tests/reference/](./echoframe/matlab/tests/reference/) | Fourier beamforming in plain MATLAB, as a reference for the CUDA path |
| [echoframe/matlab/benchmarks/](./echoframe/matlab/benchmarks/) | throughput benchmarks for processing and for storage |

Each folder has its own README with the details.

---

## Repository Layout<a name="repository-layout"></a>

- **echoframe/**
  - **cpp/**: the C/C++/CUDA core in `echoframe/cpp/src/`, including the MEX gateway, the Python bindings, the CLI, and submodules in `libs/`.
  - **matlab/**: the MATLAB side, split by role.
    - **core/**: the library - `imaging/`, `storage/` (writes recordings), `reading/` (reads them back), `verasonics/`, and `setup/` (path setup).
    - **tests/**: the `verify_*` harnesses, plus `data/` (shared test-data generators) and `reference/` (the plain-MATLAB beamformer used as ground truth).
    - **benchmarks/**: throughput benchmarks and the GPU-fit pre-flight check.
    - **examples/**: runnable examples. See [echoframe/matlab/examples/README.md](./echoframe/matlab/examples/README.md).
  - **python/**: **core/** helper modules for reading saved data, and **examples/** for the Python replay path.

- **documentation/**: Doxygen configuration and generated output.

- **build_scripts/**: developer helper scripts — the Windows build, vcpkg setup, and the build-verification harness. See [build_scripts/README.md](./build_scripts/README.md).

- **binaries/**: prebuilt builds, one zip per CUDA/MATLAB combination. See [Plug and Play](#plug-play).

- **docker/**: the Ubuntu/CUDA development image.

- **justfile**: task runner recipes. Stays at the repository root so `just` can find it.

---

## Contributing<a name="contributing"></a>

* Fork → feature branch → PR
* Run `clang‑format -i` on C++ sources *(style file in repo)*

---

## License<a name="license"></a>

EchoFrame is released under the **GNU Lesser General Public License v3.0**.
See [`LICENSE`](LICENSE) for the LGPL text. The LGPLv3 applies the terms of the
GNU General Public License v3.0 with additional permissions, so a copy of the
GPLv3 is included as [`GPLv3.txt`](GPLv3.txt).

© 2022‑2026 EchoFrame Contributors
