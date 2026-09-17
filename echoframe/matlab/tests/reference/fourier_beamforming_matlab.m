% fourier_beamforming_matlab - Reference Fourier (f-k) beamforming in plain MATLAB.
%
% Mirrors the C++/CUDA implementation in
% echoframe/cpp/src/beamformer/fourier_imaging as a self-contained MATLAB script.
% Useful for understanding the algorithm and as a ground-truth reference
% when debugging the MEX.
%
% Pipeline (per transmission, per repeat):
%   1. Convert int16 RF to complex single (BS100BW: interleaved I / Q).
%   2. Reshape to [nSamplesIQ, nTransmissions, nRepeats, nChannels].
%   3. Apply the TGC vector along fast time.
%   4. FFT along fast time.
%   5. Per-channel plane-wave delay phasor.
%   6. FFT along channels (spatial FFT).
%   7. Beamform via the lookup tables built by echoframe_setup_fourier:
%      single-bin nearest neighbour with linear-phase fractional shift
%      correction, which is what the C++ kernel consumes, so the MEX produces
%      the same image.
%   8. Compound across transmissions; IFFT2 zero-padded to (nz, nx).
%
% Reuses simulate_logo_rf for the input RF and initialize_image_reconstruction
% for nz/nx/tgcVector and the lookup tables, which it builds by calling
% echoframe_setup_fourier.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built (only needed when
%         compare_with_mex is true; forced false for 'linear' interp).
% Usage:  edit the parameters block below; run.

clear; close all; clear mex;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));

% The MEX + storage gateways under test. addpath prepends, so this takes
% priority over any other copy on the path (binaries/, ...).
ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);

%% Parameters
compare_with_mex = true;     % run echoframe_mex on the same RF too

% --- Probe / Transmit
ProbeSpec.pitch          = 300e-6;
ProbeSpec.Fc             = 5e6;
ProbeSpec.nElements      = 128;

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

