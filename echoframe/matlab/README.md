# echoframe/matlab/

The MATLAB side of EchoFrame: builds and validates the spec structs, precomputes the
reconstruction tables the CUDA core reads, manages storage, and integrates with
Verasonics Vantage. None of it processes data — that is `echoframe_mex`'s job.

## Layout

| Folder | What it holds |
|---|---|
| [`core/`](./core/) | The library. `imaging/`, `storage/` (writes recordings), `reading/` (reads them back), `verasonics/`, `setup/`. |
| [`tests/`](./tests/) | The `verify_*` harnesses, plus `data/` generators and the `reference/` beamformer. |
| [`benchmarks/`](./benchmarks/) | Throughput benchmarks and the GPU-fit pre-flight check. |
| [`examples/`](./examples/) | Runnable demos — start with `logo_simulation/`. |
| [`run_all_matlab.m`](./run_all_matlab.m) | Driver that runs every script above in sequence and prints a PASS/FAIL/SKIP table. |

Each folder documents its own contents; this page is the index plus the spec-struct
reference below.

## Getting started

Run [`core/setup/setup_echoframe_paths.m`](./core/setup/setup_echoframe_paths.m)
once per session, then
[`examples/logo_simulation/logo_simulation.m`](./examples/logo_simulation/logo_simulation.m)
to confirm the path and the MEX are working.

To run everything at once instead, use
[`run_all_matlab.m`](./run_all_matlab.m). It walks the tests, examples and
(optionally) the benchmarks in order, runs each in its own workspace so their
`clear` cannot disturb the sweep, catches failures instead of aborting, and
prints a PASS/FAIL/SKIP summary plus a diary log. Scripts that write a recording
need an **elevated MATLAB**; without it the driver skips that whole group rather
than let the storage Handler call `std::terminate()` and take MATLAB with it.

The sweep covers the Verasonics side too, on a machine with Vantage installed.
The two scripts it leaves out are the two that never return on their own:
`echoframe_acquisition_start.m` (ends in `VSX`, which blocks in the Verasonics
GUI until an operator closes it) and `ef_external_process.m` (a per-frame
callback, not a script). Everything they set up is still covered — see
[`tests/verify_verasonics_setup.m`](./tests/verify_verasonics_setup.m).

Note that EchoFrame functions resolve **by basename, not by folder** — see
[`core/setup/`](./core/setup/) for what that means when moving or naming
files.

## Spec structures

The fields below are the public API consumed by `echoframe_mex`. Any field marked **derived** is filled in by one of the helpers above (typically `initialize_image_reconstruction.m`); everything else is set by the user.

### ProbeSpec

| Field             | Type     | Description                                                       |
|-------------------|----------|-------------------------------------------------------------------|
| `pitch`           | `double` | Distance between transducer elements [m].                         |
| `Fc`              | `single` | Centre frequency of the transducer elements [Hz].                 |
| `nElements`       | `int32`  | Number of transducer elements in the probe.                       |
| `elementPosition` | `single` | Per-element [x, y, z, azimuth, elevation] (Verasonics layout).    |

### TransmitSpec

| Field            | Type     | Description                                                       |
|------------------|----------|-------------------------------------------------------------------|
| `c0`             | `double` | Speed of sound used by the transmit model [m/s].                  |
| `type`           | `char`   | Transmit type (currently only `'planewave'`).                     |
| `steer`          | `single` | Steering angle per transmission [degrees].                        |
| `apodization`    | `double` | Per-element transmit apodization vector.                          |
| `transmitDelays` | `double` | Per-element transmit delays per transmission [s].                 |

### ReceiveSpec

