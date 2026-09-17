# rf_io.py
from __future__ import annotations
import struct
import numpy as np
from pathlib import Path
from typing import BinaryIO, TypedDict


class HeaderSpec(TypedDict):
    version: int
    headerSize: int
    buffersStored: int
    effectiveBufferSize: int
    paddingBytes: int
    dataType: int  # NaN for version-0


# -------------------------------------------------------------------------
#  low-level helper – read exactly n uint64s   (little-endian on Windows)
# -------------------------------------------------------------------------
def _read_u64(f: BinaryIO, n: int) -> list[int]:
    buf = f.read(8 * n)
    if len(buf) != 8 * n:
        raise EOFError("file truncated while reading header")
    return list(struct.unpack(f"<{n}Q", buf))   # little-endian unsigned-64


# -------------------------------------------------------------------------
#  1.  header reader  (binary compatible with MATLAB version 0 / 1)
# -------------------------------------------------------------------------
def read_header(f: BinaryIO) -> HeaderSpec:
    version, = struct.unpack("<Q", f.read(8))
    if version == 0:
        hsize, nbuf, effsize, pad = _read_u64(f, 4)
        dtype_code = np.nan
    elif version == 1:
        hsize, nbuf, effsize, pad, dtype_code = _read_u64(f, 5)
    else:
        raise ValueError(f"Unknown header version {version}")

    # Seek to end-of-header so caller is ready to read first buffer
    f.seek(hsize, 0)

    return HeaderSpec(
        version=version,
        headerSize=hsize,
        buffersStored=nbuf,
        effectiveBufferSize=effsize,
        paddingBytes=pad,
        dataType=dtype_code,
    )


# -------------------------------------------------------------------------
#  2.  read first RF buffer into a (samples*TX*repeats, channels) array
# -------------------------------------------------------------------------
def _scalar(spec, key) -> int:
    """Read a scalar spec field (MATLAB stores scalars as 1x1 arrays)."""
    return int(np.asarray(spec[key]).ravel()[0])


def read_stored_rf(path: str | Path,
                   receive_spec) -> np.ndarray:
    """
    Parameters
    ----------
    path : str or Path
        File saved by EchoFrame storage.
    receive_spec : any object / dict exposing
        `.nSamples`, `.nTransmissions`, `.nRepeats`, `.nChannels`

    Returns
    -------
    rf : ndarray  shape = (nSamples*nTX*nRepeats, nChannels)  dtype=int16
    """
    nS  = _scalar(receive_spec, "nSamples")
    nTX = _scalar(receive_spec, "nTransmissions")
    nR  = _scalar(receive_spec, "nRepeats")
    nC  = _scalar(receive_spec, "nChannels")

    with open(path, "rb") as f:
        hdr = read_header(f)

        # read ONE buffer (like MATLAB loop `for i = 1:1`)
        count   = nS * nTX * nR * nC
        rf_flat = np.fromfile(f, dtype=np.int16, count=count)

        if rf_flat.size != count:
            raise EOFError("RF file ended prematurely")

        rf = rf_flat.reshape((nS * nTX * nR, nC), order="F")

        # skip padding bytes to mimic MATLAB seek
        f.seek(hdr["paddingBytes"], 1)

    return rf
