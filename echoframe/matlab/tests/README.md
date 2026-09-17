# tests/

Verification harnesses. Each one errors out on any mismatch, so a clean run is a pass.

Each removes its output folder on a pass and keeps it on a failure, so a failed run
can still be inspected. The folders live under `echoframe_data_root()`.

| Script | Needs | What it proves |
|---|---|---|
| `verify_core_headless.m` | nothing (no MEX, no GPU) | `read_header` parses both header versions; `read_stored_RF` round-trips; the spec pipeline sizes `nz`/`nx` as documented, derives `nElements`, casts types and rejects a missing field; `stored_frame_size` reports cropped vs full frame geometry and rejects an inverted ROI; the apodization helpers stay centred and zero weights <= 0.2; and every `verify_*.m` in this folder is named in `run_all_matlab`'s task table, so a harness cannot be added here without being driven. |
| `verify_batch_loading_headless.m` | nothing (no MEX, no GPU) | `batch_loading` yields exactly the windows a single-shot load would, across every window regime and a swept memory budget. |
| `verify_mex_string_args.m` | GPU (no elevation) | A MATLAB `string` where the MEX requires `char` errors instead of taking the process down. Covers `PDISpec.svdMethod` plus `filepath` and `dataType` on all four storage structs — nine poisoned cases behind a `char` control, so a failure is attributable. Every storage save flag is off, so no `Handler` is built. |
| `verify_batch_lossless.m` | GPU, elevated | Batched PDI over `bf_acq.dat` equals single-shot PDI, frame count and values. |
| `verify_batch_lossless_rf.m` | GPU, elevated | Same for the RF path, through the full beamform + PDI pipeline. |
| `verify_batch_storage.m` | GPU, elevated | Re-stored PDI round-trips through `pdi_acq.dat` without loss or reordering. |
| `verify_crop_storage.m` | GPU, elevated | Storage writes the cropped ROI, not the full frame — and the right rectangle. |
| `verify_storage_race.m` | GPU, elevated | Every stored buffer is correct, not just the first — the one the other storage harnesses compare. Two identical runs come out byte-identical, and BF, PDI and the time tags match the memory handed to `storeBuffer`. Each frame gets different RF, without which a torn write still compares equal. `EF_RACE_RINGS=0` runs the unfixed path, where it should fail. |
| `verify_storage_stats.m` | GPU, elevated | The slot rings, and `EF_STORAGE_VERIFY` itself. `EF_STORAGE_DELAY_WRITE_MS` holds writes back so every producer-owned stream is driven past the window on purpose: under the shipped defaults PDI and tags stay clean while BF is caught (its ring is opt-in), rings off catches all three, rings on catches nothing. The middle case is the negative control — without it a clean third case proves nothing. |
| `verify_padding_removal.m` | GPU, elevated | `remove_padding_bytes` strips the per-buffer padding from all four streams without changing the data, and the de-padded copies match what `process()` returned. |
| `verify_batch_large.m` | GPU, elevated, disk | Streams a stack far larger than the budget. Writes `TARGET_STACK_GB` (default **64**) to the temp folder, and needs that much free there. The stack is removed again on a pass. |
| `verify_verasonics_setup.m` | Vantage install (`VERASONICS_VPF_ROOT`) | The Verasonics setup chain builds valid structures for both probes: `L74_demo` / `GE9LD_demo` produce `Trans`/`TX`/`TW`/`Receive`, `vsx_to_ef_structs` converts them, `initialize_image_reconstruction` sizes the grid and axes consistently, and `setup_echoframe_figure` publishes the image and timeline handles the live callback updates. Stops before `VSX`, so nothing is transmitted (`simulateMode = 1`) and no recording is written. |

- [`data/`](./data/) — shared generators that produce the recordings these read.
  `batch_demo_data.m` is the specs-plus-buffers helper the GPU harnesses call;
  `generate_echoframe_demo_data.m` produces a standalone demo dataset.
- [`reference/`](./reference/) — the plain-MATLAB Fourier beamformer, used as ground
  truth when debugging the MEX.

> Every harness that touches storage needs an **elevated MATLAB** — see
> [`../core/storage/`](../core/storage/) for why. Start with
> `verify_batch_loading_headless.m`, which needs neither elevation nor a GPU.