| Field                  | Type      | Description                                                       |
|------------------------|-----------|-------------------------------------------------------------------|
| `nSamples`             | `int32`   | RF samples per channel per transmission (post-resample).          |
| `nSamplesIQ`           | `int32`   | IQ samples per channel per transmission (= `nSamples`/2 typically).|
| `nTransmissions`       | `int32`   | Number of transmissions per ensemble (angle compounding).         |
| `nRepeats`             | `int32`   | Number of repeated ensembles (slow time / Doppler).               |
| `nChannels`            | `int32`   | Number of receive channels.                                       |
| `nElements`            | `int32`   | Mirrors `ProbeSpec.nElements` (set by `echoframe_validate_structs`).        |
| `channel2ElementMap`   | `int32`   | Channel → element mapping (0-based).                              |
| `Fs`                   | `single`  | RF sampling frequency [Hz]. Sets `dz` / `frequencyAxis` in the reconstruction setup. |
| `samplingMode`         | `char`    | `'BS50BW'`, `'BS100BW'`, or `'NS200BW'`.                          |
| `samplesPerWavelength` | `int32`   | Derived from `samplingMode`.                                      |
| `nBuffers`             | `int32`   | Number of host buffers.                                           |

### ReconSpec

| Field                                    | Type                | Description                                              |
|------------------------------------------|---------------------|----------------------------------------------------------|
| `bfDataType`                             | `char`              | Beamformed data type (`'complex single'`).               |
| `getBF`                                  | `logical`           | Return complex BF output from `process()`.               |
| `getPDI`                                 | `logical`           | Return PDI output from `process()`.                      |
| `filterFrequencies`                      | `logical`           | Apply optional frequency filter.                         |
| `cropBF`                                 | `logical`           | Crop BF output to `croppingROI`.                         |
| `croppingROI`                            | `int32`             | `[zTop; zBottom; xLeft; xRight]`, **0-based inclusive** (used when `cropBF`/`cropPDI` is true). Indexing the full frame in MATLAB needs `+1`. |
| `extraVoxelsZ`                           | `int32`             | z padding for Fourier reconstruction.                    |
| `extraVoxelsX`                           | `int32`             | x padding (lateral oversampling).                        |
| `c0`                                     | `single`            | Speed of sound used in reconstruction [m/s].             |
| `nz` (derived)                           | `int32`             | z-pixels of the reconstructed grid.                      |
| `nx` (derived)                           | `int32`             | x-pixels of the reconstructed grid.                      |
| `imageSize` (derived)                    | `int32`             | `[nz nx]`.                                               |
| `xAxis` / `zAxis` (derived)              | `double`            | Pixel coordinates [mm].                                  |
| `tgcVector` (derived)                    | `single`            | Time-gain compensation vector.                           |
| `delayIndices` (derived)                 | `int32`             | Fourier-beamforming delay indices.                       |
| `interpolationWeights` (derived)         | `complex single`    | Fourier-beamforming interpolation weights.               |
| `frequencyAxis` (derived)                | `single`            | Frequency axis used by the reconstruction.               |
| `planewaveDelays` (derived)              | `single`            | Per-transmit plane-wave delays.                          |
| `nSamplesCropTop`/`nSamplesCropBot`      | `int32`             | Cropping bounds in z (used when `cropBF=true`).          |
| `nChannelsCropLeft`/`nChannelsCropRight` | `int32`             | Cropping bounds in x (used when `cropBF=true`).          |

### PDISpec

| Field          | Type      | Description                                                       |
|----------------|-----------|-------------------------------------------------------------------|
| `ensembleSize` | `int32`   | Slow-time samples per PDI estimate.                               |
| `threshold`    | `single`  | Upper (tissue) SVD threshold — fraction of `ensembleSize` rejected as clutter. |
| `lowerThreshold` | `single` | *Optional.* Lower (noise) SVD threshold, same units. Absent ⇒ `0`. Used only by `svdMethod = 'Covariance'`; settable at runtime via `echoframe_mex('updatePDInoiseThreshold&process', …)`. |
| `shiftSize`    | `int32`   | Slow-time stride between successive PDIs.                         |
| `cropPDI`      | `logical` | Apply the same cropping ROI as `cropBF`.                          |
| `svdMethod`    | `char`    | `'Covariance'` (default) or `'Full'`.                             |

