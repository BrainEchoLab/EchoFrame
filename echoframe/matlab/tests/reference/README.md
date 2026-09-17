# tests/reference/

Fourier (f-k) beamforming written in plain MATLAB, mirroring the CUDA
implementation in `echoframe/cpp/src/beamformer/fourier_imaging`. It lives under
`tests/` because its job is to be a reference: a ground truth when debugging the
MEX, and a step-by-step reading of the algorithm.

It builds its tables the way the live path does, through
`initialize_image_reconstruction`, which calls `echoframe_setup_fourier` (in
`../../core/imaging/`). Reading the same tables the kernel reads is what makes
the comparison against the MEX meaningful.

## Directory Structure

### Files

- **fourier_beamforming_matlab.m**
  - Self-contained script. Simulates RF (or loads it), runs the whole
    beamforming chain in MATLAB, and can compare the result against the MEX
    output.

## Usage

Edit the parameters block at the top of the script, then run it.

`ECHOFRAME_PATH` must be set. `echoframe_mex` only needs to be built if you are
using the script to compare against the CUDA path.

## Notes

The pipeline the script walks through, per transmission and per repeat:

1. Convert int16 RF to complex single (BS100BW: interleaved I / Q).
2. Reshape to `[nSamplesIQ, nTransmissions, nRepeats, nChannels]`.
3. Apply the TGC vector along fast time.
4. FFT along fast time.
5. Apply the per-channel plane-wave delay phasor.

The setup tables it relies on (`delayIndices`, `interpolationWeights`,
`frequencyAxis`, `planewaveDelays`) are the same ones
`initialize_image_reconstruction` builds for the CUDA path, so the two are
comparable stage by stage.
