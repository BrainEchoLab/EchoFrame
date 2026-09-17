# python/

This directory provides the Python bindings and integration layer for the EchoFrame C++/CUDA backend. It enables Python users to access high-performance ultrasound processing, resource management, and data conversion utilities directly from Python, leveraging pybind11 and seamless resource translation.

## Directory Structure

### Files

- **__init__.py**
  - Python shim for the C++/CUDA extension. On Windows, it ensures all necessary CUDA DLL paths are added before importing the compiled module. Re-exports all symbols from the `echoframe` extension for convenient access.

- **echoframe_py_wrapper.cpp**
  - Implements the Python bindings for the EchoFrame CUDA backend using pybind11. Exposes the main EchoFrame resource structures and processing functions to Python, including a high-level `EchoFrame` class for resource management, processing, storage reinitialization, and parameter updates.

- **echoframe_py_conversions.cpp**
  - Provides helper functions for converting Python dictionaries (typically from pybind11) into native EchoFrame C++ resource structures. Enables the creation and initialization of `EchoframeResources` objects from Python, supporting seamless integration with Python-based workflows.

## Usage

To use the Python bindings:

1. Build the Python extension module using your build system (e.g., CMake with pybind11).
2. In your Python code, import the package and use the `EchoFrame` class and resource helpers:
   ```python
   import echoframe

   # Create resources from Python dicts
   resources = echoframe.make_resources(receive_dict, recon_dict, pdi_dict)

   # Initialize EchoFrame
   ef = echoframe.EchoFrame(resources, use_storage=False)

   # Process RF data
   pdi, bmode, bfcmp = ef.process(rf_buffer)
   ```

## Notes

- The bindings support resource management, processing, storage reinitialization, and parameter updates from Python.
- Conversion utilities ensure robust translation between Python dictionaries and C++ resource structures.
- On Windows, CUDA DLL paths are automatically managed for compatibility with both CUDA Toolkit and