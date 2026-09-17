# verasonics/

Verasonics Vantage integration: a live acquisition that processes each RF buffer
as it arrives, and a script that processes a workspace saved from a stock
Verasonics example.

## Directory Structure

### functional_ultrasound_imaging/

A live plane-wave acquisition with B-mode + PDI displayed as it runs, and
RF / BF / PDI / RF-time-tag written to disk.

- **echoframe_acquisition_start.m**
  - The script to run. Activates Vantage, picks a probe setup, converts the
    Verasonics structures into EchoFrame specs, initialises reconstruction and
    storage, and hands off to `VSX`.

- **setup/L74_demo.m**
  - Plane-wave setup for the L7-4. This is the default: the L7-4 is a stock
    Verasonics probe, so it is the one most people can run.

- **setup/GE9LD_demo.m**
  - The same for the GE 9LD, which needs the GE connector. Commented out in
    `echoframe_acquisition_start.m`; swap the two lines to use it.

- **setup/setup_echoframe_figure.m**
  - Creates the live B-mode + PDI axes and publishes their handles to the base
    workspace.

- **process/ef_external_process.m**
  - The Verasonics external-process callback. Runs for each RF buffer: forwards
    it to `echoframe_mex`, stores the RF, and updates the image handles.

### process_verasonics_workspace/

- **process_verasonics_workspace.m**
  - Loads a `.mat` workspace saved from a Verasonics example (`Resource`, `TW`,
    `Trans`, `TX`, `Receive`, `RcvData`), converts it into EchoFrame's specs,
    beamforms the recorded RF, and shows the B-mode result. No live hardware
    needed.

## Usage

`STORAGE_PATH` now defaults to `echoframe_data_root()`, which resolves to
`EF_DATA_ROOT` when that is set, else `D:\EchoFrameData` on the acquisition
machines, else `tempdir`. Set it explicitly only to write somewhere else.

For the live acquisition: edit `STORAGE_PATH` and the parameters at the top of
`echoframe_acquisition_start.m`, pick a probe setup script, and run. Needs a
Vantage installation with `VERASONICS_VPF_ROOT` set, plus `ECHOFRAME_PATH` and
`echoframe_mex`.

To capture a workspace for `process_verasonics_workspace.m`:

1. Run a Verasonics plane-wave example (for example `SetUpGE9LDFlashAngles.m`),
   with the Receive set to `'BS100BW'` and `startDepth = 1`.
2. Hit "Freeze" and close the Verasonics console.
3. Save `Resource`, `TW`, `Trans`, `TX`, `Receive` and `RcvData` to a `.mat`.

Then point `data_path` at it and run.

## Notes

- VSX finds the acquisition workspace through a base variable named `filename`.
  The name is load-bearing — VSX prompts for a file interactively if it is
  missing. VSX also clears the base workspace and reloads it from that `.mat`,
  which is why the figure handles have to be saved into it.
- Each recording folder gets a `RecordingInfo.txt` with the folder-created,
  first-sample-stored ("started") and last-sample-stored ("ended") times at
  millisecond resolution. "ended" is taken from `rf_acq.dat`'s last-write time
  (RF is the primary recording).
  - This last-write time is read from the filesystem, so its resolution depends
    on the volume: **NTFS keeps sub-second timestamps, so you get true
    milliseconds; FAT/exFAT round the modified time to 2 s**, which makes the
    RF-derived "ended" coarser on those volumes. The wall-clock `created` and
    `started` stamps are always full-resolution regardless of filesystem. Record
    to an NTFS disk if you need millisecond "ended" accuracy.
