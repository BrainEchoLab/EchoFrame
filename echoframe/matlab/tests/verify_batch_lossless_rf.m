% verify_batch_lossless_rf - batch_loading.forRF batched replay == single-shot.
%
% RF-path counterpart of verify_batch_lossless: generates an RF recording via the
% batch_demo_data helper, then computes PDI two ways through the full pipeline
% (echoframe_mex 'process' = beamform + PDI) with overlapping windows and asserts
% identical frame count AND values:
%   (A) single-shot: one process over the whole RF stack read from disk (independent ref)
%   (B) batched:     batch_loading.forRF streaming the same rf_acq.dat, budget forcing >1 batch
%
% Run interactively in R2024a (needs the GPU). Errors out on any mismatch.

%% Tunables
N_BUFFERS     = 12;      % small -> whole stack fits for the single-shot reference
ENSEMBLE_SIZE = 50;      % PDISpec.ensembleSize
SHIFT_SIZE    = 20;      % PDISpec.shiftSize < ENSEMBLE_SIZE => overlapping windows
NOISE_STD     = 200;

%% Paths
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
MEX_DIR = echoframe_mex_dir();
if ~isempty(MEX_DIR), addpath(MEX_DIR); end
fprintf('Using echoframe_mex: %s\n', which('echoframe_mex'));

%% Generate an RF recording (shared helper: simulate one buffer, write N noisy RF buffers)
prep          = batch_demo_data.prepare();
data_root     = fullfile(echoframe_data_root(), 'echoframe_lossless_rf_verify');
recording_dir = batch_demo_data.writeBuffers(prep, data_root, ...
                                             N_BUFFERS, NOISE_STD, false, true);   % saveRF only

%% Reload specs + RF geometry
S = load(fullfile(recording_dir, 'ScanParameters.mat'));
ProbeSpec = S.ProbeSpec; TransmitSpec = S.TransmitSpec;
ReceiveSpec = S.ReceiveSpec; ReconSpec = S.ReconSpec;
ReconSpec.getPDI = true;                              % the RF path returns PDI from 'process'
nRepeats_buf  = double(ReceiveSpec.nRepeats);
nChannels     = double(ReceiveSpec.nChannels);
rowsPerRepeat = double(ReceiveSpec.nSamples) * double(ReceiveSpec.nTransmissions);
rowsPerBuffer = rowsPerRepeat * nRepeats_buf;

%% Read the whole RF stack straight from disk: [rowsPerBuffer*nBuffers, nChannels]
% Independent of batch_loading -- the single-shot reference.
rfPath = fullfile(recording_dir, 'rf_acq.dat');
fid = fopen(rfPath); H = read_header(fid); fseek(fid, H.headerSize, 'bof');
nBuffers = double(H.buffersStored);
T        = nBuffers * nRepeats_buf;
RF_full  = zeros(rowsPerBuffer * nBuffers, nChannels, 'int16');
for i = 1:nBuffers
    RF_full((i-1)*rowsPerBuffer + (1:rowsPerBuffer), :) = fread(fid, [rowsPerBuffer, nChannels], '*int16');
    fseek(fid, H.paddingBytes, 'cof');
end
fclose(fid);

PDISpec = struct('ensembleSize', ENSEMBLE_SIZE, 'shiftSize', SHIFT_SIZE, ...
                 'threshold', single(0.4), 'svdMethod', 'Covariance', 'cropPDI', false);
totalFrames = floor((T - ENSEMBLE_SIZE)/SHIFT_SIZE) + 1;
fprintf('T=%d, ensemble=%d, shift=%d (overlap) -> %d frames expected.\n', ...
        T, ENSEMBLE_SIZE, SHIFT_SIZE, totalFrames);

%% (A) single-shot reference: one process over all T repeats (independent of the loader)
ReceiveSpec.nRepeats = int32(T);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
PDI_single = echoframe_mex('process', RF_full, false);
echoframe_mex('destroy'); clear mex;
fprintf('single-shot produced %d frames.\n', size(PDI_single,3));

%% (B) batched via batch_loading.forRF, streaming the same rf_acq.dat from disk
% Budget sized to hold exactly one ensemble (1x) -> 1 frame/batch, so the overlap
% carry is exercised between every consecutive window.
budgetGB = ENSEMBLE_SIZE * (rowsPerRepeat * nChannels * 2) / 1024^3;

fidB   = fopen(rfPath);
loader = batch_loading.forRF(fidB, H, rowsPerRepeat, nChannels, nRepeats_buf, ...
                             ENSEMBLE_SIZE, SHIFT_SIZE, budgetGB);
if loader.nBatches < 2
    error('verify_batch_lossless_rf:setup', ...
          'budget did not force batching (nBatches=%d).', loader.nBatches);
end
ReceiveSpec.nRepeats = int32(loader.slabLen);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
PDI_batched = zeros(size(PDI_single), 'single');
framesOut = 0;
while loader.hasNext()
    slab = loader.next();                          % [slabLen*rowsPerRepeat, nChannels] int16
    PDI  = echoframe_mex('process', slab, false);
    PDI_batched(:, :, framesOut + (1:size(PDI,3))) = PDI;
    framesOut = framesOut + size(PDI,3);
end
echoframe_mex('destroy'); clear mex;
fclose(fidB);
fprintf('batched via batch_loading.forRF: %d frames in %d call(s) of %d frame(s).\n', ...
        framesOut, loader.nBatches, loader.framesPerBatch);

%% Compare
if ~isequal(size(PDI_single), size(PDI_batched))
    error('verify_batch_lossless_rf:size', 'frame count differs: single=%d batched=%d', ...
          size(PDI_single,3), size(PDI_batched,3));
end
maxDiff = max(abs(PDI_single(:) - PDI_batched(:)));
if maxDiff ~= 0
    error('verify_batch_lossless_rf:values', 'PDI differs (max abs diff %.3g).', maxDiff);
end
fprintf('\n=== PASS: batch_loading.forRF PDI is identical to single-shot (%d frames, overlapping windows) ===\n', ...
        size(PDI_single,3));

% Test output. Must follow the destroy above, which is what closes the files.
echoframe_cleanup_dir(data_root);
