# beamformer

Fourier (f-k) beamforming, and the formatters that move RF in and BF out.

The reconstruction tables this stage reads (`delayIndices`,
`interpolationWeights`, `frequencyAxis`, `planewaveDelays`) are precomputed on
the MATLAB side by `initialize_image_reconstruction`.

```{doxygennamespace} Beamform
:members:
```
