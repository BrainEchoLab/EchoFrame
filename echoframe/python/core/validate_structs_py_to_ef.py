# validate_echoframe_specs.py
# ---------------------------------------------------------------------------

from __future__ import annotations
import numpy as np

# ───────────────────────── expected schemas ────────────────────────────────
INT32   = np.int32
FLOAT   = np.float32
DOUBLE  = np.float64
CFLOAT  = np.csingle
CHAR =    np.char
LOGICAL = bool

_EXPECTED = {
    "ProbeSpec": [
        ("pitch",            DOUBLE),
        ("Fc",               FLOAT),
        ("nElements",       INT32),
        ("elementPosition", FLOAT),
    ],
    "TransmitSpec": [
        ("c0",               DOUBLE),
        ("type",             str),
        ("steer",           FLOAT),
        ("apodization",      DOUBLE),
        ("transmitDelays",   DOUBLE),
    ],
    "ReceiveSpec": [
        ("nSamples",             INT32),
        ("nSamplesIQ",           INT32),
        ("nTransmissions",       INT32),
        ("nRepeats",             INT32),
        ("nChannels",            INT32),
        ("channel2ElementMap",   INT32),
        ("nElements",            INT32),
        ("Fs",                   FLOAT),
        ("samplingMode",        str),
        ("samplesPerWavelength", INT32),
    ],
    "ReconSpec": [
        ("bfDataType",          str),
        ("getBF",               LOGICAL),
        ("getPDI",              LOGICAL),
        ("nz",                  INT32),
        ("nx",                  INT32),
        ("filterFrequencies",   LOGICAL),
        ("cropBF",              LOGICAL),
        ("croppingROI",         INT32),
        ("extraVoxelsZ",      INT32),
        ("extraVoxelsX",      INT32),
        ("c0",                  FLOAT),
        ("tgcVector",           FLOAT),
        ("delayIndices",        INT32),
        ("interpolationWeights",CFLOAT),
        ("frequencyAxis",       FLOAT),
        ("planewaveDelays",     FLOAT),
        ("xAxis",              DOUBLE),
        ("zAxis",              DOUBLE),
    ],
    "PDISpec": [
        ("ensembleSize",        INT32),
        ("threshold",           FLOAT),
        ("shiftSize",          INT32),
        ("cropPDI",             LOGICAL),
        ("svdMethod",          str),
    ],
}

# ─────────────────────────── helpers ───────────────────────────────────────
def _cast(value, dtype):
    """Cast scalar / ndarray to dtype, preserving arrays when needed."""
    if dtype is bool:
        return bool(value)
    if dtype is str:
        return str(value)

    # ── new: convert MATLAB compound {real,imag} → NumPy complex ──────────
    if dtype == np.complex64:
        if isinstance(value, np.ndarray) and value.dtype.names == ('real', 'imag'):
            value = value['real'] + 1j * value['imag']

    if np.isscalar(value):
        return dtype(value)
    return np.asarray(value, dtype=dtype)

def _validate_and_cast(name: str, spec: dict) -> dict:
    """Check mandatory fields & cast each to the expected dtype."""
    out = {}
    for field, dtype in _EXPECTED[name]:
        if field not in spec:
            raise ValueError(f"{name}: missing field '{field}'")

        value = spec[field]
        if value is None or (isinstance(value, (list, np.ndarray)) and len(value) == 0):
            raise ValueError(f"{name}: field '{field}' is empty / uninitialised")

        out[field] = _cast(value, dtype)
    return out

# ─────────────────────────── public API ────────────────────────────────────
def validate_specs(
    ProbeSpec: dict,
    TransmitSpec: dict,
    ReceiveSpec: dict,
    ReconSpec: dict,
    PDISpec: dict,
):
    ReceiveSpec["nElements"]         = ProbeSpec["nElements"]


    """Replicates MATLAB echoframe_validate_structs in Python."""
    ProbeSpec   = _validate_and_cast("ProbeSpec",   ProbeSpec)
    TransmitSpec= _validate_and_cast("TransmitSpec",TransmitSpec)
    ReceiveSpec = _validate_and_cast("ReceiveSpec", ReceiveSpec)
    ReconSpec   = _validate_and_cast("ReconSpec",   ReconSpec)
    PDISpec     = _validate_and_cast("PDISpec",     PDISpec)

    ReconSpec["croppingROI"] = ReconSpec["croppingROI"].astype(np.int32).ravel(order='C')
    ReconSpec["interpolationWeights"] = ReconSpec["interpolationWeights"].ravel(order='C')
    ReconSpec["delayIndices"] = ReconSpec["delayIndices"].ravel(order='C')
    ReconSpec["xAxis"] = ReconSpec["xAxis"].ravel(order='C')
    ReconSpec["zAxis"] = ReconSpec["zAxis"].ravel(order='C')



    return ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec
