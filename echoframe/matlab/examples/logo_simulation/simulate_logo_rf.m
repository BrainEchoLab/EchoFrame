function [RF, ProbeSpec, TransmitSpec, ReceiveSpec] = simulate_logo_rf(ProbeSpec,TransmitSpec,ReceiveSpec,sim_method)
% simulate_logo_rf - Simulate plane-wave RF data from the EchoFrame logo phantom.
%
% Builds a 2D scatterer phantom from the EchoFrame logo image, simulates the
% RF returned at each transducer element via the Fourier method, applies the
% sampling-mode resampling, and returns int16 RF in the layout EchoFrame
% expects: [nSamples * nTransmissions * nRepeats, nChannels].
%
% Inputs (all required, except sim_method):
%   ProbeSpec     struct with fields: pitch, Fc, nElements
%   TransmitSpec  struct with fields: c0, steer, apodization
%   ReceiveSpec   struct with fields: nRepeats, Fs, nTransmissions, samplingMode
%   sim_method    'fast' (default, vectorized) or 'slow' (per-sensor reference)
%
% Outputs:
%   RF                          int16 acquired data (host)
%   ProbeSpec, TransmitSpec, ReceiveSpec  populated with derived fields
%                               (elementPosition, transmitDelays, nSamples,
%                               nChannels, channel2ElementMap,
%                               samplesPerWavelength, startDepthMm,
%                               actualEndDepthMm)
%
% Those derived fields are filled in only where the caller left a gap. A spec
% set that came out of a recording already carries the acquisition's own
% geometry, and overwriting it simulated a configuration the probe does not
% run -- the GE9LD's 1152 x 256 collapsed to 832 x 192, 54% of the data
% volume, while the benchmark still called the result GE9LD.

if nargin < 4 || isempty(sim_method)
    sim_method = 'fast';
end

rng(0); % deterministic scatterer layout and noise

%% Simulation constants
noise_std   = 1e-3;   % additive noise std (~ -60 dB vs. peak)
int16_scale = 2^14;   % signal scale into int16 (leaves 1 bit headroom)

%% Logo processing
logo_size = [128 128];
EF_logo = imresize(max(imread('echoFrame_logo.png'),[],3),logo_size,'lanczos2');
EF_logo(EF_logo<255) = 1;
EF_logo(EF_logo==255) = 0;
logo_physical_size = [30e-3 30e-3];
logo_physical_offset_z = 20e-3;
logo_physical_offset_x = 10e-3;
image_physical_size = [50e-3 50e-3];

%% Gridding
dx = logo_physical_size(2) / logo_size(2);
dz = logo_physical_size(1) / logo_size(1);
dt = 1 / ReceiveSpec.Fs;

x_vec_image = 0:dx:image_physical_size(2);
x_vec_image = x_vec_image - mean(x_vec_image);
z_vec_image = 0:dz:image_physical_size(1);
[Z,X] = ndgrid(z_vec_image,x_vec_image);

% The probe's own element positions when it has them; a uniform array from the
% pitch otherwise.
if isfield(ProbeSpec, 'elementPosition') && ~isempty(ProbeSpec.elementPosition) && ...
        size(ProbeSpec.elementPosition, 1) == ProbeSpec.nElements
    x_vec_acquisition = double(ProbeSpec.elementPosition(:,1))';
else
    x_vec_acquisition = (1:ProbeSpec.nElements) * ProbeSpec.pitch;
    x_vec_acquisition = x_vec_acquisition - mean(x_vec_acquisition);
    % Verasonics-style columns: [x, y, z, azimuth, elevation]
    ProbeSpec.elementPosition = [x_vec_acquisition(:), zeros(ProbeSpec.nElements, 4)];
end

% How many raw samples resample down to one post-resample sample. Needed here
% because a caller's ReceiveSpec.nSamples is post-resample, while everything
% between this point and the resampling switch below works in raw samples.
resample_factor = resample_factor_for(ReceiveSpec.samplingMode);

if isfield(ReceiveSpec, 'nSamples') && ~isempty(ReceiveSpec.nSamples)
    % A recording's own imaging depth. Simulate the raw axis that resamples
    % down to it, and leave the depths it was recorded with alone.
    nRawSamples = double(ReceiveSpec.nSamples) * resample_factor;
    keepDepths  = isfield(ReceiveSpec, 'actualEndDepthMm') && ...
                  ~isempty(ReceiveSpec.actualEndDepthMm);
