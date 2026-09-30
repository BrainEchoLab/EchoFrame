"""
Generate a tiny synthetic EchoFrame session for offline examples.

Writes ``ScanParameters.mat`` and ``rf_acq.dat`` with the minimum fields needed by
``compare_beamformers.py``. The data are deterministic and intentionally small.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

import h5py
import numpy as np


def _char(s: str) -> np.ndarray:
    return np.array([ord(c) for c in s], dtype=np.uint16)


def _dataset(group: h5py.Group, name: str, value) -> None:
    group.create_dataset(name, data=value)


def _write_struct(root: h5py.File, name: str, fields: dict) -> None:
    group = root.create_group(name)
    for key, value in fields.items():
        _dataset(group, key, value)


def make_specs() -> tuple[dict, dict, dict, dict, dict]:
    """Build deterministic small EchoFrame structs."""
    n_iq = 64
    n_samples = 2 * n_iq
    n_channels = 16
    n_tx = 3
    n_repeats = 8
    pitch = 300e-6
    fs = 20e6
    fc = 5e6
    c0 = 1540.0

    # DAS delay is transmit distance + receive distance in samples. Keep this
    # tiny grid inside the 64 IQ samples so the smoke test exercises in-bounds
    # interpolation instead of mostly returning zeros.
    z_axis = np.linspace(0.2, 2.2, n_iq, dtype=np.float64)
    x_axis = np.linspace(-(n_channels / 2) * pitch, (n_channels / 2) * pitch, n_channels) * 1e3

    z_idx = np.arange(n_iq, dtype=np.int32)[:, None, None]
    delay_indices = np.broadcast_to(z_idx, (n_iq, n_channels, n_tx)).copy()
    interpolation_weights = np.ones(
        (n_iq, n_channels, n_tx), dtype=np.complex64
    ) / np.float32(n_tx * n_channels * n_iq * n_channels * 2)

    probe = {
        "pitch": np.array(pitch, dtype=np.float64),
        "Fc": np.array(fc, dtype=np.float32),
        "nElements": np.array(n_channels, dtype=np.int32),
        "elementPosition": np.column_stack([
            (np.arange(n_channels) - (n_channels - 1) / 2) * pitch,
            np.zeros((n_channels, 4)),
        ]).astype(np.float32),
    }
    transmit = {
        "c0": np.array(c0, dtype=np.float64),
        "type": _char("planewave"),
        "steer": np.array([-8.0, 0.0, 8.0], dtype=np.float32),
        "apodization": np.ones(n_channels, dtype=np.float64),
        "transmitDelays": np.zeros((n_channels, 1, n_tx), dtype=np.float64),
    }
    receive = {
        "nSamples": np.array(n_samples, dtype=np.int32),
        "nSamplesIQ": np.array(n_iq, dtype=np.int32),
        "nTransmissions": np.array(n_tx, dtype=np.int32),
        "nRepeats": np.array(n_repeats, dtype=np.int32),
        "nChannels": np.array(n_channels, dtype=np.int32),
        "channel2ElementMap": np.arange(n_channels, dtype=np.int32),
        "nElements": np.array(n_channels, dtype=np.int32),
        "Fs": np.array(fs, dtype=np.float32),
        "samplingMode": _char("NS200BW"),
        "samplesPerWavelength": np.array(4, dtype=np.int32),
    }
    recon = {
        "bfDataType": _char("complex single"),
        "getBF": np.array(True, dtype=np.bool_),
        "getPDI": np.array(True, dtype=np.bool_),
        "nz": np.array(n_iq, dtype=np.int32),
        "nx": np.array(n_channels, dtype=np.int32),
        "filterFrequencies": np.array(False, dtype=np.bool_),
        "cropBF": np.array(False, dtype=np.bool_),
        "croppingROI": np.array([0, n_iq - 1, 0, n_channels - 1], dtype=np.int32),
        "extraVoxelsZ": np.array(0, dtype=np.int32),
        "extraVoxelsX": np.array(0, dtype=np.int32),
        "c0": np.array(c0, dtype=np.float32),
        "tgcVector": np.ones(n_iq, dtype=np.float32),
        "delayIndices": delay_indices,
        "interpolationWeights": interpolation_weights,
        "frequencyAxis": np.linspace(-fs / 4, fs / 4, n_iq, dtype=np.float32),
        "planewaveDelays": np.zeros((n_tx, 2), dtype=np.float32),
        "xAxis": x_axis.astype(np.float64),
        "zAxis": z_axis,
    }
    pdi = {
        "ensembleSize": np.array(n_repeats, dtype=np.int32),
        "threshold": np.array(0.4, dtype=np.float32),
        "shiftSize": np.array(n_repeats, dtype=np.int32),
        "cropPDI": np.array(False, dtype=np.bool_),
        "svdMethod": _char("Covariance"),
    }
    return probe, transmit, receive, recon, pdi


def make_rf(receive: dict) -> np.ndarray:
    """Create interleaved int16 IQ RF data as EchoFrame stores it."""
    n_iq = int(receive["nSamplesIQ"])
    n_samples = int(receive["nSamples"])
    n_tx = int(receive["nTransmissions"])
    n_repeats = int(receive["nRepeats"])
    n_channels = int(receive["nChannels"])
    rows_iq = n_iq * n_tx * n_repeats
    rf = np.zeros((n_samples * n_tx * n_repeats, n_channels), dtype=np.int16, order="F")

    t = np.arange(n_iq, dtype=np.float32)
    for ch in range(n_channels):
        center = 12 + ch * 2.2
        echo = 9000 * np.exp(-0.5 * ((t - center) / 2.5) ** 2)
        phase = ch * 0.25
        iq_real = echo * np.cos(phase)
        iq_imag = echo * np.sin(phase)
        for tx in range(n_tx):
            for rep in range(n_repeats):
                base = (rep * n_tx + tx) * n_iq
                amp = 1.0 + 0.02 * rep + 0.05 * tx
                rf[2 * (base + np.arange(n_iq)), ch] = np.round(amp * iq_real).astype(np.int16)
                rf[2 * (base + np.arange(n_iq)) + 1, ch] = np.round(amp * iq_imag).astype(np.int16)
    return rf


def write_rf(path: Path, rf: np.ndarray) -> None:
    """Write EchoFrame RF storage header plus one RF buffer."""
    payload = rf.ravel(order="F")
    header = struct.pack("<6Q", 1, 48, 1, payload.nbytes, 0, 0)
    path.write_bytes(header + payload.tobytes())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path, help="Output session directory")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    probe, transmit, receive, recon, pdi = make_specs()
    with h5py.File(args.out / "ScanParameters.mat", "w") as f:
        _write_struct(f, "ProbeSpec", probe)
        _write_struct(f, "TransmitSpec", transmit)
        _write_struct(f, "ReceiveSpec", receive)
        _write_struct(f, "ReconSpec", recon)
        _write_struct(f, "PDISpec", pdi)
    write_rf(args.out / "rf_acq.dat", make_rf(receive))
    print(f"Wrote {args.out / 'ScanParameters.mat'}")
    print(f"Wrote {args.out / 'rf_acq.dat'}")


if __name__ == "__main__":
    main()
