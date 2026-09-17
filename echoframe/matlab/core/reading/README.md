# core/reading/

Reads a finished recording back off disk. Nothing here is on the live acquisition
path — these run after the fact, offline.

Stored `.dat` files are a header followed by fixed-size buffers, each padded out so
writes stay sector-aligned. Everything here deals with that layout.

## Library

- **`read_header.m`** — parses the header (version 0 with 5 fields, version 1 with 6,
  the extra one being `dataType`) and leaves the file positioned at the first data
  buffer. The only EchoFrame dependency `batch_loading` has.
- **`batch_loading.m`** — handle-class iterator (`forBF` / `forRF`, then
  `hasNext` / `next`) that streams a recording in memory-bounded, lossless batches, so
  a recording larger than host memory can still be processed. Cuts on the PDI window
  grid and carries the overlap between batches, so the frame set is identical to
  loading everything at once.
- **`read_stored_RF.m`** — reads one RF buffer out of `rf_acq.dat` by index.
- **`stored_frame_size.m`** — the per-frame pixel size a stream was actually
  written at. A recording made with `ReconSpec.cropBF` (BF) or `PDISpec.cropPDI`
  (PDI) stored only `croppingROI`, so its frames are smaller than `nz x nx`; this
  returns whichever applies. Used by the inspection scripts and by the offline BF
  replay so they all agree on the geometry.

## Inspection scripts

Standalone, run by hand: set `load_path` to a recording folder (or `cd` there and leave
it `''`) and run.

- **`read_stored_BF.m`** — walks `bf_acq.dat`, rebuilds the complex frames from the
  interleaved I/Q, and shows B-mode next to an SVD-filtered frame.
- **`read_stored_PDI.m`** — walks `pdi_acq.dat` and shows each PDI frame in dB.
- **`read_stored_RF_time_tag.m`** — walks the time-tag stream and plots it.
- **`remove_padding_bytes.m`** — rewrites a recording without the per-buffer padding,
  zeroing the header's padding field. The element type comes from the version 1
  header's `dataType`; version 0 headers predate that field and are assumed to be
  complex single.

> **Known issue — `read_stored_BF.m` needs `nRepeats >= 20`.**
> Its SVD clutter filter hardcodes `S0(1:20,1:20) = 0` (line 76). When a recording has
> fewer than 20 repeats, that assignment *grows* `S0` beyond the size of `U` and `V`,
> and the next line (`BF2 = U*S0*V'`) fails with a matrix-dimension error. Real
> acquisitions use far more than 20 repeats, so this only bites on small synthetic
> recordings. Guarding the index with `min(20, end)` fixes it, but changes what the
> filter does for small ensembles — so it is left as-is deliberately.
