function ReconSpec = echoframe_setup_das(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec)
%ECHOFRAME_SETUP_DAS  Build ffdas delay-and-sum geometry tables.
% EchoFrame IQ samples are depth-like: one complex sample advances the image
% depth by c/Fs. Geometric DAS sums transmit and receive paths, so scale
% positions by Fs/(2c) to map the two-way path onto EchoFrame's sample axis.

if ~strcmpi(TransmitSpec.type, 'planewave')
    error('echoframe_setup_das:unsupportedTransmit', ...
          'DAS setup currently supports TransmitSpec.type = ''planewave'' only.');
end

nz = double(ReconSpec.nz);
nx = double(ReconSpec.nx);
nTx = double(ReceiveSpec.nTransmissions);
fsOverTwoC = single(ReceiveSpec.Fs) / (2 * single(ReconSpec.c0));
startSamples = single(ReconSpec.zAxis(1) * 1e-3) * 2 * fsOverTwoC;

nActive = double(ProbeSpec.nElements);
channelX = ((0:nActive-1)' - (nActive-1)/2) * double(ProbeSpec.pitch);
ReconSpec.dasChannelPositions = single([channelX'; zeros(2, nActive)]) * fsOverTwoC;

[xGridMm, zGridMm] = meshgrid(double(ReconSpec.xAxis), double(ReconSpec.zAxis));
xGrid = xGridMm * 1e-3;
zGrid = zGridMm * 1e-3;
ReconSpec.dasVoxelPositions = single([xGrid(:)'; zeros(1, nz * nx); zGrid(:)']) * fsOverTwoC;

receiveSamples = sqrt((xGrid(:) - channelX').^2 + zGrid(:).^2) * fsOverTwoC;
minOffset = reshape(1 - min(receiveSamples, [], 2), nz, nx);

% Planewave TX path is z*cos(theta)+x*sin(theta) plus the per-tx bulk delay
% Verasonics stores by clamping negative TX.Delay to zero. That bulk is in
% the RF; omitting it desynchronizes steered txs and blurs mid-depth. Do not
% rebuild the wavefront via min-over-elements or clip maxOffset: the
% geometric path plus bulk matches min-over(active) to <0.01 sample, and
% ffdas already zeros channel reads past the IQ buffer so deep rows keep
% correct depth with partial aperture.
useTransmitDelays = isfield(TransmitSpec, 'transmitDelays') && any(TransmitSpec.transmitDelays(:) ~= 0);
if useTransmitDelays
    txDelays = double(TransmitSpec.transmitDelays);
    if ndims(txDelays) == 3
        txDelays = squeeze(txDelays(:, 1, :));
    end
    if size(txDelays, 1) == nTx
        txDelays = txDelays.';
    end
    active = double(TransmitSpec.apodization(:)) ~= 0;
end

ReconSpec.dasOffsets = zeros(nz, nx, nTx, 'single');
for iTx = 1:nTx
    theta = double(TransmitSpec.steer(iTx));
    sinTheta = sind(theta);
    if useTransmitDelays
        residual = txDelays(:, iTx) - channelX * sinTheta / double(ReconSpec.c0);
        bulk = median(residual(active));
    else
        bulk = 0;
    end
    offsets = (zGrid * cosd(theta) + xGrid * sinTheta) * fsOverTwoC ...
        + bulk * double(ReceiveSpec.Fs) / 2 - startSamples;
    ReconSpec.dasOffsets(:, :, iTx) = single(max(offsets, minOffset));
end

fNumber = directivity_f_number(ProbeSpec, ReconSpec);
cosAlpha = single(cos(atan(1 / (2 * fNumber))));

channelXRow = reshape(channelX, 1, 1, []);
directivityMask = single(zGrid ./ sqrt((xGrid - channelXRow).^2 + zGrid.^2) > double(cosAlpha));
ReconSpec.dasWeights = zeros(nz, nx, nTx, 'single');
for iTx = 1:nTx
    phase = double(ReconSpec.dasOffsets(:, :, iTx)) + reshape(receiveSamples, nz, nx, []);
    valid = directivityMask & single(phase >= 0 & phase < double(ReceiveSpec.nSamplesIQ - 1));
    counts = sum(valid, 3);
    ReconSpec.dasWeights(:, :, iTx) = single(counts > 0) ./ single(max(1, nTx * counts));
end

% RFFormatter stores IQ as I - iQ, so ffdas' usual negative phase rotation
% is conjugated here.
ReconSpec.dasWavenum = single(4 * pi * double(ProbeSpec.Fc) / double(ReceiveSpec.Fs));
ReconSpec.dasAlgorithm = int32(1);
ReconSpec.dasComputeType = int32(0);
ReconSpec.dasSourceDirections = single(repmat([0; 0; 1; cosAlpha], 1, nActive));
end

function fNumber = directivity_f_number(ProbeSpec, ReconSpec)
% -3 dB piston-element directivity cutoff from Perrot et al. Defaults are
% deliberately boring: pitch as element width, Fc as highest useful frequency.
width = getfield_default(ProbeSpec, {'elementWidth', 'ElementWidth', 'width'}, ProbeSpec.pitch);
fmax = getfield_default(ProbeSpec, {'fmax', 'Fmax'}, ProbeSpec.Fc);
if isfield(ProbeSpec, 'bandwidth')
    fmax = double(ProbeSpec.Fc) + double(ProbeSpec.bandwidth) / 2;
elseif isfield(ProbeSpec, 'bandwidthFraction')
    fmax = double(ProbeSpec.Fc) * (1 + double(ProbeSpec.bandwidthFraction) / 2);
end
lambda = double(ReconSpec.c0) / double(fmax);
theta = linspace(0, pi/2 - 1e-3, 4096);
directivity = abs(cos(theta) .* sinc(double(width) / lambda * sin(theta)));
idx = find(directivity <= 0.71, 1, 'first');
if isempty(idx)
    alpha = theta(end);
else
    alpha = theta(idx);
end
fNumber = 1 / (2 * tan(alpha));
end

function value = getfield_default(s, names, defaultValue)
value = defaultValue;
for i = 1:numel(names)
    if isfield(s, names{i}) && ~isempty(s.(names{i}))
        value = s.(names{i});
        return;
    end
end
end
