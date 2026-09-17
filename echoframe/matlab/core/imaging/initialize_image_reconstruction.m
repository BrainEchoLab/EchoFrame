function [ProbeSpec,ReceiveSpec,ReconSpec] = initialize_image_reconstruction(ProbeSpec,TransmitSpec,ReceiveSpec,ReconSpec)
%INITIALIZE_IMAGE_RECONSTRUCTION  Size the output grid and precompute the beamforming tables.
% Called by the acquisition/processing scripts (e.g. echoframe_acquisition_start.m,
% generate_echoframe_demo_data.m).
%
%  [ProbeSpec, ReceiveSpec, ReconSpec] = INITIALIZE_IMAGE_RECONSTRUCTION(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec)
%  fills in the ReconSpec fields the CUDA core reads. ProbeSpec and ReceiveSpec
%  are returned unchanged; they are inputs only.
%
%  Sets on ReconSpec::
%
%    nz, nx        output image size. nz = ReceiveSpec.nSamplesIQ + extraVoxelsZ,
%                  nx = ReceiveSpec.nChannels + extraVoxelsX, each rounded up to
%                  even. The extraVoxels* fields are the only way to change it.
%    tgcVector     fast-time gain curve: a flat window with the transmit and the
%                  far end zeroed, smoothed with a gaussian.
%    imageSize     [nz nx].
%    xAxis, zAxis  display axes in mm.
%
%  The beamforming tables themselves (delayIndices, interpolationWeights,
%  frequencyAxis, planewaveDelays) come from echoframe_setup_fourier, which this
%  function calls.
%
%  Call this before echoframe_validate_structs: the core reads tables that only
%  exist once this has run.
%
%  See also ECHOFRAME_SETUP_FOURIER, ECHOFRAME_VALIDATE_STRUCTS.

% extraVoxelsZ/X pad the output grid above the input size; negative values
% (grid smaller than the sample/channel count) would need a truncation path the
% beamformer does not implement, so reject them here.
if ReconSpec.extraVoxelsZ < 0 || ReconSpec.extraVoxelsX < 0
    error('initialize_image_reconstruction:negativeExtraVoxels', ...
          'extraVoxelsZ and extraVoxelsX must be >= 0 (grid truncation is not supported).');
end

Nz = ReceiveSpec.nSamplesIQ + ReconSpec.extraVoxelsZ;
Nz = Nz + rem(Nz,2);
Nx = ReceiveSpec.nChannels + ReconSpec.extraVoxelsX;
Nx = Nx + rem(Nx,2);
ReconSpec.nz = int32(Nz);
ReconSpec.nx = int32(Nx);

% Digital TGC: f-k migration uses FFTs, which assume the record is periodic.
% The start of the record holds the transmit signal, which is very high energy
% and often clipped, and the periodic extension puts it right next to the quiet
% end of the record. That jump leaks across the spectrum and shows up as
% periodic artefacts in the image, caused by the periodicity assumption of the
% FFT rather than by anything in the tissue.
% So: zero the first 10 wavelengths (transmit + ringdown) and the last 3, then
% smooth the mask with a short Gaussian so the weighting vector stays low-frequency.
%
% TODO: the mask extent is hardcoded (10 and 3 wavelengths, 30 sample kernel).
% It should follow from the plane wave angle, sampling frequency and the 
% pulse length instead. The pulse length sets how long the transmit signal 
% contaminates the record, and the steering angle sets how much later it arrives 
% on one side of the aperture than on the other. Ideally this becomes a two 
% dimensional weighting matrix (samples x channels) where the TGC vector is 
% delayed per channel according to the plane wave angle, so the mask follows 
% the actual wavefront instead of masking too much on one side and too little 
% on the other.
%
temp_kernel = gausswin(30,5)';
temp_kernel = temp_kernel./sum(temp_kernel); 
zeros_samples_start = zeros(1,round(10 * ReceiveSpec.samplesPerWavelength));
zeros_samples_end = zeros(1,round(3 * ReceiveSpec.samplesPerWavelength));
tgc = ones(1,ReceiveSpec.nSamplesIQ - length(zeros_samples_start) - length(zeros_samples_end));
ReconSpec.tgcVector = convn([zeros_samples_start tgc zeros_samples_end],temp_kernel,'same');

% Get the Fourier interpolation lookup tables  
ReconSpec = echoframe_setup_fourier(ProbeSpec,TransmitSpec,ReceiveSpec,ReconSpec);

nElementRf                   = double(ReceiveSpec.nChannels);
ReconSpec.xAxis              = linspace(-(nElementRf/2)*ProbeSpec.pitch, (nElementRf/2)*ProbeSpec.pitch, Nx) * 1e3;
ReconSpec.zAxis              = linspace(ReceiveSpec.startDepthMm,ReceiveSpec.startDepthMm + ReceiveSpec.actualEndDepthMm, Nz);
ReconSpec.imageSize           = [Nz Nx];