else
    z_probe     = 0:dt:(image_physical_size(1)*2.5)/TransmitSpec.c0;
    nRawSamples = floor(length(z_probe)/64) * 64;
    keepDepths  = false;
end
z_vec_acquisition = (0:nRawSamples-1) * dt;

if ~keepDepths
    ReceiveSpec.startDepthMm = z_vec_acquisition(1) * TransmitSpec.c0 * 1e3;
    ReceiveSpec.actualEndDepthMm = (z_vec_acquisition(end) / 2) * TransmitSpec.c0 * 1e3;
end

% Raw for the simulation; the sampling-mode switch below divides it back down.
ReceiveSpec.nSamples = nRawSamples;

%% RF processing
logo_pixel_offset_z = round(logo_physical_offset_z / dz);
logo_pixel_offset_x = round(logo_physical_offset_x / dx);

EF_logo_us = zeros(size(X));
EF_logo_us([0:logo_size(1)-1]+logo_pixel_offset_z,[0:logo_size(2)-1]+logo_pixel_offset_x) = EF_logo;

scatter_indices = find(EF_logo_us);
sl = length(scatter_indices);
ridx = randperm(sl,sl);

%%
frequency_axis = [0:ReceiveSpec.nSamples/2-1 -ReceiveSpec.nSamples/2:-1] * ReceiveSpec.Fs / ReceiveSpec.nSamples;
tc   = gauspuls('cutoff',ProbeSpec.Fc,0.6,[],-40);
t    = -tc : dt : tc;
tx_pulse = gauspuls(t,ProbeSpec.Fc,0.6);

signal_template = zeros(1,ReceiveSpec.nSamples);
signal_template(1:length(tx_pulse)) = tx_pulse;
F_template = fft(signal_template,ReceiveSpec.nSamples);

Rf = zeros(ReceiveSpec.nSamples,ProbeSpec.nElements,ReceiveSpec.nTransmissions,ReceiveSpec.nRepeats,'single');
slt = floor(sl/ReceiveSpec.nRepeats);
scatter_range = [1:slt];
reverseStr = '';

for iRepeat = 1:ReceiveSpec.nRepeats
    scatter_range_temp = scatter_range + (iRepeat-1) * slt;
    scatter_indices_temp = scatter_indices(ridx(scatter_range_temp));
    scatter_image = zeros(size(X));
    scatter_image(scatter_indices_temp(:)) = 1;

    for iTransmit = 1:ReceiveSpec.nTransmissions
        planewave_angle = TransmitSpec.steer(iTransmit);
        tx_distance = Z(scatter_indices_temp) * cosd(planewave_angle) + X(scatter_indices_temp) * sind(planewave_angle);
        rx_distance = sqrt(Z(scatter_indices_temp).^2 + (X(scatter_indices_temp)-x_vec_acquisition).^2);
        txrx_delays = (tx_distance + rx_distance) / TransmitSpec.c0;

        if strcmp(sim_method, 'fast')
            sz = [1,1,length(frequency_axis)];
            Rf(:,:,iTransmit,iRepeat) = squeeze(real(ifft(mean(reshape(F_template,sz).*exp(-1j*2*pi*txrx_delays.*reshape(frequency_axis,sz))),[],3)))';
        else
            for iSensor = 1:ProbeSpec.nElements
                F_sensor =  F_template.' .* exp(-1j*2*pi*frequency_axis'*txrx_delays(:,iSensor)');
                Rf(:,iSensor,iTransmit,iRepeat) = real(ifft(mean(F_sensor,2)));
            end
        end
    end

    % Display the progress
    percentDone = 100 * iTransmit * iRepeat / (ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats);
    msg = sprintf('Simulating EchoFrame RF: %3.1f\n', percentDone);
    fprintf([reverseStr, msg]);
    reverseStr = repmat(sprintf('\b'), 1, length(msg));
end

%% Assign, adding noise, Reshape and resample
% nChannels is the RF array width, a system property rather than a probe one:
% a 192-element probe on a 256-channel Vantage delivers 256 columns, and
% channel2ElementMap says which of them carry elements. Only assume one column
% per element when the caller knows neither.
if ~isfield(ReceiveSpec, 'nChannels') || isempty(ReceiveSpec.nChannels)
    ReceiveSpec.nChannels = ProbeSpec.nElements;
