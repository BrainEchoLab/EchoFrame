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
maxOffset = reshape((double(ReceiveSpec.nSamplesIQ) - 2) - max(receiveSamples, [], 2), nz, nx);

useTransmitDelays = isfield(TransmitSpec, 'transmitDelays') && any(TransmitSpec.transmitDelays(:) ~= 0);
txDelaySamples = double(TransmitSpec.transmitDelays) * double(ReceiveSpec.Fs) / 2;
if ndims(txDelaySamples) == 3
    txDelaySamples = squeeze(txDelaySamples(:, 1, :));
end

ReconSpec.dasOffsets = zeros(nz, nx, nTx, 'single');
for iTx = 1:nTx
    if useTransmitDelays
        active = TransmitSpec.apodization(:) ~= 0;
        txX = channelX(active)';
        txDelay = txDelaySamples(active, iTx)';
        txSamples = min(sqrt((xGrid(:) - txX).^2 + zGrid(:).^2) * fsOverTwoC + txDelay, [], 2);
        offsets = reshape(txSamples, nz, nx) - startSamples;
    else
        theta = double(TransmitSpec.steer(iTx));
        offsets = (zGrid * cosd(theta) + xGrid * sind(theta)) * fsOverTwoC - startSamples;
    end
    ReconSpec.dasOffsets(:, :, iTx) = single(min(max(offsets, minOffset), maxOffset));
end

ReconSpec.dasWeights = ones(nz, nx, nTx, 'single') ./ single(max(1, nTx * nActive));
% RFFormatter stores IQ as I - iQ, so ffdas' usual negative phase rotation
% is conjugated here.
ReconSpec.dasWavenum = single(4 * pi * double(ProbeSpec.Fc) / double(ReceiveSpec.Fs));
ReconSpec.dasAlgorithm = int32(1);
ReconSpec.dasComputeType = int32(0);
ReconSpec.dasSourceDirections = single(repmat([0; 0; 1; cosd(35)], 1, nActive));
end
