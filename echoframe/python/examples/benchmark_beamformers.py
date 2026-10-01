"""
Benchmark EchoFrame Fourier and ffdas DAS beamformers on one stored RF frame.

Requires an EchoFrame Python build. Pass a folder, *_rf.dat, or *_seq.mat file.
"""

from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

import numpy as np

from compare_beamformers import (
    add_das_spec,
    add_fourier_spec,
    ef,
    find_session_files,
    load_path,
    load_specs,
    normalize_specs,
    rf_io,
    validate_specs,
)


def _disable_pdi(recon: dict) -> dict:
    out = dict(recon)
    out["getBF"] = True
    out["getPDI"] = False
    return out


def _make_case(name: str, probe: dict, transmit: dict, receive: dict, recon: dict, pdi: dict):
    recon = add_fourier_spec(probe, transmit, receive, recon) if name == "Fourier" else add_das_spec(probe, transmit, receive, recon)
    recon = _disable_pdi(recon)
    _, _, receive, recon, pdi = validate_specs(probe, transmit, receive, recon, pdi)
    t0 = time.perf_counter()
    core = ef.EchoFrame(ef.make_resources(receive, recon, pdi), use_storage=False)
    return receive, core, time.perf_counter() - t0


def _time_process(core, rf: np.ndarray, warmup: int, iterations: int) -> list[float]:
    for _ in range(warmup):
        core.process(rf, start_storage=False)
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        core.process(rf, start_storage=False)
        times.append(time.perf_counter() - t0)
    return times


def _summarize(times: list[float]) -> str:
    return (
        f"median {statistics.median(times) * 1e3:.2f} ms, "
        f"mean {statistics.mean(times) * 1e3:.2f} ms, "
        f"min {min(times) * 1e3:.2f} ms, "
        f"std {(statistics.stdev(times) if len(times) > 1 else 0.0) * 1e3:.2f} ms"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=load_path)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--iterations", "-n", type=int, default=20)
    args = parser.parse_args()
    if not args.path or not args.path.exists():
        raise SystemExit("Pass a folder containing ScanParameters.mat/rf_acq.dat or an Effusive *_rf.dat file.")

    seq_path, rf_path = find_session_files(args.path)
    probe, transmit, receive, recon, pdi = load_specs(seq_path)
    probe, transmit, receive, recon, pdi = normalize_specs(probe, transmit, receive, recon, pdi)

    cases = {}
    for name in ("Fourier", "DAS"):
        receive_i, core, init_s = _make_case(name, probe, transmit, receive, recon, pdi)
        cases[name] = (receive_i, core, init_s)

    rf = rf_io.read_stored_rf(rf_path, cases["Fourier"][0]).ravel(order="F")
    print(f"RF: {rf_path}")
    print(f"Iterations: {args.iterations} (+{args.warmup} warmup), PDI disabled")
    for name, (_, core, init_s) in cases.items():
        times = _time_process(core, rf, args.warmup, args.iterations)
        print(f"{name:7} init {init_s * 1e3:.2f} ms, process {_summarize(times)}")


if __name__ == "__main__":
    main()
