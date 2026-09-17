# beamformer/

The `beamformer` directory contains the core components required for Fourier-domain plane-wave beamforming in the EchoFrame system. It includes general-purpose classes, the Fourier imaging implementation, and the CUDA kernels needed for GPU acceleration.

## Directory Structure

### Files

- **beamformer.h / beamformer.t.hpp**
  - Defines the `Beamformer` class template, providing a base interface and common functionality for beamforming operations, including resource management and GPU memory handling.

- **beamformer_kernels.cu / beamformer_kernels.h**
  - Implements and declares CUDA kernels for RF data formatting, conversion, magnitude computation, and cropping. These are used throughout the beamforming and post-processing pipeline for efficient GPU-accelerated computation.

- **BF_formatter.h**
  - Defines the `BFFormatter` class template, which converts beamformed data to various output formats (e.g., real, half, bfloat16, B-mode) and manages GPU/host memory for output.

- **RF_formatter.h**
  - Defines the `RFFormatter` class template, which formats raw RF data for beamforming, manages device/host memory, and handles efficient transfer and conversion of RF data.

- **resources.h**
  - Declares the `ReceiveSpec` and `ReconSpec` structures, which describe RF data acquisition, reconstruction parameters, cropping, and output options.

- **echoframe_resources_bundle.h**
  - Defines the `EchoframeResources` structure, bundling all resource specifications (receive, recon, PDI, Fourier, storage) for initializing and configuring the EchoFrame system.

### Subdirectories

- **fourier_imaging/**
  - Contains the `FourierImaging` class template and related files for Fourier-based beamforming and reconstruction:
    - **fourier_imaging.h / fourier_imaging.t.hpp**: Implements the class and its template methods, managing cuFFT plans and GPU memory for advanced frequency-domain processing.
    - **fourier_imaging_kernels.cuh / fourier_imaging_kernels.cu**: Declares and implements CUDA kernels for TGC, delay application, interpolation, compounding, and scaling in Fourier imaging workflows.
    - **fourier_recon_spec.h**: Defines the `FourierReconSpec` structure, holding parameters and GPU pointers for Fourier-based reconstruction.

## Usage

To use the beamforming components within this directory, ensure that the `Beamformer` class and its associated templates and kernels are correctly integrated with your processing pipeline. The Fourier-based implementation in `fourier_imaging/` is the supported beamforming method.

