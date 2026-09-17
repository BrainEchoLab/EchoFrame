"""CUDA-free tests for the pure-Python helpers in echoframe/python/core.

None of these import the compiled `echoframe` module, so they run anywhere --
including CI on a machine with no GPU and no CUDA toolkit. They are the Python
counterpart of echoframe/matlab/tests/verify_core_headless.m.

Run with:
    pytest echoframe/python/tests

Not covered: read_BF.py and read_PDI.py execute at import time (no
`if __name__ == "__main__"` guard), so they cannot be imported for testing
without refactoring them into functions first.

Known asymmetry, deliberately not tested: MATLAB's read_stored_RF takes a
0-based BUFID and can return any buffer in a recording; rf_io.read_stored_rf
takes no such argument and always returns the first. The Python helper is not
intended to walk multi-buffer recordings, so the tests below assert what it
does return rather than pretending the capability exists.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

CORE = Path(__file__).resolve().parents[1] / "core"


def _load(name: str):
    """Import a module from echoframe/python/core by path, without packaging it."""
    spec = importlib.util.spec_from_file_location(name, CORE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


rf_io = _load("rf_io")
rpb = _load("remove_padding_bytes")
validate = _load("validate_structs_py_to_ef")


# ────────────────────────────── helpers ────────────────────────────────────
def write_dat(path: Path, *, version: int, buffers: int, eff: int, pad: int,
              dtype, elems_per_value: int = 1, data_type_code: int | None = None,
              header_size: int | None = None):
    """Write a storage-format .dat and return the per-buffer payloads.

    header_size defaults to the minimum the fields occupy, but real recordings
    use the sector size (512 was observed on ext4 under WSL, 4096 is typical)
    with the remainder zero-filled -- see computeHeaderSize() in
    LinuxFileIO/WindowsFileIO. Tests should cover both.
    """
    n_fields = 6 if version == 1 else 5
    if header_size is None:
        header_size = n_fields * 8
    assert header_size >= n_fields * 8, "header_size cannot be smaller than the fields"

    header = [version, header_size, buffers, eff, pad]
    if version == 1:
        header.append(data_type_code if data_type_code is not None else 2)
    payloads = []
    with open(path, "wb") as f:
        f.write(np.array(header, dtype=np.uint64).tobytes())
        f.write(b"\x00" * (header_size - n_fields * 8))   # zero-fill to headerSize
        for b in range(buffers):
            n = eff * elems_per_value
            v = (np.arange(n, dtype=np.int64) + b * 1000).astype(dtype)
            payloads.append(v)
            f.write(v.tobytes())
            f.write(b"\x00" * pad)
    return payloads


# ────────────────────────────── rf_io.read_header ──────────────────────────
@pytest.mark.parametrize("header_size", [None, 512, 4096],
                         ids=["minimum", "sector-512", "sector-4096"])
@pytest.mark.parametrize(
    "version, has_dtype",
    [(1, True), (0, False)],
    ids=["version1-6-fields", "version0-5-fields"],
)
def test_read_header_both_versions(tmp_path, version, has_dtype, header_size):
    """headerSize is the sector size in real recordings, not the field count.

    A reader that assumed the payload began right after the fields would pass
    at the minimum and fail on every file the storage layer writes, so all
    three sizes are exercised.
    """
    p = tmp_path / "h.dat"
    write_dat(p, version=version, buffers=3, eff=64, pad=64, dtype=np.float32,
              header_size=header_size)
    expected_header_size = header_size if header_size is not None else (6 * 8 if version == 1 else 5 * 8)

    with open(p, "rb") as f:
        h = rf_io.read_header(f)
        pos_after = f.tell()

    assert int(h["version"]) == version
    assert int(h["headerSize"]) == expected_header_size
    assert int(h["buffersStored"]) == 3
    assert int(h["effectiveBufferSize"]) == 64
    assert int(h["paddingBytes"]) == 64
    # read_header must leave the file at the first data buffer
    assert pos_after == expected_header_size
    if has_dtype:
        assert int(h["dataType"]) == 2


def test_read_header_rejects_unknown_version(tmp_path):
    p = tmp_path / "bad.dat"
    p.write_bytes(np.array([7, 48, 1, 1, 0, 2], dtype=np.uint64).tobytes())
    with open(p, "rb") as f:
        with pytest.raises(Exception):
            rf_io.read_header(f)


# ────────────────────────────── rf_io.read_stored_rf ───────────────────────
class _ReceiveSpec(dict):
    """read_stored_rf accepts anything exposing the four sizing fields."""
    __getattr__ = dict.__getitem__


def test_read_stored_rf_reads_the_first_buffer(tmp_path):
    """read_stored_rf returns buffer 0, shaped (nS*nTX*nR, nC) in Fortran order.

    Buffer 0 is all this function can return: unlike MATLAB's
    read_stored_RF(RFPath, ReceiveSpec, BUFID), the Python reader takes no
    buffer index and always reads the one immediately after the header. That is
    a deliberate limitation of the Python helper, not an oversight in this test
    -- a recording holding several buffers can only be walked from MATLAB, or
    by seeking manually. The file below holds three buffers with distinct
    contents so that "returns the first" is actually asserted rather than
    assumed.
    """
    n_samples, n_tx, n_repeats, n_channels = 16, 3, 4, 8
    rows = n_samples * n_tx * n_repeats
    eff = rows * n_channels

    p = tmp_path / "rf_acq.dat"
    payloads = write_dat(p, version=1, buffers=3, eff=eff, pad=64,
                         dtype=np.int16, data_type_code=1, header_size=512)

    spec = _ReceiveSpec(nSamples=n_samples, nTransmissions=n_tx,
                        nRepeats=n_repeats, nChannels=n_channels)
    rf = rf_io.read_stored_rf(p, spec)

    assert rf.dtype == np.int16
    assert rf.shape == (rows, n_channels)
    # column-major unravel must reproduce the bytes that were written
    assert np.array_equal(rf.ravel(order="F"), payloads[0].astype(np.int16))
    # and it must be buffer 0 specifically, not whichever one happens to land
    assert not np.array_equal(rf.ravel(order="F"), payloads[1].astype(np.int16))


def test_read_stored_rf_raises_on_a_truncated_file(tmp_path):
    n_samples, n_tx, n_repeats, n_channels = 16, 3, 4, 8
    eff = n_samples * n_tx * n_repeats * n_channels

    p = tmp_path / "short.dat"
    write_dat(p, version=1, buffers=1, eff=eff, pad=0,
              dtype=np.int16, data_type_code=1)
    # lop off the last quarter of the payload
    raw = p.read_bytes()
    p.write_bytes(raw[: 48 + (eff * 2) // 4])

    spec = _ReceiveSpec(nSamples=n_samples, nTransmissions=n_tx,
                        nRepeats=n_repeats, nChannels=n_channels)
    with pytest.raises(EOFError):
        rf_io.read_stored_rf(p, spec)


# ────────────────────── remove_padding_bytes.clean_file ────────────────────
def test_clean_file_strips_padding_and_zeroes_the_field(tmp_path):
    eff, buffers, pad = 64, 3, 64
    src = tmp_path / "orig.dat"
    payloads = write_dat(src, version=1, buffers=buffers, eff=eff, pad=pad,
                         dtype=np.float32, elems_per_value=2, data_type_code=3)

    dst = tmp_path / "clean.dat"
    rpb.clean_file(str(src), str(dst))

    raw = dst.read_bytes()
    header = np.frombuffer(raw[:48], dtype=np.uint64)
    body = np.frombuffer(raw[48:], dtype=np.float32)
    expected = np.concatenate(payloads)

    assert int(header[4]) == 0, "padding field must be zeroed in the cleaned file"
    assert int(header[2]) == buffers, "buffersStored must be preserved"
    assert int(header[3]) == eff, "effectiveBufferSize must be preserved"
    assert len(raw) == 48 + expected.nbytes, "cleaned size must drop exactly the padding"
    assert np.array_equal(body, expected), "payload must survive byte-for-byte"


def test_clean_file_is_idempotent_on_an_unpadded_file(tmp_path):
    """Cleaning a file that has no padding must be a faithful copy."""
    src = tmp_path / "nopad.dat"
    payloads = write_dat(src, version=1, buffers=2, eff=32, pad=0,
                         dtype=np.float32, elems_per_value=2, data_type_code=3)
    dst = tmp_path / "nopad_clean.dat"
    rpb.clean_file(str(src), str(dst))

    body = np.frombuffer(dst.read_bytes()[48:], dtype=np.float32)
    assert np.array_equal(body, np.concatenate(payloads))


# ────────────────────── validate_structs_py_to_ef ──────────────────────────
def _specs():
    n_el, nz, nx, n_tx = 128, 256, 256, 3
    probe = {
        "pitch": 300e-6,
        "Fc": 5e6,
        "nElements": n_el,
        "elementPosition": np.zeros((n_el, 5), dtype=np.float32),
    }
    transmit = {
        "c0": 1540.0,
        "type": "planewave",
        "steer": np.array([-10, 0, 10], dtype=np.float32),
        "apodization": np.ones(n_el),
        "transmitDelays": np.zeros((n_el, 1, n_tx)),
    }
    receive = {
        "nSamples": 512, "nSamplesIQ": 256, "nTransmissions": n_tx,
        "nRepeats": 40, "nChannels": 128,
        "channel2ElementMap": np.arange(n_el, dtype=np.int32),
        "Fs": 20e6, "samplingMode": "BS100BW", "samplesPerWavelength": 2,
    }
    recon = {
        "bfDataType": "complex single", "getBF": True, "getPDI": True,
        "nz": nz, "nx": nx, "filterFrequencies": False, "cropBF": False,
        "croppingROI": np.array([0, nz, 0, nx], dtype=np.int32),
        "extraVoxelsZ": 0, "extraVoxelsX": 128, "c0": 1540.0,
        "tgcVector": np.ones(nz, dtype=np.float32),
        "delayIndices": np.zeros((nz, nx, n_tx), dtype=np.int32),
        "interpolationWeights": np.zeros((nz, nx, n_tx), dtype=np.csingle),
        "frequencyAxis": np.zeros(nz, dtype=np.float32),
        "planewaveDelays": np.zeros(n_tx, dtype=np.float32),
        "xAxis": np.zeros(nx), "zAxis": np.zeros(nz),
    }
    pdi = {
        "ensembleSize": 40, "threshold": 0.4, "shiftSize": 40,
        "cropPDI": False, "svdMethod": "Covariance",
    }
    return probe, transmit, receive, recon, pdi


def test_validate_specs_derives_and_casts():
    probe, transmit, receive, recon, pdi = _specs()
    probe, transmit, receive, recon, pdi = validate.validate_specs(
        probe, transmit, receive, recon, pdi)

    # mirrors the MATLAB validator: nElements is derived, never set by hand
    assert int(receive["nElements"]) == 128
    assert receive["nSamples"].dtype == np.int32
    assert pdi["threshold"].dtype == np.float32
    assert bool(recon["getBF"]) is True
    # croppingROI is flattened C-order for the core
    assert recon["croppingROI"].ndim == 1
    assert recon["croppingROI"].dtype == np.int32


def test_validate_specs_rejects_a_missing_field():
    probe, transmit, receive, recon, pdi = _specs()
    del receive["samplingMode"]
    with pytest.raises(Exception):
        validate.validate_specs(probe, transmit, receive, recon, pdi)


def test_validate_specs_rejects_an_empty_field():
    probe, transmit, receive, recon, pdi = _specs()
    recon["tgcVector"] = np.array([], dtype=np.float32)
    with pytest.raises(ValueError):
        validate.validate_specs(probe, transmit, receive, recon, pdi)


# ──────────────────── cross-check against a real recording ─────────────────
def _find_real_recording() -> Path | None:
    """A bf_acq.dat the C++ storage layer actually wrote, if one is around.

    Every other test in this file reads a file it wrote itself, from one
    understanding of the storage format. If that understanding were wrong, the
    writer and these tests would disagree while everything still passed. This
    reads the real thing when it is available: EF_REAL_RECORDING (file or
    folder), else anything a storage harness left under the temp directory.
    """
    import os
    import tempfile

    env = os.environ.get("EF_REAL_RECORDING")
    if env:
        cand = Path(env)
        if cand.is_file():
            return cand
        if cand.is_dir():
            found = sorted(cand.rglob("bf_acq.dat"))
            if found:
                return found[0]

    found = sorted(Path(tempfile.gettempdir()).rglob("bf_acq.dat"))
    return found[-1] if found else None


def test_real_recording_layout_closes():
    """header + buffers x (elements x 8 + padding) must equal the file size.

    bf_acq.dat holds complex single, so 8 bytes per element -- the arithmetic
    every reader in the repo depends on. This also pins headerSize to whatever
    the writer really used rather than what the tests assume.
    """
    real = _find_real_recording()
    if real is None:
        pytest.skip("no real recording available "
                    "(set EF_REAL_RECORDING or run a storage test first)")

    with open(real, "rb") as f:
        h = rf_io.read_header(f)
        pos_after = f.tell()

    assert int(h["version"]) in (0, 1)
    assert int(h["headerSize"]) >= 40
    assert int(h["headerSize"]) % 8 == 0, "headerSize must be whole uint64s"
    assert pos_after == int(h["headerSize"]), \
        "read_header must land on the first data buffer"
    assert int(h["buffersStored"]) > 0

    predicted = (int(h["headerSize"])
                 + int(h["buffersStored"])
                 * (int(h["effectiveBufferSize"]) * 8 + int(h["paddingBytes"])))
    assert predicted == real.stat().st_size, (
        f"layout does not close for {real}: predicted {predicted}, "
        f"file is {real.stat().st_size}")
