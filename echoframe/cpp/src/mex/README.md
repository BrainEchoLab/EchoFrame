# mex/

This directory contains the CUDA source and header files required to build the MEX functions that interface with MATLAB. The MEX functions are essential for enabling real-time processing in the EchoFrame system, utilizing GPU acceleration for intensive computational tasks.

## Directory Structure

### Files

- **echoframe_mex.cu**
  - Implements the MATLAB MEX gateway for the EchoFrame core. Provides the entry point for MATLAB to interact with the EchoFrame C++/CUDA backend, supporting initialization, processing, storage management, and destruction of EchoFrame objects. Translates MATLAB data structures and commands into native EchoFrame operations for high-performance ultrasound processing from MATLAB.

- **echoframe_mex.h**
  - Header for `echoframe_mex.cu`. Declares the MEX entry point, cleanup function, and utility functions for converting MATLAB data to C++ types and building MATLAB output arrays from EchoFrame GPU results.

- **mex_resources_conversions.h / mex_resources_conversions.cpp**
  - Declares and implements functions for converting MATLAB `mxArray` resource structures into native EchoFrame C++ structures. Used by the MEX interface to initialize and update core processing resources, storage specifications, and experiment parameters from MATLAB inputs.

## Usage

To use the MEX interface:

1. Build the MEX via CMake with `-DEF_BUILD_MEX=ON` (see the main README for the full build).
2. In MATLAB, call the compiled MEX function with the appropriate command and arguments, e.g.:
   ```matlab
   echoframe_mex('init', receiveSpec, reconSpec, pdiSpec, ...);
   [PDI, Bmode, BF] = echoframe_mex('process', rfBuffer, saveFlag);
   echoframe_mex('destroy');
   ```
   `process` optionally returns a 4th output — a per-stage timing struct (seconds)
   with fields `rf_transfer`, `rf_formatting`, `beamforming`, `bf_formatting`,
   `pdi_processing`, `pdi_transfer`, `bf_storage`, `pdi_storage`, `total`:
   ```matlab
   [PDI, Bmode, BF, timings] = echoframe_mex('process', rfBuffer, saveFlag);
   ```
   `init` and the re-init commands take the BF, PDI and RF-time-tag storage
   specs, optionally followed by `RFStorageSpec` for raw RF. See
   [`documentation/api/mex.md`](../../../../documentation/api/mex.md) for the
   argument positions.
3. The MEX function will handle resource conversion, processing, and output construction, returning results directly to MATLAB.

## Notes

- The MEX interface supports both full pipeline and PDI-only workflows.
- Conversion utilities ensure robust translation between MATLAB and C++ data structures.
- Error handling is robust, with informative messages for invalid commands or data.