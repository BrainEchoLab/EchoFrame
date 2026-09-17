# echoframe_cli/

The `echoframe_cli` directory contains the command-line interface (CLI) utilities and tools for batch and offline processing of RF data using the EchoFrame system. This directory provides file readers, resource loaders, and the main CLI application for running EchoFrame workflows outside of a GUI environment.

## Directory Structure

### Files

- **cli.cpp**
  - Implements the main EchoFrame CLI application. Loads scan and processing parameters from a MATLAB `.mat` file, reads RF acquisition data from binary files, and processes each buffer using the EchoFrame backend. Provides a simple interface for offline processing and benchmarking.

- **read_rf.hpp / read_rf.cpp**
  - Declares and implements functions and structures for reading RF acquisition data buffers and header information from binary files. Includes utilities for extracting header metadata and loading individual RF data buffers for processing.

- **load_specs_from_mat.hpp / load_specs_from_mat.cpp**
  - Declares and implements functions for loading EchoFrame scan and processing specifications from a MATLAB `.mat` file using the matio library. Provides utilities for extracting and converting ReceiveSpec, ReconSpec, and PDISpec structures from MATLAB files and populating native EchoFrame resource structures.

## Usage

To use the CLI tools in this directory:

1. Prepare your scan and processing parameters in a MATLAB `.mat` file (using `-v7.3` format).
2. Acquire or prepare your RF data in the expected EchoFrame binary format.
3. Run the CLI application:
   ```sh
   ./echoframe_cli ScanParameters.mat rf_acq.dat
   ```
   This processes each RF buffer in the data file using the parameters from the `.mat` file and EchoFrame backend.

   To profile without a stored RF file, generate deterministic synthetic RF from
   the saved dimensions instead:
   ```sh
   ./echoframe_cli --benchmark ScanParameters.mat 1
   ```
   The optional iteration count defaults to one. The benchmark runs three
   warmups, then uses the two-output-equivalent path (no complex BF host
   transfer), making it suitable for Nsight Systems capture.

## Notes

- The CLI is intended for batch/offline processing and benchmarking.