% process_echoframe_data - Replay stored EchoFrame RF data through the MEX pipeline.
%
% Reads ScanParameters.mat + rf_acq.dat produced by an EchoFrame storage
% session, replays the RF through echoframe_mex, and renders B-mode + PDI. The
% RF stack is streamed through batch_loading (see batch_loading.m) so a long
% recording need not fit in memory at once.
%
% The PDI struct below is set FIRST and is preserved through the load step (only
% the other spec structs come from ScanParameters.mat), so you can change
% ensembleSize, threshold, svdMethod, etc. without re-acquiring.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built; saved data at load_path.
% Tip:    load_path should point at the recording_<timestamp> subfolder
%         created by init_storage (the same path generate_echoframe_demo_data
%         prints when it finishes).
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
load_path = '';                                    % folder with ScanParameters.mat + rf_acq.dat
rf_file   = 'rf_acq.dat';

% Host-memory budget per batch (see batch_loading.m). Larger => fewer, bigger
% batches. Lower it if you hit a GPU out-of-memory error -- the GPU holds a batch
% of RF, BF and PDI on top of this host budget.
MEMORY_BUDGET_GB = 4;

% PDI parameters (these win over whatever was saved at acquisition time)
PDISpec.ensembleSize = 100;
PDISpec.shiftSize    = 100;
PDISpec.threshold    = single(0.4);
PDISpec.svdMethod    = 'Covariance';
PDISpec.cropPDI      = logical(false);

if isempty(load_path)
    error('process_echoframe_data:missingPath', ...
          'Set load_path to the recording folder with ScanParameters.mat + %s.', rf_file);
end

%% Load the spec structs (everything except PDISpec, which the user controls above)
S = load(fullfile(load_path, 'ScanParameters.mat'));
ProbeSpec    = S.ProbeSpec;
TransmitSpec = S.TransmitSpec;
ReceiveSpec  = S.ReceiveSpec;
ReconSpec    = S.ReconSpec;

%% Open RF file + geometry
RFPath = fullfile(load_path, rf_file);
fileID = fopen(RFPath);
if fileID < 0
    error('process_echoframe_data:open', 'Could not open %s.', RFPath);
end
cleanup = onCleanup(@() fclose(fileID));   % closes fileID when this scope ends (incl. on error)
HeaderSpec = read_header(fileID);

nBuffers      = double(HeaderSpec.buffersStored);
nRepeats_buf  = double(ReceiveSpec.nRepeats);
nChannels     = double(ReceiveSpec.nChannels);
rowsPerRepeat = double(ReceiveSpec.nSamples) * double(ReceiveSpec.nTransmissions);  % RF rows per slow-time sample
T             = nBuffers * nRepeats_buf;             % total slow-time samples (repeats)

ens   = double(PDISpec.ensembleSize);
shift = double(PDISpec.shiftSize);

%% Size + stream the RF stack through batch_loading
loader = batch_loading.forRF(fileID, HeaderSpec, rowsPerRepeat, nChannels, ...
                             nRepeats_buf, ens, shift, MEMORY_BUDGET_GB);
nEnsembles = loader.totalFrames;   % PDI frames over the whole recording = floor((T-ens)/shift)+1

fprintf('%d buffers x %d repeats = %d slow-time samples. %d PDI frame(s) total.\n', ...
        nBuffers, nRepeats_buf, T, nEnsembles);
if loader.wholeLoad
    fprintf('Whole recording fits the %.1f GB budget: loading all %d frame(s) in one call.\n', ...
            MEMORY_BUDGET_GB, nEnsembles);
else
    fprintf('Batching %d frame(s)/call in %d call(s), budget %.1f GB.\n', ...
            loader.framesPerBatch, loader.nBatches, MEMORY_BUDGET_GB);
end

%% Init the MEX once (no storage: view only)
ReceiveSpec.nRepeats = int32(loader.slabLen);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);

%% Process each batch (timed end-to-end over the streaming loop)
frameNo   = 0;
BmodeLast = [];
PDI_all   = zeros(double(ReconSpec.nz), double(ReconSpec.nx), nEnsembles, 'single');
tProc     = tic;
while loader.hasNext()
    slab = loader.next();                          % [slabLen*rowsPerRepeat, nChannels] int16
    [PDI, Bmode, ~] = echoframe_mex('process', slab, false);
    BmodeLast = Bmode;
    PDI_all(:, :, frameNo + (1:size(PDI,3))) = PDI;
    frameNo = frameNo + size(PDI,3);
end
fprintf('Processed %d frame(s) in %d batch(es) in %.2f s.\n', nEnsembles, loader.nBatches, toc(tProc));

echoframe_mex('destroy');
clear mex;

%% Show B-mode (last batch's) and all PDI frames
BmodeLog = 20*log10(BmodeLast ./ max(BmodeLast(:)) + eps);
figure('Name', 'B-mode');
imagesc(ReconSpec.xAxis, ReconSpec.zAxis, BmodeLog);
colormap(gray); clim([-40 0]); colorbar;
axis equal ij tight;
xlabel('Width [mm]'); ylabel('Depth [mm]');
title('B-mode [dB] (last batch)');

figure('Name', 'PDI frames');
for idx = 1:size(PDI_all, 3)
    PDI_frame   = PDI_all(:, :, idx);
    PDI_norm_db = 10*log10(PDI_frame ./ max(PDI_frame(:)));
    imagesc(ReconSpec.xAxis, ReconSpec.zAxis, PDI_norm_db);
    colormap hot; colorbar;
    axis equal ij tight;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title(sprintf('PDI frame %d / %d  (ensemble=%d, shift=%d, threshold=%.3f)', ...
                  idx, size(PDI_all, 3), ens, shift, PDISpec.threshold));
    drawnow;
    pause(0.5);
end
