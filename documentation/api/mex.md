# MATLAB (mex)

`echoframe_mex` is the MATLAB gateway to the core. It is a command-dispatch MEX:
the first argument is always a command string, and the remaining arguments depend
on it.

```matlab
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
[PDI, Bmode] = echoframe_mex('process', RF, false);
echoframe_mex('destroy');
```

The spec structs must be passed through `echoframe_validate_structs` first — it
fills in derived fields and casts each field to the type the converter expects.

## Commands

| Command | Inputs (after the command) | Outputs |
|---------|---------------------------|---------|
| `init` | `ReceiveSpec, ReconSpec, PDISpec` — or those plus `BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec[, RFStorageSpec]` | none |
| `process` | `RF, saveFlag` | `PDI, Bmode[, BF][, timings]` |
| `updatePDIthreshold&process` | `RF, saveFlag, threshold` | `PDI, Bmode[, BF][, timings]` |
| `updatePDInoiseThreshold&process` | `RF, saveFlag, lowerThreshold` | `PDI, Bmode[, BF][, timings]` |
| `re-init storage` | `BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec[, RFStorageSpec], ReconSpec, PDISpec` | none |
| `re-init experiment` | `BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec[, RFStorageSpec]` | none |
| `init_pdi_only` | same as `init` | none |
| `process_pdi_only` | `BF, saveFlag` | `PDI` |
| `timings` | none | `timings` struct for the last `process` |
| `storage_stats` | none | per-stream write instrumentation |
| `destroy` | none | none |

Any other command string raises `Unknown command.`

### init

Takes 4 arguments total (no storage), 7 (BF / PDI / time-tag storage) or 8 (those
plus RF); anything else is an error. Storage is enabled by which form you use —
there is no separate flag.

Argument order is positional and fixed:

```matlab
%                 1            2          3         4              5               6                     7
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec)
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec)
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec)
```

`RFStorageSpec` is the 4th output of `init_storage`. Without it RF is not written.

Calling `init` again destroys any existing instance first, so it is safe to
re-init without an explicit `destroy`.

`init` also calls `mexLock()`. See [Lifetime](#lifetime) below.

### process

```matlab
[PDI, Bmode, BF, timings] = echoframe_mex('process', RF, saveFlag);
```

- `RF` — `int16`, laid out as
  `[nSamples * nTransmissions * nRepeats, nChannels]`.
- `saveFlag` — `logical`. When true, and storage specs were given to `init`, the
  BF / PDI / RF-time-tag streams are written to disk by the core, and RF with
  them.

Outputs, requested by how many you ask for:

| # | Output | Size | Type |
|---|--------|------|------|
| 1 | `PDI` | `[nz, nx, num_ensembles]` | single |
| 2 | `Bmode` | `[nz, nx]` | single |
| 3 | `BF` | `[nz, nx, nRepeats]` | complex single |
| 4 | `timings` | struct | double, seconds |

The 3rd and 4th are only computed if requested, so ask for the two you need in a
live loop.

The `timings` struct has one field per stage, in seconds: `rf_transfer`,
`rf_formatting`, `beamforming`, `bf_formatting`, `pdi_processing`,
`pdi_transfer`, `bf_storage`, `pdi_storage`, `total`. These come from CUDA
events, so they measure GPU work rather than wall clock.

### updatePDIthreshold&process

Identical to `process`, with the new SVD threshold as a 4th input:

```matlab
[PDI, Bmode] = echoframe_mex('updatePDIthreshold&process', RF, saveFlag, threshold);
```

`threshold` must be `single`. The threshold is applied before processing, and
persists for later `process` calls.

### updatePDInoiseThreshold&process

The same shape, but it sets the **lower (noise)** threshold rather than the upper
(tissue) one:

```matlab
[PDI, Bmode] = echoframe_mex('updatePDInoiseThreshold&process', RF, saveFlag, lowerThreshold);
```

`lowerThreshold` must be `single`, and like the upper threshold it persists for
later `process` calls. It is a fraction of `ensembleSize`, converted internally to
an eigenvalue index (`round(lowerThreshold * ensembleSize)`).

Only the `'Covariance'` SVD method uses it; under `'Full'` it is ignored. The
corresponding `PDISpec.lowerThreshold` field is **optional** at `init` — when
absent it defaults to `0`, so specs and `ScanParameters.mat` files written before
the field existed still initialise.

### re-init storage vs re-init experiment

Both take the storage specs in the same positions.

```matlab
%                            1               2               3                     4              5          6
echoframe_mex('re-init storage',    BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec, ReconSpec, PDISpec)
echoframe_mex('re-init experiment', BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec)
```

`ReconSpec` and `PDISpec` sit at 5 and 6, after the RF slot.

The difference is what else gets rebuilt. `re-init experiment` swaps the storage
specs only — the usual case for starting a new recording with the same
acquisition. `re-init storage` additionally re-reads `ReconSpec` when
`BFStorageSpec.crop` is set, and re-reads `ReconSpec` and `PDISpec` when
`PDIStorageSpec.crop` is set, so it is the one to use when cropping changes.
Those two extra arguments are only read in those branches.

### init_pdi_only / process_pdi_only

For running just the PDI stage on beamformed data that came from somewhere else
— replaying stored BF, for example.

```matlab
echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec);
PDI = echoframe_mex('process_pdi_only', BF, saveFlag);
```

`BF` must be complex single. `process_pdi_only` returns PDI only, sized
`[nz, nx, num_ensembles]`.

### timings / storage_stats

Both take no arguments beyond the command and require exactly one output, and
both error when nothing is initialised.

```matlab
t = echoframe_mex('timings');        % same struct 'process' returns as its 4th output
s = echoframe_mex('storage_stats');
```

`timings` re-reads the last `process` call's stage times.

`storage_stats` returns one field per stream — `rf`, `bf`, `pdi`, `timetag` —
each a struct:

| Field | Meaning |
|-------|---------|
| `saving` | whether this stream is written |
| `writes` | writes completed |
| `buffersQueued` | buffers handed to the writer |
| `latencyMeanMs` / `latencyMaxMs` | write-completion latency |
| `peakInFlight` | most writes outstanding at once |
| `queueCapacity` | queue size |
| `slotRingDepth` | staging slots; 0 when writing from the caller's buffer |
| `blockedTotalMs` / `blockedMaxMs` | time `process` spent waiting for queue room |
| `verified` / `corrupted` | buffers checked, and mismatches, under `EF_STORAGE_VERIFY` |

### destroy

Frees the core and unlocks the MEX. Both are guarded, so calling `destroy`
without a prior `init` is a no-op rather than an error — but see below.

## Lifetime

`init` calls `mexLock()`, which keeps the library resident between calls.

While an instance is live, **`clear mex` alone does not free the core**: the lock
stops MATLAB running the atExit cleanup. Call `destroy` first, then `clear mex`:

```matlab
echoframe_mex('destroy')
clear mex
```

The instance handle is global to the MEX, not per-caller. So `destroy` from any
script tears down whatever instance is live — worth knowing before adding it to
an analysis script that never called `init`.

## Internals

The conversion layer between MATLAB's `mxArray` structs and the native specs.

```{doxygennamespace} MexToNative
:members:
```
