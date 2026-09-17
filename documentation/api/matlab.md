# MATLAB core

The MATLAB side of EchoFrame, in `echoframe/matlab/core/`. These functions do not process
data — they build the spec structs and precompute the tables the CUDA core reads,
then hand them to [`echoframe_mex`](mex.md).

Signatures and descriptions below come from the sources. Where a function shows
only a signature, it has no docstring yet.

## Call order

```matlab
% 1. Verasonics only: build the specs from the Verasonics globals
[ProbeSpec, TransmitSpec, ReceiveSpec] = vsx_to_ef_structs(Resource, Trans, TX, Receive, ProbeSpec, TransmitSpec, ReceiveSpec);

% 2. Size the grid and precompute the beamforming tables
[ProbeSpec, ReceiveSpec, ReconSpec] = initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

% 3. Fill in derived fields, cast every field to the type C++ expects
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

% 4. Recording only
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);

% 5. Hand off -- add the four storage specs to record, or none to process only
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
```

Step 1 is Verasonics-only — the simulation examples build the specs directly.
Steps 2 and 3 are not optional: the core reads tables that only exist after
`initialize_image_reconstruction`, and types that only match after
`echoframe_validate_structs`.

## imaging

`initialize_image_reconstruction` sizes the output image from the padding fields:
`nz = nSamplesIQ + extraVoxelsZ` and `nx = nChannels + extraVoxelsX`, each rounded
up to even. It then builds `tgcVector` and delegates to `echoframe_setup_fourier`
for the beamforming tables.

`echoframe_setup_fourier` is where the sampling rate enters the pipeline.
`ReceiveSpec.Fs` sets `dz = ReconSpec.c0 / (Fs * freq_scale)`, where `freq_scale`
is the per-`samplingMode` multiplier, and that sets the axial wavenumber axis,
which produces `delayIndices` and `interpolationWeights`. The core never sees a
sampling frequency — it is baked into these tables. `delayIndices` is converted
to 0-based here, for C++.

The same tables are what `fourier_beamforming_matlab.m` reads, so the plain-MATLAB
reference beamformer and the kernel work from one source rather than two.

:::{warning}
`echoframe_validate_structs` errors only on fields that are **missing or empty**.
Extra fields are ignored — a stale field left on a spec is not caught here, it
simply never reaches the core. `ReceiveSpec.nBuffers` is one of those: it is not in
the validator's expected-field list at all, so it is never checked or cast. It is
read by the Verasonics path (`get_system_parameters` sets
`Resource.RcvBuffer(1).numFrames` from it, and `vsx_to_ef_structs` fills it in when
missing) and by `init_storage`, which caps the RF write queue at it so a stored
frame cannot be overwritten while its write is still running.
:::

```{eval-rst}
.. mat:module:: core.imaging

.. mat:autofunction:: initialize_image_reconstruction

.. mat:autofunction:: echoframe_validate_structs

.. mat:autofunction:: echoframe_setup_fourier
```

## verasonics

`vsx_to_ef_structs` translates the Verasonics globals into EchoFrame specs:
element positions from `Trans.ElementPos`, steering angles and transmit delays
from `TX`, the channel-to-element map from `Trans.Connector` (0-based for C++).
Each `ReceiveSpec` field is guarded by an `isfield` check, so anything the setup
script already filled in is left alone and only the gaps are taken from the
Verasonics structures.

`get_system_parameters` sets the receive buffer geometry, picks
`ReceiveSpec.nChannels` from `Resource.Parameters.numRcvChannels` and
`Trans.numelements`, and maps `samplingMode` to `samplesPerWavelength`.

```{eval-rst}
.. mat:module:: core.verasonics

.. mat:autofunction:: vsx_to_ef_structs

.. mat:autofunction:: get_system_parameters

.. mat:autofunction:: calculate_transmit_apodization

.. mat:autofunction:: calculate_receive_apodization
```

## storage

`init_storage` does three things beyond returning the specs: it creates a
timestamped `recording_<date>` folder under `StorageSpec.folderStoragePath`,
writes `ScanParameters.mat` there with all six spec structs, and builds
`RFStorageSpec` when `StorageSpec.saveRF` is set. It also assigns `StorageSpec`
into the base workspace on the way out.

Buffer length depends on `StorageSpec.preallocateFullFile`: when true the file is
sized for `ExperimentSpec.numberOfPDIsExperiment` buffers, when false for as many
as fit under a 200 GB cap.

`RFStorageSpec` is the fourth output; RF is stored inside `echoframe_mex`, which
takes that spec as an 8th argument to its `init`.

`echoframe_data_root()` returns where this machine writes data: `EF_DATA_ROOT`,
else `D:\EchoFrameData`, else `tempdir`.

```{eval-rst}
.. mat:module:: core.storage

.. mat:autofunction:: init_storage

.. mat:autofunction:: echoframe_data_root

.. mat:autofunction:: clean_empty_files
```

## benchmarks

`check_gpu_memory_fit` is what `benchmark_echoframe.m` uses to skip
configurations that would not fit. Needs `nvidia-smi` on PATH.

```{eval-rst}
.. mat:module:: benchmarks

.. mat:autofunction:: check_gpu_memory_fit
```

## Paths

`ECHOFRAME_PATH` has to be set before any of this works. `setup_echoframe_paths`
is a script (not a function) that sets it; `check_echoframe_path` verifies it and
is called early by the examples.

```{eval-rst}
.. mat:module:: core.setup

.. mat:autofunction:: check_echoframe_path

.. mat:autofunction:: ef_log
```

## Logging

`EF_LOG_LEVEL` gates both the MATLAB prints and the C++ ones. Levels are `quiet`,
`normal`, `verbose`, `trace`; anything else prints at `normal`.

```matlab
setenv('EF_LOG_LEVEL', 'verbose');
```

Both sides read it per call, so a change takes effect without a re-init. The
storage knobs (`EF_STORAGE_VERIFY`, `_PROBES`, `_DELAY_WRITE_MS`, `_STATS`) latch
at `init` instead. Full table in `echoframe/matlab/core/storage/README.md`.

