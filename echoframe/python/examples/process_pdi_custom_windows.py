"""
process_pdi_custom_windows - Recompute fUSI power Doppler from stored BF, offline,
with analysis-time SVD windows.

Reads a stored beamformed stack (bf_acq.dat + ScanParameters.mat) and recomputes
power Doppler with temporal windows chosen at analysis time, independent of the
acquisition. It resamples the slow-time series to `NEWDT_MS`, takes a `WINDOW_MS`
SVD window at each step (dropping the first `NSVDDROP` singular values as the
tissue clutter filter), and averages |signal|^2 to a power-Doppler frame. Windows
overlap when WINDOW_MS > NEWDT_MS.

Unlike process_echoframe_offline.py (which drives the CUDA core with a fixed
PDISpec), this is a pure-NumPy offline reanalysis: no GPU, no MEX, and the
window/step/SV-drop can be swept without re-acquiring or re-beamforming. It reads
older recordings too: it accepts the legacy ScanParameters layout where ReconSpec
has no `nz` and stores `nx` as a two-element [nz, nx], and MATLAB scalars saved as
1x1 arrays.

Prereq: numpy, scipy, h5py, matplotlib. A stored recording with a beamformed
stream (bf_acq.dat). No EchoFrame wheel or GPU required, but run it under the same
Python environment used for EchoFrame (the interpreter that has the EchoFrame
build/analysis dependencies installed) rather than an unrelated system Python.
Usage:  edit the parameters block below; run.
"""

import glob
import os
import time
from pathlib import Path

import h5py
import matplotlib.pyplot as plt
import numpy as np
from scipy import linalg as LA

# ─────────────────────────── Parameters ────────────────────────────────────
load_path = Path("")           # folder containing ScanParameters.mat + the BF .dat
bf_file   = "bf_acq.dat"       # BF stream file name; "" auto-discovers a *BF*/*bf* .dat
scan_file = "ScanParameters.mat"

NEWDT_MS  = 300                # output temporal resolution [ms]
WINDOW_MS = 600                # SVD window length [ms]
NSVDDROP  = 50                 # number of leading singular values to drop (clutter filter)

# Slow-time sampling rate [Hz]. 0 -> read ReceiveSpec.dopplerSamplingFrequency
# from ScanParameters.mat (present on Verasonics recordings; set it here for
# datasets that do not carry the field, e.g. the generated demo data).
SAMPLING_FREQ_HZ = 0

SHOW_FRAMES = 3                # preview this many power-Doppler frames at the end (0 = none)


def mult_diag(d, mat, left=True):
    """Multiply a diagonal (given as a vector d) with a matrix, on the left or right."""
    if left:
        return (d * mat.T).T
    return d * mat


def filter_signal_svd(data, nelim=25):
    """SVD clutter filter: drop the first `nelim` singular values, rebuild the stack.

    data is (time, nz, nx); returns the filtered stack (same shape) and the
    variance-explained spectrum.
    """
    nt, nz, nx = data.shape
    data = data.reshape(nt, -1)
    U, S, Vt = LA.svd(data, full_matrices=False)

    varexpl = S / np.sum(S)
    goodidx = np.arange(len(S)) >= nelim
    US = mult_diag(S[goodidx], U[:, goodidx], left=False)
    Vt = Vt[goodidx]
    ndat = np.dot(US, Vt)

    return ndat.reshape(nt, nz, nx), varexpl


def _scalar(group, key):
    """Read a scalar field from an h5py group (MATLAB stores scalars as 1x1 arrays)."""
    return np.array(group[key][()]).ravel()[0]


def _find_one(folder, name, patterns):
    """Return the path to `name` in folder, or the single match of the glob patterns."""
    if name:
        p = os.path.join(folder, name)
        if os.path.exists(p):
            return p
    for pat in patterns:
        hits = glob.glob(os.path.join(folder, pat))
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise FileNotFoundError(
                f"Multiple matches for {pat} in {folder}; set the file name explicitly."
            )
    raise FileNotFoundError(f"No {name or patterns} found in {folder}")


