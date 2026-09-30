"""
Compare EchoFrame Fourier and ffdas DAS beamformers on one stored RF frame.

Requires an EchoFrame Python build configured with ``-DEF_USE_FFDAS=ON``.
Edit ``load_path`` below or pass it on the command line.
"""

from __future__ import annotations

import argparse
import copy
import sys
import time
from pathlib import Path

import h5py
import matplotlib.pyplot as plt
import numpy as np

import echoframe as ef

_HERE = Path(__file__).resolve().parent
sys.path.insert(1, str((_HERE / "../core").resolve()))
import rf_io  # noqa: E402
from validate_structs_py_to_ef import validate_specs  # noqa: E402

load_path = Path("")


def h5struct_to_dict(group: h5py.Group) -> dict:
    """Convert a MATLAB v7.3 struct group to a dict."""
    out = {}
    for k, item in group.items():
        name = k.rstrip("\x00")
        if isinstance(item, h5py.Dataset):
            data = item[()]
            if isinstance(data, np.ndarray) and data.dtype.names == ("real", "imag"):
                data = data["real"] + 1j * data["imag"]
            elif item.attrs.get("MATLAB_complex", None) == np.bytes_("1"):
                real, imag = np.split(data, 2, axis=-1)
                data = real.squeeze(-1) + 1j * imag.squeeze(-1)
            elif data.dtype.kind in ("u", "i") and data.dtype.itemsize == 2:
                data = "".join(chr(x) for x in data.squeeze())
            if isinstance(data, np.ndarray) and data.shape == ():
                data = data.item()
            out[name] = data
        elif isinstance(item, h5py.Group):
            out[name] = h5struct_to_dict(item)
    return out


def normalize_specs(probe: dict, transmit: dict, receive: dict, recon: dict, pdi: dict) -> tuple[dict, dict, dict, dict, dict]:
    """Map Effusive field names onto EchoFrame Python example names."""
    probe = dict(probe)
    transmit = dict(transmit)
    receive = dict(receive)
    recon = dict(recon)
    pdi = dict(pdi)

    if "pitch" not in probe and "pitchX" in probe:
        probe["pitch"] = probe["pitchX"]
    if "nElements" not in probe and "nElementsX" in probe:
        probe["nElements"] = probe["nElementsX"]
    if "elementPosition" not in probe and "element_position" in probe:
        probe["elementPosition"] = probe["element_position"]

    if "steer" not in transmit and "steerX" in transmit:
        transmit["steer"] = transmit["steerX"]

    if "samplingMode" not in receive and "sampling_mode" in receive:
        receive["samplingMode"] = receive["sampling_mode"]
    if "samplesPerWavelength" not in receive and "samples_per_wavelength" in receive:
        receive["samplesPerWavelength"] = receive["samples_per_wavelength"]

    if "extraVoxelsZ" not in recon and "extra_voxels_z" in recon:
        recon["extraVoxelsZ"] = recon["extra_voxels_z"]
    if "extraVoxelsX" not in recon and "extra_voxels_x" in recon:
        recon["extraVoxelsX"] = recon["extra_voxels_x"]

    return probe, transmit, receive, recon, pdi


def find_session_files(path: Path) -> tuple[Path, Path]:
    """Accept either example folder or an Effusive *_rf.dat file."""
    if path.is_file():
        if path.name.endswith("_rf.dat"):
            return path.with_name(path.name.replace("_rf.dat", "_seq.mat")), path
        return path, path.with_name(path.name.replace("_seq.mat", "_rf.dat"))
    return path / "ScanParameters.mat", path / "rf_acq.dat"


