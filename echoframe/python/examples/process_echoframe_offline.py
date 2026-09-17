"""
process_echoframe_offline - Replay stored EchoFrame data via the Python pipeline.

Reads ScanParameters.mat (-v7.3, via h5py) and rf_acq.dat produced by an
EchoFrame storage session, validates and casts the parameter structs,
drives the CUDA core through the pybind11 module `echoframe`, and shows
B-mode and PDI images.

Prereq: the EchoFrame python wheel installed, and saved data at load_path (see
the main README for wheel instructions). Run this with the same Python
interpreter the wheel is installed in, not an arbitrary system Python.
Usage:  edit the parameters block below; run.
"""

from pathlib import Path
import sys

import h5py
import matplotlib.pyplot as plt
import numpy as np

import echoframe as ef

# Make the echoframe/python/core helpers importable regardless of current directory
_HERE = Path(__file__).resolve().parent
sys.path.insert(1, str((_HERE / "../core").resolve()))
from validate_structs_py_to_ef import validate_specs  # noqa: E402
import rf_io  # noqa: E402

# ─────────────────────────── Parameters ────────────────────────────────────
load_path = Path("")                  # folder containing ScanParameters.mat + rf_acq.dat
scan_file = "ScanParameters.mat"
rf_file   = "rf_acq.dat"
N_FRAMES  = 1                         # number of times to call process() (timing/warmup)
SHOW      = True                      # render B-mode + PDI at the end


def h5struct_to_dict(group: h5py.Group) -> dict:
    """Convert a MATLAB v7.3 struct group to a nested dict (handles complex + char)."""
    out = {}
    for k, item in group.items():
        name = k.rstrip("\x00")
        if isinstance(item, h5py.Dataset):
            data = item[()]

            # complex dataset: MATLAB stores [real imag] layout
            if item.attrs.get("MATLAB_complex", None) == np.bytes_("1"):
                real, imag = np.split(data, 2, axis=-1)
                data = real.squeeze(-1) + 1j * imag.squeeze(-1)
            # char array (uint16) → str
            elif data.dtype.kind in ("u", "i") and data.dtype.itemsize == 2:
                data = "".join(chr(x) for x in data.squeeze())

            # 0-D dataset → scalar
            if isinstance(data, np.ndarray) and data.shape == ():
                data = data.item()

            out[name] = data
        elif isinstance(item, h5py.Group):
            out[name] = h5struct_to_dict(item)
    return out


def main() -> None:
    if not load_path or not load_path.exists():
        raise SystemExit(
            f"load_path is not set or does not exist: {load_path!s}\n"
            f"Edit the parameters block at the top of this file."
        )

    scan_path = load_path / scan_file
    rf_path   = load_path / rf_file

    # 1. Read ScanParameters.mat
    with h5py.File(scan_path, "r") as f:
        ProbeSpec    = h5struct_to_dict(f["ProbeSpec"])
        TransmitSpec = h5struct_to_dict(f["TransmitSpec"])
        ReceiveSpec  = h5struct_to_dict(f["ReceiveSpec"])
        ReconSpec    = h5struct_to_dict(f["ReconSpec"])
        PDISpec      = h5struct_to_dict(f["PDISpec"])

    # 2. Validate + cast (mirrors MATLAB's echoframe_validate_structs)
    ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec = validate_specs(
        ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec
    )

    # 3. Build resources for the core
    res = ef.make_resources(ReceiveSpec, ReconSpec, PDISpec)

    # 4. Read the RF buffer
    rf = rf_io.read_stored_rf(rf_path, ReceiveSpec).ravel(order="F")

    # 5. Process
    core = ef.EchoFrame(res, use_storage=False)
    pdi = bmode = None
    for _ in range(N_FRAMES):
        pdi, bmode, _ = core.process(rf, start_storage=False)

    # 6. Display
    if SHOW and bmode is not None:
        bmode_db = 20 * np.log10(bmode / bmode.max() + np.finfo(np.float32).eps)
        plt.figure(figsize=(6, 5))
        plt.imshow(np.transpose(bmode_db), cmap="gray", vmin=-40, vmax=0, origin="upper")
        plt.title("B-mode [dB]")
        plt.colorbar(); plt.axis("image"); plt.show()

        for k in range(pdi.shape[2]):
            plt.figure(figsize=(6, 5))
            PDI_frame = pdi[:, :, k]
            PDI_norm_db = 10 * np.log10(PDI_frame / PDI_frame.max())
            plt.imshow(np.transpose(PDI_norm_db), cmap="hot", origin="upper")
            plt.title(f"PDI frame {k + 1}")
            plt.colorbar(); plt.axis("image")
            plt.show()


if __name__ == "__main__":
    main()
