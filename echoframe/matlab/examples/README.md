# echoframe/matlab/examples/

Runnable examples for EchoFrame. Each subdirectory has its own README with the
details; this is the index.

Every example follows the same shape: a parameters block at the top of the
script, then run it. Each script's header comment lists its prerequisites.

## Directory Structure

### Subdirectories

- **logo_simulation/**
  - Start here. Simulates plane-wave RF from a phantom built out of the
    EchoFrame logo, beamforms it and computes PDI on the GPU, and shows B-mode
    and PDI side by side. Needs no hardware and no stored data.

- **process_echoframe_data/**
  - Replay stored data through the pipeline offline. The generator that produces
    a demo dataset for these to read lives in `../tests/data/`; the Python
    equivalent of this replay is in `echoframe/python/examples/`.

- **verasonics/**
  - Verasonics Vantage integration: a live acquisition example, and a script
    that processes a workspace saved from a stock Verasonics example.

Two things that used to live here have moved, since they are not demos: the
plain-MATLAB reference beamformer is now `../tests/reference/`, and the
throughput benchmarks are now `../benchmarks/`.

## Usage

Set the `ECHOFRAME_PATH` environment variable and build `echoframe_mex` before
running any of these. See the main README for build instructions.

Running `logo_simulation.m` first is the quickest way to check that the path and
the MEX are set up correctly.