def add_das_spec(probe: dict, transmit: dict, receive: dict, recon: dict) -> dict:
    """Return a ReconSpec copy with the DAS fields EchoFrame expects."""
    out = copy.deepcopy(recon)
    out["beamformerType"] = "DAS"

    nz = int(np.asarray(out["nz"]).ravel()[0])
    nx = int(np.asarray(out["nx"]).ravel()[0])
    ntx = int(np.asarray(receive["nTransmissions"]).ravel()[0])
    nelem = int(np.asarray(probe["nElements"]).ravel()[0])
    pitch = float(np.asarray(probe["pitch"]).ravel()[0])
    fs = float(np.asarray(receive["Fs"]).ravel()[0])
    c0 = float(np.asarray(out["c0"]).ravel()[0])
    # EchoFrame IQ samples are depth-like: one complex sample advances the image
    # depth by c/Fs. Geometric DAS sums transmit and receive paths, so scale
    # positions by Fs/(2c) to map the two-way path onto EchoFrame's sample axis.
    fs_over_two_c = fs / (2 * c0)

    channel_x = (np.arange(nelem, dtype=np.float32) - (nelem - 1) / 2) * pitch
    out["dasChannelPositions"] = (
        np.column_stack([channel_x, np.zeros((nelem, 2), dtype=np.float32)])
        * fs_over_two_c
    ).astype(np.float32).ravel()

    x_axis = np.asarray(out["xAxis"], dtype=np.float64).ravel() * 1e-3
    z_axis = np.asarray(out["zAxis"], dtype=np.float64).ravel() * 1e-3
    start_samples = z_axis[0] * 2 * fs_over_two_c
    x_grid, z_grid = np.meshgrid(x_axis, z_axis)
    voxel_x = x_grid.ravel(order="F")
    voxel_z = z_grid.ravel(order="F")
    out["dasVoxelPositions"] = (
        np.column_stack([voxel_x, np.zeros(nz * nx), voxel_z]) * fs_over_two_c
    ).astype(np.float32).ravel()

    receive_samples = (
        np.sqrt((voxel_x[:, None] - channel_x[None, :]) ** 2 + voxel_z[:, None] ** 2)
        * fs_over_two_c
    )
    min_offset = 1 - receive_samples.min(axis=1)

    # Planewave TX path is z*cos(theta)+x*sin(theta) plus the per-tx bulk delay
    # Verasonics stores by clamping negative TX.Delay to zero. That bulk is in
    # the RF; omitting it desynchronizes steered txs and blurs mid-depth. Do not
    # rebuild the wavefront via min-over-elements or clip max_offset: the
    # geometric path plus bulk matches min-over(active) to <0.01 sample, and
    # ffdas already zeros channel reads past the IQ buffer so deep rows keep
    # correct depth with partial aperture.
    steer = np.asarray(transmit["steer"], dtype=np.float64).ravel()
    transmit_delays = np.asarray(transmit.get("transmitDelays", 0), dtype=np.float64)
    use_transmit_delays = transmit_delays.size > 1 and np.any(transmit_delays != 0)
    if use_transmit_delays:
        transmit_delays = np.squeeze(transmit_delays)
        if transmit_delays.shape[0] == ntx and transmit_delays.shape[-1] == nelem:
            transmit_delays = transmit_delays.T
        else:
            transmit_delays = transmit_delays.reshape(nelem, -1)
        transmit_delays = transmit_delays[:, :ntx]
        apod = np.asarray(transmit.get("apodization", np.ones(nelem)), dtype=bool).ravel()

    offsets = np.empty((ntx, nz * nx), dtype=np.float32)
    for i, theta in enumerate(steer[:ntx]):
        sin_t = np.sin(np.deg2rad(theta))
        if use_transmit_delays:
            residual = transmit_delays[:, i] - channel_x * sin_t / c0
            bulk = float(np.median(residual[apod])) if np.any(apod) else 0.0
        else:
            bulk = 0.0
        raw_offsets = (
            (
                z_grid * np.cos(np.deg2rad(theta))
                + x_grid * sin_t
            ).ravel(order="F")
            * fs_over_two_c
            + bulk * fs / 2
            - start_samples
        )
        offsets[i] = np.maximum(raw_offsets, min_offset)
    out["dasOffsets"] = offsets.ravel()
    out["dasWeights"] = np.full(
        ntx * nz * nx, 1.0 / max(1, ntx * nelem), dtype=np.float32
    )
    # RFFormatter stores IQ as I - iQ, so ffdas' usual negative phase rotation
    # is conjugated here.
    out["dasWavenum"] = np.float32(
        4 * np.pi * float(np.asarray(probe["Fc"]).ravel()[0]) / fs
    )
    out["dasAlgorithm"] = np.int32(1)
    out["dasComputeType"] = np.int32(0)
    out["dasSourceDirections"] = np.tile(
        np.array([0, 0, 1, np.cos(np.deg2rad(35))], dtype=np.float32), nelem
    )
    return out


def run_once(receive: dict, recon: dict, pdi: dict, rf: np.ndarray) -> tuple[np.ndarray, float]:
    """Process one RF buffer and return B-mode plus elapsed seconds."""
    res = ef.make_resources(receive, recon, pdi)
    core = ef.EchoFrame(res, use_storage=False)
    t0 = time.perf_counter()
    _, bmode, _ = core.process(rf, start_storage=False)
    return bmode, time.perf_counter() - t0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=load_path)
    parser.add_argument("--no-show", action="store_true")
    args = parser.parse_args()
    if not args.path or not args.path.exists():
        raise SystemExit("Pass a folder containing ScanParameters.mat/rf_acq.dat or an Effusive *_rf.dat file.")

    seq_path, rf_path = find_session_files(args.path)
    with h5py.File(seq_path, "r") as f:
        probe = h5struct_to_dict(f["ProbeSpec"])
        transmit = h5struct_to_dict(f["TransmitSpec"])
        receive = h5struct_to_dict(f["ReceiveSpec"])
        recon = h5struct_to_dict(f["ReconSpec"])
        pdi = h5struct_to_dict(f["PDISpec"])
    probe, transmit, receive, recon, pdi = normalize_specs(probe, transmit, receive, recon, pdi)

    _, _, receive_f, recon_f, pdi_f = validate_specs(probe, transmit, receive, recon, pdi)
    rf = rf_io.read_stored_rf(rf_path, receive_f).ravel(order="F")
    fourier_bmode, fourier_s = run_once(receive_f, recon_f, pdi_f, rf)

    recon_d = add_das_spec(probe, transmit, receive, recon)
    _, _, receive_d, recon_d, pdi_d = validate_specs(probe, transmit, receive, recon_d, pdi)
    das_bmode, das_s = run_once(receive_d, recon_d, pdi_d, rf)

    print(f"Fourier: {fourier_s:.3f} s")
    print(f"DAS:     {das_s:.3f} s")
    print(f"Mean abs B-mode diff: {np.mean(np.abs(fourier_bmode - das_bmode)):.6g}")

    if args.no_show:
        return
    vmax = max(float(fourier_bmode.max()), float(das_bmode.max()), np.finfo(np.float32).eps)
    imgs = [fourier_bmode, das_bmode]
    titles = ["Fourier", "DAS"]
    fig, axes = plt.subplots(1, 2, figsize=(8, 4), constrained_layout=True, dpi=300)
    for ax, img, title in zip(axes, imgs, titles):
        im = ax.imshow(
            20 * np.log10(img.T / vmax + np.finfo(np.float32).eps),
            cmap="gray",
            vmin=-60,
            vmax=0,
        )
        ax.set_title(title)
        ax.axis("image")
    fig.colorbar(im, ax=axes, label="dB", shrink=0.8)
    plt.show()


if __name__ == "__main__":
    main()
