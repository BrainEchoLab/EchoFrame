# logo_simulation/

An end-to-end run with no hardware and no stored data. RF is simulated from a
phantom built out of the EchoFrame logo, then beamformed and turned into a Power
Doppler image on the GPU through the MEX interface. B-mode and PDI are shown side
by side.

This is the example to run first: if it works, `ECHOFRAME_PATH` and the MEX are
set up correctly.

## Directory Structure

### Files

- **logo_simulation.m**
  - The script to run. Sets the probe / transmit / receive / recon / PDI
    parameters, gets the RF, calls `echoframe_mex('init')` and `('process')`,
    and displays the two images.

- **simulate_logo_rf.m**
  - Builds the scatterer phantom from the logo image and simulates the RF each
    element receives, using the Fourier method. Returns int16 RF in the layout
    EchoFrame expects, plus the probe / transmit / receive specs filled in with
    the derived fields (element positions, transmit delays, nSamples, and so
    on). Takes a `sim_method` argument: `'fast'` (default, vectorised) or
    `'slow'` (per-sensor, easier to read).

- **crop_demo.m**
  - Shows what `ReconSpec.croppingROI` selects. Beamforms the logo buffer once,
    then draws the full B-mode and PDI with several ROIs outlined and cut out
    side by side. Nothing is written to disk, so it needs no elevation. Writes
    PNGs to `fullfile(tempdir, 'echoframe_crop_demo')`.

- **crop_demo_storage.m**
  - The same ROI, but end to end through the real storage layer: the buffer is
    stored twice, once with `cropBF`/`cropPDI` false and once true, and both
    `.dat` files are read back with `read_header` + `stored_frame_size` and
    compared element-wise. **Needs an elevated MATLAB** - `Handler::init` calls
    `assignPriviledges()` before opening any file and calls `std::terminate()`
    if it fails, which takes MATLAB down with it. Writes PNGs and both
    recordings to `fullfile(tempdir, 'echoframe_crop_demo_storage')`.

- **echoFrame_logo.png**
  - The image the phantom is built from.

- **logo_rf.mat** *(not in git; created on the first run)*
  - Cached RF plus the specs it was simulated with. Delete it any time — the next
    run re-simulates it, identically (`simulate_logo_rf` seeds `rng(0)`).

## Usage

Edit the `%% Parameters` block at the top of `logo_simulation.m`, then run it.

`crop_demo` and `crop_demo_storage` are standalone - run them directly. Both set
their own specs and simulate their own RF, so they ignore `logo_rf.mat`.
`crop_demo_storage` must be started from an elevated MATLAB.

The first run simulates the RF (~25 s) and saves it to `logo_rf.mat`. Every run
after that loads the cache instead — `LOAD_SAVED_RF` is set from
`isfile(RF_FILE)`, so this is automatic. To re-simulate, delete `logo_rf.mat` or
set `LOAD_SAVED_RF = false` by hand; either overwrites the cache.

### Which parameters actually take effect

`ProbeSpec`, `TransmitSpec` and `ReceiveSpec` are used **twice** — once by
`simulate_logo_rf` to synthesise the RF, and again by
`initialize_image_reconstruction` and `echoframe_mex` to reconstruct it. The
beamforming tables come from `pitch`, `Fc`, `c0`, `steer` and `Fs`; the array shape
from `nSamples` / `nChannels` / `nTransmissions`. Both uses must agree, so a cached
RF set has to be processed with the specs it was made from.

That means **editing the probe / transmit / receive parameters has no effect while
`logo_rf.mat` exists** — the loaded specs win. Any edited field that is being
overridden is listed by name in a warning. Delete the cache to make your values
take effect.

`ReconSpec` and `PDISpec` are reconstruction-side only and always take effect.
`ReconSpec.c0` and `PDISpec.ensembleSize` / `shiftSize` are re-derived from the
loaded specs **only if you left them at their default coupling** (`= TransmitSpec.c0`
and `= ReceiveSpec.nRepeats`); a value you set deliberately is kept. Asking for an
`ensembleSize` longer than the cached recording's `nRepeats` is an error rather than
a silent reset.

## Notes

- `TransmitSpec.steer` sets the plane-wave angles; its length feeds
  `ReceiveSpec.nTransmissions`.
- `PDISpec.threshold` is the fraction of the ensemble removed as clutter.
- `simulate_logo_rf` seeds the RNG (`rng(0)`), so the scatterer layout and noise
  are the same every run.
- `'BS67BW'` is not supported by the simulator and raises an error.