def preprocess_fusi(path, newdt=NEWDT_MS, window=WINDOW_MS, nsvddrop=NSVDDROP,
                    sampling_freq_hz=SAMPLING_FREQ_HZ, max_frames=None):
    """Compute fUSI power Doppler from a stored BF recording.

    Parameters
    ----------
    path (str)             : recording folder (ScanParameters.mat + BF .dat)
    newdt (int)            : output temporal resolution [ms]
    window (int)           : SVD window length [ms]
    nsvddrop (int)         : number of singular values to drop
    sampling_freq_hz (int) : slow-time sampling rate [Hz]; 0 reads it from the .mat
    max_frames (int)       : stop after this many frames (None = whole recording);
                             use it to preview a long recording without reading it all

    Returns
    -------
    power_doppler (np.ndarray): (time, nz, nx)
    times (np.ndarray)        : window-centre time of each frame [ms]
    """
    assert os.path.exists(path), f"Recording folder not found: {path}"

    bf_path = _find_one(path, bf_file, ["bf_acq.dat", "*BF*.dat", "*bf*.dat"])
    scan_path = _find_one(path, scan_file, ["ScanParameters.mat", "*ScanParameters*.mat"])

    fileID = open(bf_path, "rb")
    fileSize = os.path.getsize(bf_path)

    with h5py.File(scan_path, "r") as file:
        ReconSpec = file["ReconSpec"]
        ReceiveSpec = file["ReceiveSpec"]

        cropBF = bool(np.array(ReconSpec["cropBF"][()])) if "cropBF" in ReconSpec else False
        if cropBF:
            nz = int(np.array(ReconSpec["croppingROI"][0][1])
                     - np.array(ReconSpec["croppingROI"][0][0]) + 1)
            nx = int(np.array(ReconSpec["croppingROI"][0][3])
                     - np.array(ReconSpec["croppingROI"][0][2]) + 1)
        else:
            # Older recordings store no `nz`; `nx` is then a 2-element [nz, nx].
            nx_field = np.array(ReconSpec["nx"]).ravel()
            if nx_field.size > 1:
                nz = int(nx_field[0])
                nx = int(nx_field[1])
            else:
                nz = int(_scalar(ReconSpec, "nz"))
                nx = int(nx_field[0])
        nRepeats = int(_scalar(ReceiveSpec, "nRepeats"))

        if sampling_freq_hz:
            sampling_freqhz = int(sampling_freq_hz)
        elif "dopplerSamplingFrequency" in ReceiveSpec:
            sampling_freqhz = int(_scalar(ReceiveSpec, "dopplerSamplingFrequency"))
        else:
            raise KeyError(
                "ReceiveSpec.dopplerSamplingFrequency is not in ScanParameters.mat; "
                "set SAMPLING_FREQ_HZ in the parameters block."
            )

    # Header: field[1] is the header size in bytes; seek past it to the data.
    numHeaderElements = 5
    header = np.fromfile(fileID, dtype=np.uint64, count=numHeaderElements)
    mVersion, mHeaderSize, mBuffersDequeued, effectiveBufferSize, mPaddingBytes = header
    nframes = mBuffersDequeued

    # Image counts from durations: ms * Hz / 1000 (exact when it should be, unlike
    # ms / sampling_dt where sampling_dt = 1000/Hz may not terminate).
    images_per_window = round(window * sampling_freqhz / 1000.0)
    step_images = round(newdt * sampling_freqhz / 1000.0)
    assert abs(images_per_window - window * sampling_freqhz / 1000.0) < 1e-6, \
        "WINDOW_MS must be a whole number of sampling periods"
    assert abs(step_images - newdt * sampling_freqhz / 1000.0) < 1e-6, \
        "NEWDT_MS must be a whole number of sampling periods"
    assert images_per_window > 0 and step_images > 0, "WINDOW_MS / NEWDT_MS too small"

    # Each stored buffer is a burst of nRepeats slow-time images.
    burst_duration = (nRepeats / sampling_freqhz) * 1000  # [ms]

    frame_size_bytes = nx * nz * 2 * 4        # complex float32
    window_size_bytes = images_per_window * frame_size_bytes

    total_duration = nframes * burst_duration  # [ms]
    n_chunks = int(np.floor(total_duration / newdt))
    if max_frames is not None:
        n_chunks = min(n_chunks, int(max_frames))

    procdata = np.zeros((n_chunks, nz, nx), dtype=np.float32)
    newtimes = np.zeros(n_chunks, dtype=np.float64)

    # Read `for_svd` float32s per window; advance `step - for_svd` between windows
    # (negative -> overlap) so successive windows step by NEWDT_MS.
    step = 2 * nx * nz * step_images
    for_svd = 2 * nx * nz * images_per_window

    fileID.seek(mHeaderSize, 0)

    t0 = time.time()
    ichunk = 0
    for ichunk in range(n_chunks):
        current_position = fileID.tell()
        if window_size_bytes > fileSize - current_position:
            break  # not enough data left for a full window

        start_time = ichunk * newdt + window / 2  # window-centre time [ms]

        data_raw = np.fromfile(fileID, dtype=np.float32, count=for_svd)
        try:
            data = data_raw[::2] + 1j * data_raw[1::2]
            data = data.reshape(nz, nx, images_per_window, order="F")
        except ValueError as e:
            print(f"Reshape error at chunk {ichunk}: {e}; "
                  f"got {data_raw.size} floats, expected ({nz}, {nx}, {images_per_window})")
            break
        data = np.transpose(data, (2, 0, 1))  # -> (images, nz, nx)

        if ichunk % 10 == 0:
            print("dt=%0.2f[ms] window=%0.2f[ms] dropped_svds=%i (%i/%i) %0.3f[min]"
                  % (newdt, window, nsvddrop, ichunk + 1, n_chunks, (time.time() - t0) / 60.0))

        data, _ = filter_signal_svd(data, nelim=nsvddrop)
        procdata[ichunk] = np.mean(np.abs(data) ** 2, 0).astype(np.float32)
        newtimes[ichunk] = start_time

        fileID.seek(int((step - for_svd) * 4), 1)

    fileID.close()
    print("Total duration: %0.04f[min]" % ((time.time() - t0) / 60.0))
    return procdata[:ichunk], newtimes[:ichunk]


def _preview(procdata, times, n):
    """Show the first n power-Doppler frames as dB re per-frame max (10*log10,
    since power Doppler is a power quantity), matching read_PDI.py."""
    for i in range(min(n, len(procdata))):
        frame = procdata[i]
        frame_db = 10 * np.log10(frame / frame.max())
        plt.figure(figsize=(6, 6))
        plt.imshow(frame_db, cmap="hot")
        plt.colorbar(label="Power [dB re max]")
        plt.xlabel("x [pixels]")
        plt.ylabel("z [pixels]")
        plt.title(f"Power Doppler frame {i + 1} (t = {times[i]:.0f} ms)")
    plt.show()


if __name__ == "__main__":
    proc_data, proc_times = preprocess_fusi(str(load_path))
    print(f"Computed {len(proc_data)} power-Doppler frames of shape "
          f"{proc_data.shape[1:] if len(proc_data) else '(none)'}")
    if SHOW_FRAMES and len(proc_data):
        _preview(proc_data, proc_times, SHOW_FRAMES)
