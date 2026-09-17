# efcore/

The `efcore` directory contains the core classes and interfaces for the EchoFrame processing pipeline. This includes the main pipeline controller and C/C++ interface for external bindings. The code is designed for modularity, extensibility, and integration with both GUI and CLI workflows.

## Directory Structure

### Files

- **echoframe_core.h / echoframe_core.cu**
  - Declares and implements the `EchoFrameCore` class, the main interface for the EchoFrame processing pipeline. Responsible for managing beamforming, PDI processing, and storage. Handles initialization, processing of RF data, and output management.

- **echoframe_ci_interface.h / echoframe_ci_interface.cpp**
  - Declares and implements the C-compatible interface for EchoFrame, used for integration with Matlab MEX and Python bindings. Provides functions to create, destroy, and process EchoFrame objects, as well as to reinitialize storage and experiments, and update PDI thresholds.

## Key Concepts

- **EchoFrameCore**: The central class that manages the entire processing pipeline, including beamforming, PDI, and storage.
- **C Interface**: The `echoframe_ci_interface` files provide a C-compatible API for use in Matlab and Python, enabling easy integration and scripting.

## Usage

- Use `EchoFrameCore` directly in C++ applications for full control over the processing pipeline.
- Use the C interface (`echoframe_ci_interface.h`) for integration with Matlab or Python.

## Notes

- The code is modular and designed for extensibility, supporting both batch and real-time workflows.