% --- Receive
ReceiveSpec.nRepeats       = 40;
ReceiveSpec.Fs             = 20e6;
ReceiveSpec.nTransmissions = length(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';

% --- Reconstruction
ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(false);
ReconSpec.extraVoxelsZ      = 0;
ReconSpec.extraVoxelsX      = 128;
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = [0; 128; 0; 128];

% --- PDI (only used by the optional MEX comparison)
PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

%% Simulate RF
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

%% Initialise reconstruction: nz, nx, tgcVector, and the lookup tables, which
%% it builds by calling echoframe_setup_fourier.
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

%% Pull out the common reconstruction tables
frequency_axis = ReconSpec.frequencyAxis(:);
delay_Ax       = ReconSpec.planewaveDelays(:, 1);
delay_b        = ReconSpec.planewaveDelays(:, 2);
tgc_vector     = ReconSpec.tgcVector(:);

delay_idx = double(ReconSpec.delayIndices) + 1;            % 0-based -> 1-based
weights   = ReconSpec.interpolationWeights;

Ns = double(ReceiveSpec.nSamplesIQ);
Nt = double(ReceiveSpec.nTransmissions);
Ne = double(ReceiveSpec.nRepeats);
Nc = double(ReceiveSpec.nChannels);
Nz = double(ReconSpec.nz);
Nx = double(ReconSpec.nx);

%% Convert int16 RF -> complex single, reshape to [Ns, Nt, Ne, Nc]
% BS100BW interleaves I and Q every other row.
RF_iq = single(RF(1:2:end, :)) - 1i * single(RF(2:2:end, :));
RF_iq = reshape(RF_iq, Ns, Nt, Ne, Nc);

%% Beamform (per transmission, per repeat)
fprintf('Running MATLAB f-k beamformer (Nt=%d, Ne=%d)...\n', Nt, Ne);
BF = zeros(Nz, Nx, Nt, Ne, 'single');
chan_vec = 1:Nc;
for iTransmit = 1:Nt
    fprintf('  transmission %d / %d\n', iTransmit, Nt);

    % Per-transmission planewave-delay phasor (same for every repeat)
    d_delay = delay_Ax(iTransmit) * chan_vec + delay_b(iTransmit);    % [1, Nc]
    phasor  = exp(1i * (frequency_axis * d_delay));                   % [Ns, Nc]

    % Pull this transmission's lookup tables once per tx
    lookup = delay_idx(:, :, iTransmit);                              % [Ns, Nc]
    wt     = weights(:, :, iTransmit);                                % [Ns, Nc]

    for iRepeat = 1:Ne
        % 1. Pull a [Ns, Nc] frame
        frame = squeeze(RF_iq(:, iTransmit, iRepeat, :));

        % 2. TGC along fast time
        frame = frame .* tgc_vector;

        % 3. FFT along fast time
        F = fft(frame, [], 1);

        % 4. Apply per-channel planewave-delay phasor
        F = F .* phasor;

        % 5. FFT along channels (spatial FFT)
        F = fft(F, [], 2);

        % 6. Beamform: pick (delayIndex, channel) and apply the weight
        F_bf = zeros(size(F), 'like', F);
        for iChannel = 1:Nc
            F_bf(:, iChannel) = F(lookup(:, iChannel), iChannel) .* wt(:, iChannel);
        end

        % 7. IFFT2 zero-padded to the recon grid
        BF(:, :, iTransmit, iRepeat) = ifft2(fftshift(F_bf), Nz, Nx);
    end
end

%% Compound transmissions, average power across slow time
BF_compounded    = squeeze(sum(BF, 3));                           % [Nz, Nx, Ne]
Bmode_matlab     = mean(abs(BF_compounded), 3);                   % [Nz, Nx]
Bmode_matlab_log = 20*log10(Bmode_matlab ./ max(Bmode_matlab(:)) + eps);

%% Optional: run the MEX on the same RF for direct comparison
if compare_with_mex
    fprintf('Running echoframe_mex on the same RF for comparison...\n');
    % Validation casts the specs to the types the MEX requires; the tables are
    % the ones initialize_image_reconstruction already built above.
    [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
        echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
    echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
    [~, Bmode_mex, ~] = echoframe_mex('process', RF, false);
    Bmode_mex_log = 20*log10(Bmode_mex ./ max(Bmode_mex(:)) + eps);
    echoframe_mex('destroy');   % release resources before clear mex
    clear mex;

    % Printed rather than left to the eye: the two images look alike at a
    % glance whatever the tables say, so a number is what tells a reader the
    % reference still tracks the kernel. Both sides are single, so agreement
    % lands near 1e-7; a mismatch is orders larger, not marginally so.
    a = Bmode_matlab ./ max(Bmode_matlab(:));
    b = double(Bmode_mex) ./ max(double(Bmode_mex(:)));
    fprintf('MATLAB vs MEX on the normalised B-mode: max %.2e, rms %.2e\n', ...
            max(abs(a(:) - b(:))), sqrt(mean((a(:) - b(:)).^2)));
end

%% Display
if compare_with_mex
    figure('Name', 'Fourier beamforming: MATLAB vs. MEX');
    subplot(1, 2, 1);
    imagesc(ReconSpec.xAxis, ReconSpec.zAxis, Bmode_matlab_log);
    colormap(gca, gray); clim([-40 0]); colorbar;
    axis equal ij tight;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title('B-mode (MATLAB)');

    subplot(1, 2, 2);
    imagesc(ReconSpec.xAxis, ReconSpec.zAxis, Bmode_mex_log);
    colormap(gca, gray); clim([-40 0]); colorbar;
    axis equal ij tight;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title('B-mode (echoframe\_mex)');
else
    figure('Name', 'Fourier beamforming (MATLAB)');
    imagesc(ReconSpec.xAxis, ReconSpec.zAxis, Bmode_matlab_log);
    colormap(gray); clim([-40 0]); colorbar;
    axis equal ij tight;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title('B-mode (MATLAB f-k beamforming, logo phantom)');
end
