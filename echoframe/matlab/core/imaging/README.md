# core/imaging/

Sizes the output grid and precomputes the beamforming tables. Runs before
`echoframe_mex('init', ...)`; the core reads the tables built here and never sees a
sampling frequency directly.

- **`initialize_image_reconstruction.m`** — the entry point. Derives `nz`/`nx` from
  `nSamplesIQ + extraVoxelsZ` and `nChannels + extraVoxelsX` (each rounded up to
  even), builds `tgcVector` and the axes, then delegates the table build to
  `echoframe_setup_fourier`.
- **`echoframe_setup_fourier.m`** — builds the four tables the CUDA beamformer reads:
  `delayIndices` (0-based for C++), `interpolationWeights`, `frequencyAxis` and
  `planewaveDelays`. `ReceiveSpec.Fs` enters the pipeline here, via
  `dz = c0 / (Fs * freq_scale)`, where `freq_scale` comes from `samplingMode`.
- **`echoframe_validate_structs.m`** — last step before `init`. Derives
  `ReceiveSpec.nElements`, then checks every expected field is present and non-empty
  and casts it to the type C++ expects (`int32` / `single` / `logical` / `char`).

> `echoframe_validate_structs` errors only on fields that are **missing or empty**.
> Extra or stale fields are ignored, so they never reach the core.