## Cropping

`cropBF` / `cropPDI` are **storage-only**. The crop is a separate device-side copy
(`BF2OutputType` writes `d_bfCropped`, `BF_formatter.h`), so `process()` still
returns the full `nz x nx` frame — a live acquisition with `cropBF = true`
displays whole frames while writing cropped ones to disk. What changes is the
`.dat`: each stored frame is `croppingROI` instead of the full grid.

`croppingROI` is `[zTop; zBottom; xLeft; xRight]`, **0-based and inclusive** — the
same convention the C++ kernel reads. Slicing the full frame in MATLAB therefore
needs `+1`: `rows = (roi(1)+1):(roi(2)+1)`, `cols = (roi(3)+1):(roi(4)+1)`.

Reading and re-processing a cropped recording splits across three groups of
scripts. Nothing does all of it — producing cropped data and processing it are
separate steps:

| Role | Scripts |
|---|---|
| **Store cropped** | [`tests/verify_crop_storage.m`](./tests/verify_crop_storage.m) and [`examples/logo_simulation/crop_demo_storage.m`](./examples/logo_simulation/crop_demo_storage.m) — the only two that set the flags true. Every other script hardcodes `false`; flip them in your own acquisition script (e.g. `echoframe_acquisition_start.m`) to record cropped. |
| **Process cropped** | [`examples/process_echoframe_data/process_echoframe_bf_to_pdi_data.m`](./examples/process_echoframe_data/process_echoframe_bf_to_pdi_data.m) — the only one. It sizes frames from what was written, re-points `nz`/`nx` and the display axes at the ROI, and clears both crop flags so nothing crops a second time. The RF replay (`process_echoframe_data.m`) is unaffected: RF is never cropped. |
| **Read / display cropped** | [`core/reading/read_stored_BF.m`](./core/reading/read_stored_BF.m) and [`read_stored_PDI.m`](./core/reading/read_stored_PDI.m). They inspect and plot; they do not re-process. |

All of them size frames through
[`core/reading/stored_frame_size.m`](./core/reading/stored_frame_size.m), which
takes the crop flag for the stream being read — `ReconSpec.cropBF` for
`bf_acq.dat`, `PDISpec.cropPDI` for `pdi_acq.dat`, since the two are cropped
independently.

Note that PDI computed from a cropped recording is **not** the same as PDI
computed on the full frame and then cropped. The SVD clutter filter's singular
vectors depend on the spatial extent it is given, so a smaller ROI yields a
different decomposition. Cropping to save disk therefore changes the PDI result,
not just the file size.

## Typical session

1. `setup_echoframe_paths` (or set `ECHOFRAME_PATH` and `addpath(genpath(ECHOFRAME_PATH))` directly).
2. Build `ProbeSpec`, `TransmitSpec`, `ReceiveSpec`, `ReconSpec`, `PDISpec` (see the `examples/` folder in this directory for templates).
3. Acquire (or simulate) RF — populates the runtime fields of `ReceiveSpec`.
4. `initialize_image_reconstruction` — derives reconstruction tables and `nz`/`nx`.
5. (Optional) `check_gpu_memory_fit` — confirms the configuration fits in VRAM.
6. `echoframe_validate_structs` — final type cast + field check.
7. If saving is enabled, call `init_storage(...)` to build `BFStorageSpec`, `PDIStorageSpec`, `RFTimeTagStorageSpec`, and `RFStorageSpec`, then pass them to `echoframe_mex('init', ...)`.
8. Otherwise call `echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec)`.
9. Per frame: `[PDI, Bmode, BF] = echoframe_mex('process', RF, false);`.
10. `clear mex` (or `echoframe_mex('destroy')`) to release CUDA resources.
