"""
Compare EchoFrame Fourier and ffdas DAS beamformers on one stored RF frame.

Requires an EchoFrame Python build. The DAS beamformer needs ffdas, which is
built by default.
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


def _tukey_window(n: int, alpha: float) -> np.ndarray:
    if alpha <= 0:
        return np.ones(n)
    if alpha >= 1:
        return np.hanning(n)
    x = np.linspace(0, 1, n)
    w = np.ones(n)
    left = x < alpha / 2
    right = x >= 1 - alpha / 2
    w[left] = 0.5 * (1 + np.cos(2 * np.pi / alpha * (x[left] - alpha / 2)))
    w[right] = 0.5 * (1 + np.cos(2 * np.pi / alpha * (x[right] - 1 + alpha / 2)))
    return w


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


def matstruct_to_dict(obj) -> dict:
    """Convert a scipy-loaded MATLAB v5 struct to a dict."""
    fields = getattr(obj, "_fieldnames", None)
    if fields is None:
        return obj
    return {name: matstruct_to_dict(getattr(obj, name)) for name in fields}


def load_specs(path: Path) -> tuple[dict, dict, dict, dict, dict]:
    try:
        with h5py.File(path, "r") as f:
            return tuple(h5struct_to_dict(f[k]) for k in ("ProbeSpec", "TransmitSpec", "ReceiveSpec", "ReconSpec", "PDISpec"))
    except OSError:
        from scipy.io import loadmat

        data = loadmat(path, squeeze_me=True, struct_as_record=False)
        specs = tuple(matstruct_to_dict(data[k]) for k in ("ProbeSpec", "TransmitSpec", "ReceiveSpec", "ReconSpec", "PDISpec"))
        recon = specs[3]
        # scipy preserves MATLAB column-major shapes; Python bindings expect C-style
        # arrays with coordinate/tx dimensions leading.
        if str(recon.get("beamformerType", "")).lower() == "das":
            recon = dict(recon)
            recon["dasChannelPositions"] = np.asarray(recon["dasChannelPositions"]).T
            recon["dasVoxelPositions"] = np.asarray(recon["dasVoxelPositions"]).T
            recon["dasOffsets"] = np.transpose(np.asarray(recon["dasOffsets"]), (2, 1, 0))
            recon["dasWeights"] = np.transpose(np.asarray(recon["dasWeights"]), (2, 1, 0))
            if "dasSourceDirections" in recon:
                recon["dasSourceDirections"] = np.asarray(recon["dasSourceDirections"]).T
            specs = (specs[0], specs[1], specs[2], recon, specs[4])
        return specs


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
    """Accept a folder, an RF .dat, or a parameter .mat file."""
    if path.is_file():
        if path.suffix == ".dat":
            mats = sorted(path.parent.glob("*.mat"))
            preferred = path.with_name(path.name.replace("_rf.dat", "_seq.mat"))
            return (preferred if preferred.exists() else mats[0]), path
        dats = sorted(path.parent.glob("*rf*.dat"))
        return path, dats[0]
    mat = path / "ScanParameters.mat"
    if not mat.exists():
        mats = sorted(path.glob("*.mat"))
        mat = mats[0]
    rf = path / "rf_acq.dat"
    if not rf.exists():
        rfs = sorted(path.glob("*rf*.dat"))
        rf = rfs[0]
    return mat, rf


def _mode_setup(receive: dict) -> tuple[int, float, np.ndarray, np.ndarray, bool]:
    n_samples = int(np.asarray(receive["nSamples"]).ravel()[0])
    samples_per_wavelength = int(np.asarray(receive["samplesPerWavelength"]).ravel()[0])
    n_factor = round(4 / samples_per_wavelength)
    mode = str(np.asarray(receive["samplingMode"]).item())
    if mode == "BS50BW":
        nz = n_samples * n_factor
        freq_window = np.arange(int(np.ceil(nz / 4 - nz / 16)), int(np.floor(nz / 4 + nz / 16)))
        freq_mapping = np.fft.fftshift(np.arange(nz // 8))
        return nz, 1.0, freq_window, freq_mapping, True
    if mode == "BS67BW":
        nz = n_samples * 2
        lower = nz // 2 - 1
        freq_window = np.arange(lower, lower + nz // 4)
        return nz, 2.0, freq_window, np.arange(nz // 4), False
    if mode == "BS100BW":
        nz = n_samples * n_factor
        freq_window = np.arange(int(np.ceil(nz / 4 - nz / 8)), int(np.floor(nz / 4 + nz / 8)))
        freq_mapping = np.fft.fftshift(np.arange(nz // 4))
        return nz, 1.0, freq_window, freq_mapping, True
    if mode == "NS200BW":
        nz = n_samples * n_factor
        return nz, 1.0, np.arange(nz // 2), np.arange(nz // 2), False
    raise ValueError(f"Unsupported samplingMode {mode!r}")


def add_fourier_spec(probe: dict, transmit: dict, receive: dict, recon: dict) -> dict:
    """Return a ReconSpec copy with the Fourier fields EchoFrame expects."""
    out = copy.deepcopy(recon)
    out["beamformerType"] = "Fourier"

    nz, freq_scale, freq_window, freq_mapping, freq_axis_shift = _mode_setup(receive)
    fs = float(np.asarray(receive.get("Fs_base", receive["Fs"])).ravel()[0])
    c0 = float(np.asarray(out["c0"]).ravel()[0])
    nx = int(np.asarray(receive["nChannels"]).ravel()[0])
    ntx = int(np.asarray(receive["nTransmissions"]).ravel()[0])
    pitch = float(np.asarray(probe["pitch"]).ravel()[0])
    dz = c0 / (fs * freq_scale)

    frequency_axis = np.fft.fftshift(np.arange(-0.5, 0.5, 1 / nz)) * fs * freq_scale
    frequency_axis = frequency_axis[freq_window]
    if freq_axis_shift:
        frequency_axis = np.fft.fftshift(frequency_axis)

    kx_vector = np.arange(-0.5, 0.5, 1 / nx) * 2 * np.pi / pitch
    kz_vector = np.arange(-0.5, 0.5, 1 / nz) * 4 * np.pi / dz
    max_k = np.max(np.abs(np.concatenate([kx_vector, kz_vector])))
    kx_vector = np.fft.fftshift(kx_vector / max_k).astype(np.float32)
    kz_vector = np.fft.fftshift(kz_vector / max_k).astype(np.float32)
    gam = 2 / nz

    kz_vector = np.fft.fftshift(kz_vector[freq_window])
    kz, kx = np.meshgrid(kz_vector, kx_vector, indexing="ij")
    spectrum_weighting = np.fft.fftshift(
        np.outer(_tukey_window(len(kz_vector), 0.2), _tukey_window(len(kx_vector), 0.2))
    )

    theta = np.asarray(transmit["steer"], dtype=np.float32).ravel()[:ntx]
    cos_t = np.cos(np.deg2rad(theta))[None, None, :]
    sin_t = np.sin(np.deg2rad(theta))[None, None, :]
    kz3 = kz[:, :, None]
    kx3 = kx[:, :, None]
    with np.errstate(divide="ignore", invalid="ignore"):
        k = (kz3**2 + kx3**2) / (2 * kz3 * cos_t + 2 * kx3 * sin_t)
    valid = np.abs(k) < np.abs(kz3) * 2
    k = 2 * k * valid
    k[np.isnan(k)] = 0

    phase_window = spectrum_weighting[:, :, None] * (((2 * kz3 * cos_t) * (kx3 * sin_t)) < 0.01)
    kbin = k / gam
    koff = np.floor(kbin - 0.5)
    kk = np.mod(koff + 1, nz).astype(np.int64)
    idx = kk - int(freq_window[0])
    arg = kbin - koff
    phase_w = np.exp(-1j * np.pi * arg) * phase_window

    n_iq = int(np.asarray(receive["nSamplesIQ"]).ravel()[0])
    idx[(idx < 0) | (idx >= n_iq)] = 0
    idx = freq_mapping[idx]
    scaling = float(ntx * int(np.asarray(out["nz"]).ravel()[0]) * int(np.asarray(out["nx"]).ravel()[0]) * 2)

    out["delayIndices"] = np.transpose(idx.astype(np.int32), (2, 1, 0))
    out["interpolationWeights"] = np.transpose((phase_w / scaling).astype(np.complex64), (2, 1, 0))
    out["frequencyAxis"] = frequency_axis.astype(np.float32)

    transmit_delays = np.asarray(transmit["transmitDelays"], dtype=np.float64)
    transmit_delays = np.squeeze(transmit_delays)
    if transmit_delays.shape[0] == ntx:
        transmit_delays = transmit_delays.T
    transmit_delays = transmit_delays[:, :ntx] * 2 * np.pi
    active = np.flatnonzero(np.asarray(transmit["apodization"]).ravel() != 0)
    delay_ax = np.median(np.diff(transmit_delays[active, :], axis=0), axis=0)
    mid_element = int(np.asarray(probe["nElements"]).ravel()[0]) // 2 - 1
    mid_channel = nx // 2
    delay_b = transmit_delays[mid_element, :] - mid_channel * delay_ax
    out["planewaveDelays"] = np.concatenate([delay_ax, delay_b]).astype(np.float32)
    return out


def _directivity_f_number(probe: dict, recon: dict) -> float:
    width = float(np.asarray(
        probe.get("elementWidth", probe.get("ElementWidth", probe.get("width", probe["pitch"])))
    ).ravel()[0])
    fc = float(np.asarray(probe["Fc"]).ravel()[0])
    fmax = float(np.asarray(probe.get("fmax", probe.get("Fmax", fc))).ravel()[0])
    if "bandwidth" in probe:
        fmax = fc + float(np.asarray(probe["bandwidth"]).ravel()[0]) / 2
    elif "bandwidthFraction" in probe:
        fmax = fc * (1 + float(np.asarray(probe["bandwidthFraction"]).ravel()[0]) / 2)
    wavelength = float(np.asarray(recon["c0"]).ravel()[0]) / fmax
    theta = np.linspace(0, np.pi / 2 - 1e-3, 4096)
    directivity = np.abs(np.cos(theta) * np.sinc(width / wavelength * np.sin(theta)))
    idx = np.flatnonzero(directivity <= 0.71)
    alpha = theta[idx[0]] if idx.size else theta[-1]
    return 1 / (2 * np.tan(alpha))


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
    f_number = _directivity_f_number(probe, out)
    cos_alpha = np.float32(np.cos(np.arctan(1 / (2 * f_number))))
    directivity_mask = (
        voxel_z[:, None]
        / np.sqrt((voxel_x[:, None] - channel_x[None, :]) ** 2 + voxel_z[:, None] ** 2)
        > float(cos_alpha)
    )
    weights = np.zeros((ntx, nz * nx), dtype=np.float32)
    for i in range(ntx):
        phase = offsets[i, :, None] + receive_samples
        valid = directivity_mask & (phase >= 0) & (phase < float(np.asarray(receive["nSamplesIQ"]).ravel()[0] - 1))
        counts = valid.sum(axis=1)
        weights[i] = np.divide(
            1.0,
            ntx * counts,
            out=np.zeros_like(counts, dtype=np.float32),
            where=counts > 0,
        )
    out["dasWeights"] = weights.ravel()
    # RFFormatter stores IQ as I - iQ, so ffdas' usual negative phase rotation
    # is conjugated here.
    out["dasWavenum"] = np.float32(
        4 * np.pi * float(np.asarray(probe["Fc"]).ravel()[0]) / fs
    )
    out["dasAlgorithm"] = np.int32(1)
    out["dasComputeType"] = np.int32(0)
    out["dasSourceDirections"] = np.tile(
        np.array([0, 0, 1, cos_alpha], dtype=np.float32), nelem
    )
    return out


def _ef_image_layout(image: np.ndarray) -> np.ndarray:
    """Return EchoFrame image data with Python axis layout."""
    return image.ravel(order="C").reshape(image.shape, order="F")


def run_once(receive: dict, recon: dict, pdi: dict, rf: np.ndarray) -> tuple[np.ndarray, float]:
    """Process one RF buffer and return B-mode plus elapsed seconds."""
    res = ef.make_resources(receive, recon, pdi)
    core = ef.EchoFrame(res, use_storage=False)
    t0 = time.perf_counter()
    _, bmode, _ = core.process(rf, start_storage=False)
    return _ef_image_layout(bmode), time.perf_counter() - t0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=load_path)
    parser.add_argument("--no-show", action="store_true")
    args = parser.parse_args()
    if not args.path or not args.path.exists():
        raise SystemExit("Pass a folder containing ScanParameters.mat/rf_acq.dat or an Effusive *_rf.dat file.")

    seq_path, rf_path = find_session_files(args.path)
    probe, transmit, receive, recon, pdi = load_specs(seq_path)
    probe, transmit, receive, recon, pdi = normalize_specs(probe, transmit, receive, recon, pdi)

    recon_f = add_fourier_spec(probe, transmit, receive, recon)
    _, _, receive_f, recon_f, pdi_f = validate_specs(probe, transmit, receive, recon_f, pdi)
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
            20 * np.log10(img / vmax + np.finfo(np.float32).eps),
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
