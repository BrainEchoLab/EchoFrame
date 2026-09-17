function [ReconSpec] = echoframe_setup_fourier(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec)
% ECHOFRAME_SETUP_FOURIER  Fourier domain image reconstruction / f-k migration 
% setup for plane-wave imaging.
%
% Builds the per-(kz, kx, transmission) interpolation tables that map the
% acquired (t, x) IQ spectrum onto image (kz, kx) k-space, together with the
% plane-wave transmit delays consumed by the beamforming kernel.
%
% Interpolation along the temporal-frequency axis is nearest-neighbour bin
% selection with a linear-phase fractional-shift correction; k-space is
% apodised with a separable Tukey window in (kz, kx).
%
% Fields added to ReconSpec:
%   delayIndices          int32 (Nkz, Nkx, nTx)   0-based bin index
%   interpolationWeights  single(Nkz, Nkx, nTx)   complex weight: phase shift times spectrum mask
%   frequencyAxis         single(1, Nkz)          temporal frequency axis [Hz]
%   planewaveDelays       single(nTx, 2)          [delay_Ax, delay_b] per Tx
%
% References
%   Cheng, J. and Jian-yu Lu "Extended high-frame rate imaging method with limited-diffraction beams."
%     DOI: 10.1109/TUFFC.2006.1632680
%   Garcia, D. et al. Stolt's f-k migration for plane wave ultrasound imaging
%     DOI: 10.1109/TUFFC.2013.2771
%   Kruizinga, P. et al. "Plane-wave ultrasound beamforming using a nonuniform fast fourier transform".
%     DOI: 10.1109/TUFFC.2012.2509

% --- 1. Per-mode axial grid and frequency window ------------------------------
[Nz, freq_scale, freq_window, freq_mapping, freq_axis_shift] = ...
    mode_setup(ReceiveSpec);

Fs = single(ReceiveSpec.Fs);
dz = ReconSpec.c0 / (Fs * freq_scale);

frequency_axis = fftshift(-0.5:1/Nz:0.5-1/Nz) * Fs * freq_scale;
frequency_axis = frequency_axis(freq_window);
if freq_axis_shift
    frequency_axis = fftshift(frequency_axis);
end

% --- 2. Normalised k-space grid (factor 2 on kz: pulse-echo round trip) -------
Nx = single(ReceiveSpec.nChannels);
dx = single(ProbeSpec.pitch);
kx_vector = (-0.5:1/Nx:0.5-1/Nx) * 2*pi/dx;
kz_vector = (-0.5:1/Nz:0.5-1/Nz) * 4*pi/dz;
max_k     = max(abs([kx_vector kz_vector]));
kx_vector = single(fftshift(kx_vector ./ max_k));
kz_vector = single(fftshift(kz_vector ./ max_k));
gam       = 2/Nz;

kz_vector = fftshift(kz_vector(freq_window));
[kz, kx]  = ndgrid(kz_vector, kx_vector);

spectrum_weighting = tukeywin(numel(kz_vector), 0.2) * tukeywin(numel(kx_vector), 0.2)';
spectrum_weighting = fftshift(spectrum_weighting);

% --- 3. Vectorised over transmission angles -----------------------------------
theta = single(reshape(TransmitSpec.steer(:), 1, 1, []));
cosT  = cosd(theta);
sinT  = sind(theta);

% Plane-wave f-k mapping (image kz, kx -> normalised temporal k):
%   k_t = (kz^2 + kx^2) / (2 kz cos(theta) + 2 kx sin(theta))
k     = (kz.^2 + kx.^2) ./ (2*kz.*cosT + 2*kx.*sinT);
valid = abs(k) < abs(kz) * 2;
k     = 2 * k .* valid;
k(isnan(k)) = 0;

% Heuristic k-space extra mask which can be improved or removed. 
% See also: C.Chen et al. DOI: 10.1109/TUFFC.2018.2811865
spectrum_extra = ((2*kz.*cosT) .* (kx.*sinT)) < 0.01;
phase_window   = spectrum_weighting .* spectrum_extra;

