# core/storage/

Opens a recording and keeps its `RecordingInfo.txt` honest while data is being
written. The actual buffer writes happen inside `echoframe_mex` / the `storage` MEX,
not here.

- **`echoframe_data_root.m`** — where this machine puts EchoFrame data, so
  recordings, benchmark output and generated test data all land in one
  configurable place instead of a drive letter repeated across a dozen scripts.
  Resolves `EF_DATA_ROOT` (created if missing), else `D:\EchoFrameData`, else
  `tempdir`. RF is why it matters: a system drive rarely has room for a probe
  configuration's per-frame writes.
- **`init_storage.m`** — the entry point. Given a high-level `StorageSpec` plus the
  acquisition specs, derives the per-stream `BFStorageSpec`, `PDIStorageSpec`,
  `RFTimeTagStorageSpec` and `RFStorageSpec` (buffer sizes, data types, file paths),
  creates the timestamped `recording_*` folder and saves `ScanParameters.mat`.
  Command is `'init'` for a new recording or `'re-init'` for another on the same
  acquisition.
- **`write_recording_info_start.m`** — stamps folder-creation time, immediately, so it
  survives a crash mid-acquisition.
- **`mark_first_write.m`** — stamps when the first sample actually reached disk. Cheap
  to call per frame: it does file I/O only once per recording.
- **`finalize_recording_info.m`** — stamps the end time and the duration.
- **`track_recording_saving.m`** — called once per acquisition frame with the current
  folder and whether saving is on. Drives the two stamps above off the rising and
  falling edges, and closes out the previous recording if the folder changes.
- **`clean_empty_files.m`** — deletes `recording_*` folders that never received data,
  e.g. when an acquisition was aborted before any buffer flushed.
- **`echoframe_cleanup_dir.m`** — removes a test output folder, retrying briefly and
  warning rather than erroring. Used by the `verify_*` harnesses and the benchmarks,
  which would otherwise keep every run's recording; call it after
  `echoframe_mex('destroy')`, since `clear mex` leaves the `mexLock`'d module holding
  the files open.
- **`report_storage_demand.m`** — run before an acquisition. Prints the per-frame size
  of each saved stream and the sustained write rate the configuration needs, so a rate
  the drive cannot hold is visible before anything is written.
- **`echoframe_disk_monitor.m`** — the pre-run disk-space check and the live usage bar.
  `'check'` reports whether the recording fits and sizes the bar's projection, `'start'`
  adds the bar to the current figure, `'update'` refreshes it from the acquisition loop
  (self-throttled), and `'verify'` re-checks before saving begins.
- **`check_storage_headroom.m`** — run after an acquisition, before `destroy`. Reports
  per-stream write latency, how close each queue came to full, and how much
  back-pressure the loop felt, and says whether the queue depth needs raising.

The Verasonics acquisition example calls all three, and `ef_external_process` prints one
timing line per frame against the acquisition period — see
[`../../examples/verasonics/functional_ultrasound_imaging/`](../../examples/verasonics/functional_ultrasound_imaging/).

## Write queues and slot rings

Storage does not copy: `storeBuffer` hands its pointer to an async write, and the
disk reads that memory until the write completes. If the producer refills the buffer
first, the record on disk is two frames mixed, and the file gives no sign of it.

PDI and time-tags avoid this with a slot ring (on by default). BF can use one too
but is off by default -- its slot is a whole beamformed frame. RF has no slot ring
at all: staging it cost a whole frame per slot, and it is written straight out of
the Verasonics receive ring, so it relies on that ring instead:
`RFStorageSpec.numberOfBuffers` must not exceed `ReceiveSpec.nBuffers`, which
`init_storage` handles by deriving one from the other. A deeper queue does not make
the drive faster — it only lets a backlog grow past what the ring protects.

Setup scripts must set `Resource.RcvBuffer(1).numFrames = ReceiveSpec.nBuffers`, or
the real ring depth is whatever Vantage defaults to. `get_system_parameters.m` does
this for the shipped setups.

## Environment variables

Read at every `echoframe_mex('init')` and `'re-init'`, so they can be changed within a
MATLAB session. They persist for that session; clear with `setenv('NAME','')`.

`EF_LOG_LEVEL` is the exception: it is re-read at the top of **every** MEX call, so
raising it mid-session takes effect on the next print rather than at the next init.
The rest configure a recording that is already open, which is why they latch.

| Variable | Default | Effect |
| --- | --- | --- |
| `EF_LOG_LEVEL` | `normal` | How much the library prints: `quiet`, `normal`, `verbose`, `trace` (or 0-3). `normal` is banners and end-of-recording summaries, `verbose` adds a line per acquisition frame, `trace` adds per-stage timings and per-frame storage deltas. One variable covers both sides — MATLAB's `ef_log` reads the same values. Re-read per call, not at init. |
| `EF_STORAGE_SLOT_RINGS_PDI` | on | Rotate PDI output through a slot ring. |
| `EF_STORAGE_SLOT_RINGS_TIMETAG` | on | Same for time-tags. |
| `EF_STORAGE_SLOT_RINGS_BF` | off | Same for BF. Costs one BF frame per slot, so it is opt-in. |
| `EF_STORAGE_SLOT_RINGS` | — | Sets all three; per-stream flags still win. |
| `EF_RF_STORAGE_BUFFERS` | from `nBuffers` | RF write queue depth. Raise only together with `ReceiveSpec.nBuffers`. |
| `EF_STORAGE_STATS` | on | Print the write summary when a file closes. |
| `EF_STORAGE_VERIFY` | off | Re-check each source buffer on write completion and report any that changed. |
| `EF_STORAGE_VERIFY_PROBES` | 64 | Chunks sampled per buffer by that check. |
| `EF_STORAGE_DELAY_WRITE_MS` | 0 | Hold writes back to widen the race window. **Testing only.** |
| `EF_DEBUG_RF_PTR` | off | Log the RF data pointer per frame. |
| `EF_PIN_RF` | off | Page-lock each incoming RF buffer on first use, cutting the host-to-GPU transfer time (`timings.rf_transfer`). **Only set this when the caller keeps its RF buffers alive for the whole session**, as a Verasonics acquisition does with `Resource.RcvBuffer`. A script that allocates RF per call must leave it off: the lock would outlive the array, and a later transfer from the reused address fails. Not a storage knob. |

`check_storage_headroom` reports the results after a run. `../../cpp/libs/Storage/tests/write_stats_check.cpp`
checks the knobs are re-read and the verifier detects an overwrite; it needs no
MATLAB or GPU.

> **On Windows, storage needs an elevated MATLAB — and failing that kills the
> session.** `Handler::init` calls `assignPriviledges()` (`Handler.t.hpp:37`) before
> it opens or extends any file, and independently of `preallocateFullFile`. If the
> process cannot obtain `SE_MANAGE_VOLUME_NAME` (`SeManageVolumePrivilege`), the
> handler prints the error and calls `std::terminate()`, which takes MATLAB down
> with it — you do not get a catchable MATLAB error.
>
> Setting `preallocateFullFile = false`, or `EF_NO_PREALLOC=1`, does **not** lift the
> requirement. On Linux `assignPrivileges` is a no-op, so this does not apply there.

To read a finished recording back, see [`../reading/`](../reading/).
