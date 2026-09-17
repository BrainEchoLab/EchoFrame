# pdi/

The `pdi` directory contains the core implementation of Power Doppler Imaging (PDI) for the EchoFrame system. It provides the PDI class, CUDA kernels, and specification structures required to perform PDI on beamformed ultrasound data using GPU acceleration.

## Directory Structure

### Files

- **pdi_class.cuh / pdi_class.cu**
  - Declares and implements the `PDI` class, which performs Power Doppler Imaging on beamformed data using CUDA. Supports both full SVD (slower more precise) and covariance eigenvalue decomposition (faster and less precise) methods, manages memory on host and device, and provides methods for running PDI, updating thresholds, and retrieving results.

- **pdi_spec.h**
  - Defines the `PDISpec` structure, which holds parameters for the PDI algorithm, including ensemble size, threshold, shift size, cropping options, SVD method, and total data size.

- **pdi_kernels.cuh / pdi_kernels.cu**
  - Declares and implements CUDA kernels used in PDI processing. Includes kernels for thresholding singular values, converting real arrays to complex, calculating absolute values of complex matrices, and cropping 2D matrices.

## Usage

The PDI module is used within the EchoFrame pipeline to process beamformed data and extract Power Doppler information. It can be configured for different SVD methods and cropping options, and is designed for efficient GPU-accelerated computation.