end
if ~isfield(ReceiveSpec, 'channel2ElementMap') || isempty(ReceiveSpec.channel2ElementMap)
    ReceiveSpec.channel2ElementMap = [1:ProbeSpec.nElements]'-1; % start at 0 for C
end
Rf = permute(Rf,[1 3 4 2]);
Rf = reshape(Rf,ReceiveSpec.nSamples*ReceiveSpec.nTransmissions*ReceiveSpec.nRepeats,ProbeSpec.nElements);
noise = randn(size(Rf)) .* noise_std;
Rf = Rf./max(Rf(:)) + noise;
Rf = int16(Rf*int16_scale);

% Widen to the full channel count, elements landing where the map puts them.
% The unconnected columns get the same noise the connected ones carry, which is
% what the front end hands over.
if double(ReceiveSpec.nChannels) ~= ProbeSpec.nElements
    cols = double(ReceiveSpec.channel2ElementMap(:)) + 1;
    if numel(cols) ~= ProbeSpec.nElements || any(cols < 1) || ...
            any(cols > double(ReceiveSpec.nChannels)) || numel(unique(cols)) ~= numel(cols)
        error('simulate_logo_rf:badChannelMap', ...
              ['channel2ElementMap must hold %d distinct 0-based channel ' ...
               'indices below nChannels (%d); got %d entries in %g..%g.'], ...
              ProbeSpec.nElements, double(ReceiveSpec.nChannels), ...
              numel(cols), min(cols)-1, max(cols)-1);
    end
    wide = int16(randn(size(Rf,1), double(ReceiveSpec.nChannels)) * noise_std * int16_scale);
    wide(:, cols) = Rf;
    Rf = wide;
end

switch ReceiveSpec.samplingMode
    case 'BS50BW'
        ReceiveSpec.nSamples = ReceiveSpec.nSamples / 4;
        RF = zeros(ReceiveSpec.nSamples*ReceiveSpec.nTransmissions*ReceiveSpec.nRepeats,ReceiveSpec.nChannels,'int16');
        RF(1:2:end,:) = Rf(1:8:end,:);
        RF(2:2:end,:) = Rf(2:8:end,:);
        ReceiveSpec.samplesPerWavelength = 1; 
    case 'BS67BW'
        error('simulate_logo_rf:unsupportedMode', ...
              'Sampling mode ''BS67BW'' is not yet supported in the simulator.');
    case 'BS100BW'
        ReceiveSpec.nSamples = ReceiveSpec.nSamples / 2;
        RF = zeros(ReceiveSpec.nSamples*ReceiveSpec.nTransmissions*ReceiveSpec.nRepeats,ReceiveSpec.nChannels,'int16');
        RF(1:2:end,:) = Rf(1:4:end,:);
        RF(2:2:end,:) = Rf(2:4:end,:);
        ReceiveSpec.samplesPerWavelength = 2; 
    case 'NS200BW'
        ReceiveSpec.nSamples = ReceiveSpec.nSamples;
        RF = Rf;
        ReceiveSpec.samplesPerWavelength = 4; 
end

%% provide the transmit delays per element
% Recomputed only when the caller's table cannot describe this transmit set --
% a recording's delays are the ones the probe actually fired with.
if ~isfield(TransmitSpec,'transmitDelays') || isempty(TransmitSpec.transmitDelays) || ...
        numel(TransmitSpec.transmitDelays) ~= ProbeSpec.nElements * ReceiveSpec.nTransmissions
    TransmitSpec.transmitDelays = zeros(ProbeSpec.nElements,1,ReceiveSpec.nTransmissions);
    for i = 1:ReceiveSpec.nTransmissions
        delays = ProbeSpec.elementPosition(:,1) * tand(TransmitSpec.steer(i)) / TransmitSpec.c0;
        TransmitSpec.transmitDelays(:,1,i) = delays;
    end
end
end

function factor = resample_factor_for(mode)
% Raw samples per post-resample sample, for the modes the simulator supports.
switch mode
    case 'BS50BW'
        factor = 4;
    case 'BS100BW'
        factor = 2;
    case 'NS200BW'
        factor = 1;
    case 'BS67BW'
        error('simulate_logo_rf:unsupportedMode', ...
              'Sampling mode ''BS67BW'' is not yet supported in the simulator.');
    otherwise
        error('simulate_logo_rf:unknownMode', ...
              'Unknown samplingMode ''%s''.', mode);
end
end
