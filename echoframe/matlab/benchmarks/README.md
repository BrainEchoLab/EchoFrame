# benchmarks/

Throughput benchmarks: one for processing (beamforming + PDI), one for writing to
disk. Both compare measured time against a real-time acquisition budget, so the
question they answer is "can this configuration keep up with the transmit rate".

## Directory Structure

### Files

- **benchmark_echoframe.m**
  - Runs Fourier beamforming + PDI on synthetic noise RF and measures per-PDI
    processing time against the acquisition budget. Also reports the per-stage
    CUDA-event timings the MEX returns. `MODE` picks what it sweeps: `fast` (a
    baseline pair for the stage breakdown), `elaborate` (the full parameter
    sweep), `throughput` (GB/s against RF depth, at 8, 16 and 32 angles) and
    `plan` (the interactive GPU-fit planner, no timing sweep).

- **check_gpu_memory_fit.m**
  - Pre-flight check, not a benchmark itself: estimates peak GPU memory from the
    specs and compares it against free VRAM (queried via `nvidia-smi`, with a PCT
    fallback), returning tuning suggestions when a configuration will not fit.
    `benchmark_echoframe.m` calls it to skip configurations that cannot run, and
    its `'plan'` mode is an interactive slider front-end for it.

- **benchmark_storage.m**
  - Times per-buffer disk-write latency through `echoframe_mex('process')` with
    `startStorage = true`; the `compare` mode also drives the older path, where
    RF went through the separate `storage` MEX. The MEX
    returns its own CUDA-event-timed `bfStorage` value, so beamforming time is
    excluded from the BF figure. `MODE` picks the question: `compare` (RF
    written through the separate storage MEX against RF written inside
    `echoframe_mex`), `endurance` (below), `fast` (one baseline configuration)
    and `elaborate` (the full sweep).
  - `endurance` is the mode to run before planning a recording: how many frames
    pass before the drive stops keeping up. RF forced on, rate reported **per
    interval**, and `ENDURANCE_GB` (400, clamped to half the free space) written
    so the answer is past the drive's write cache. Takes minutes.

- **characterize_storage_race.m**
  - Finds the frame period at which the storage race stops biting: it sweeps a
    pause between frames and counts stored buffers that disagree with what
    `process()` returned, reporting the smallest pause with zero corruption as a
    frame period and rate. Machine- and drive-specific. Needs a build **without**
    the producer slot-ring fix; against a fixed build every row reads 0 corrupt.

## Usage

For `benchmark_echoframe.m`, set `MODE` and run. Needs `ECHOFRAME_PATH`,
`echoframe_mex` built, and `nvidia-smi` on PATH (it queries free GPU memory to
decide whether a configuration fits).

For `benchmark_storage.m`, edit the parameters block and run. Needs both
`echoframe_mex` and the storage MEX built.

`BENCH_DISKS` is the list of volumes under test, and decides what the numbers
describe. Defaults to `echoframe_data_root()`; add `tempdir` to measure the
system drive too. Every configuration runs against each volume, and volumes on
the same drive are collapsed.

A run is clamped to half the free space and to `MAX_ROW_BYTES`, so a large
configuration measures fewer buffers instead of failing in
`preallocateFullFile` with `ERROR_DISK_FULL`. `endurance` keeps only the
free-space clamp.

Anything that writes needs an **elevated MATLAB**: `Handler::init` calls
`assignPriviledges()`, which without `SeManageVolumePrivilege` throws and calls
`std::terminate()`, taking the MATLAB session down.

## Notes

Metrics reported per configuration:

- `time_ms` — mean time for one `process()` call, i.e. one PDI.
- `budget_ms` — `(nTX * nRepeats) / TARGET_TX_RATE`; the acquisition window that
  produced those frames. Processing under this means the target rate is
  sustainable.
- `realtime_ratio` — `budget_ms / time_ms`. At or above 1 is real-time capable.
- `pdi_fps` — Power Doppler images per second.
- `bf_fps` — beamformed frames per second, `nTX * nRepeats / time_s`.
- `gb_per_s` — RF input throughput.

Configurations that would not fit in GPU memory are skipped rather than run, and
their row shows `-` for the timing columns with suggestions printed above the
table.

`benchmark_storage.m` reuses the RF generation pattern from
`../tests/data/generate_echoframe_demo_data.m`: simulate one buffer with
`simulate_logo_rf`, then add fresh int16 noise per iteration so successive buffers
differ.