% --- 4. Nearest-neighbour bin + linear-phase fractional-shift correction ------
% The phase-shift interpolation is one of the schemes
% provided in Fessler's image reconstruction toolbox (IRT) 
% DOI: 10.1109/TSP.2002.807005
kbin = k ./ gam;
koff = floor(kbin - 0.5);
kk   = mod(koff + 1, Nz) + 1;
idx  = kk - freq_window(1) + 1;

arg     = kbin - koff;
phase_w = exp(-1i*pi.*arg) .* phase_window;

nIQ = ReceiveSpec.nSamplesIQ;
oob = idx < 1 | idx > nIQ;
idx(oob) = 1;              % OOB clamped to bin 1; weight left attenuated by spectrum mask

idx = freq_mapping(idx);

scaling = single(ReceiveSpec.nTransmissions * ReconSpec.nz * ReconSpec.nx * 2);

ReconSpec.delayIndices         = int32(idx - 1);            % 0-based for C++
ReconSpec.interpolationWeights = single(phase_w ./ scaling);
ReconSpec.frequencyAxis        = single(frequency_axis);

% --- 5. Plane-wave transmit delays --------------------------------------------
% Assumes probe elements and receive channels share origin and pitch.
transmit_delays = TransmitSpec.transmitDelays(:,1,:) * 2*pi;   % us -> rad
delay_Ax        = median(diff(transmit_delays(find(TransmitSpec.apodization), :)));
mid_element     = floor(ProbeSpec.nElements / 2);
mid_channel     = floor(ReceiveSpec.nChannels / 2);
delay_b         = transmit_delays(mid_element, :) - double(mid_channel) * delay_Ax;
ReconSpec.planewaveDelays = single([delay_Ax' delay_b']);

end


% =============================================================================
% Helpers
% =============================================================================

function idx = wrap_to_one_based(n, N)
% Wrap integer n into the MATLAB index range 1..N.
idx = mod(n, N) + 1;
end


function [Nz, freq_scale, freq_window, freq_mapping, freq_axis_shift] = mode_setup(ReceiveSpec)
% Per-sampling-mode constants:
%   Nz               axial FFT length
%   freq_scale       multiplier on Fs for the axial sampling rate
%   freq_window      sub-band of the FFT to keep (lower:upper)
%   freq_mapping     mapping into the IQ data axis (length = nSamplesIQ)
%   freq_axis_shift  whether to fftshift frequencyAxis after sub-banding
nS_factor = round(4 / ReceiveSpec.samplesPerWavelength);
switch ReceiveSpec.samplingMode
    case 'BS50BW'
        Nz              = single(ReceiveSpec.nSamples * nS_factor);
        freq_scale      = 1;
        freq_window     = (ceil(Nz/4 - Nz/16) + 1):floor(Nz/4 + Nz/16);
        freq_mapping    = fftshift(1:Nz/8);
        freq_axis_shift = true;
    case 'BS67BW'
        Nz              = single(ReceiveSpec.nSamples * 2);
        freq_scale      = 2;
        lower           = Nz/2;
        freq_window     = lower:(lower + Nz/4 - 1);
        freq_mapping    = 1:Nz/4;
        freq_axis_shift = false;
    case 'BS100BW'
        Nz              = single(ReceiveSpec.nSamples * nS_factor);
        freq_scale      = 1;
        freq_window     = (ceil(Nz/4 - Nz/8) + 1):floor(Nz/4 + Nz/8);
        freq_mapping    = fftshift(1:Nz/4);
        freq_axis_shift = true;
    case 'NS200BW'
        Nz              = single(ReceiveSpec.nSamples * nS_factor);
        freq_scale      = 1;
        freq_window     = 1:Nz/2;
        freq_mapping    = 1:Nz/2;
        freq_axis_shift = false;
end
end
