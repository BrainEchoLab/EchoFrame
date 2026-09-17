# process_echoframe_data/

Replaying stored data through the pipeline, offline, from MATLAB or Python. A
generator is included so you have a dataset to read without needing hardware.

The point these examples make: the offline PDI ensemble does not have to match
the per-buffer slow-time count used at acquisition. The stored buffers are a long
slow-time stack, and the MEX is initialised with whatever `PDISpec` you choose.
So `ensembleSize`, `shiftSize`, `threshold` and `svdMethod` can be changed
without re-acquiring.

## Directory Structure

- **process_echoframe_data.m**
  - Reads `ScanParameters.mat` + `rf_acq.dat`, replays the RF through
    `echoframe_mex` (full beamform + PDI), and renders B-mode + PDI. Streams the
    recording in memory-bounded batches (see [Batch loading](#batch-loading)).

- **process_echoframe_bf_to_pdi_data.m**
  - Reads `ScanParameters.mat` + `bf_acq.dat` and runs only the PDI stage
    (`echoframe_mex('process_pdi_only')`) on already-beamformed data. Same
    memory-bounded batch streaming, with optional re-storage of the PDI.

### Elsewhere

- The dataset generator, **`generate_echoframe_demo_data.m`**, lives in
  [`../../tests/data/`](../../tests/data/). It simulates one logo RF buffer with
  `simulate_logo_rf`, then writes `N_BUFFERS` buffers through EchoFrame's storage
  path, each with fresh additive noise so successive frames differ — enough for
  SVD-based PDI to separate the static "tissue" from the varying "blood". Writes
  `ScanParameters.mat`, `rf_acq.dat` and `bf_acq.dat`.
- The batch-loader verification harnesses (`verify_batch_*.m`, `batch_demo_data.m`)
  live in [`../../tests/`](../../tests/).
- The Python equivalents of these scripts —
  `process_echoframe_offline.py` and `process_pdi_custom_windows.py` — live in
  [`../../../python/examples/`](../../../python/examples/).

## Batch loading

Both MATLAB consumer scripts stream the stored `.dat` through **`batch_loading`**
(`echoframe/matlab/core/reading/batch_loading.m`). The batched PDI frame set is identical
to a single-shot load — no frames dropped at batch boundaries, for any
`ensembleSize`/`shiftSize`. If the whole recording fits within `MEMORY_BUDGET_GB`
it is loaded in one call instead.

`MEMORY_BUDGET_GB` bounds one batch's host slab: the working set stays within the
budget (the slab is filled in place, not doubled), so you can set it to a large
fraction of your free RAM — leaving headroom for the `process` call's GPU and output
allocations. Lower it if you hit a GPU out-of-memory error. See `batch_loading.m`
for the window-grid, overlap-carry and sizing details.

```matlab
loader = batch_loading.forBF(fileID, HeaderSpec, M, ens, shift, MEMORY_BUDGET_GB);
ReceiveSpec.nRepeats = int32(loader.slabLen);   % constant across batches
% ... validate + init the MEX once ...
while loader.hasNext()
    slab = loader.next();
    PDI  = echoframe_mex('process_pdi_only', slab, saveFlag);
end
```

`forBF` streams the BF stack (a unit is one column of `M` complex singles); `forRF`
streams the RF stack (a unit is one repeat of `rowsPerRepeat x nChannels` int16).

## Usage

Run [`../../tests/data/generate_echoframe_demo_data.m`](../../tests/data/generate_echoframe_demo_data.m)
first to produce a dataset, then point one of the two scripts here at the output
folder. Edit the parameters block at the top of whichever script you run.

Both need `ECHOFRAME_PATH` and `echoframe_mex`. The generator also needs the storage
MEX and, because it writes a recording, an elevated MATLAB — see
[`../../core/storage/`](../../core/storage/).

## Notes

In both consumer scripts here the `PDISpec` block is set *before* the load and is
preserved through it: only the other spec structs come from
`ScanParameters.mat`. That is what lets you re-run with different PDI parameters
against the same recording.
