% verify_batch_lossless - batch_loading.forBF batched PDI == single-shot PDI.
%
% Computes PDI two ways over the same BF recording with overlapping windows and
% asserts identical frame count AND values:
%   (A) single-shot: one process_pdi_only over the whole stack (independent ref)
%   (B) batched:     batch_loading.forBF streaming bf_acq.dat, budget forcing >1 batch
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

%% Generate dataset (shared helper: simulate one buffer, write N noisy BF buffers)
prep = batch_demo_data.prepare();
data_root = fullfile(echoframe_data_root(), 'echoframe_lossless_verify');
[recording_dir, StorageSpec] = batch_demo_data.writeBuffers(prep, ...
    data_root, N_BUFFERS, NOISE_STD, true, false);   % saveBF only

%% Read the whole BF stack into memory: [M, T]  (for the single-shot reference)
S = load(fullfile(recording_dir, 'ScanParameters.mat'));
ProbeSpec = S.ProbeSpec; TransmitSpec = S.TransmitSpec;
ReceiveSpec = S.ReceiveSpec; ReconSpec = S.ReconSpec; ExperimentSpec = S.ExperimentSpec;
M            = double(ReconSpec.nz) * double(ReconSpec.nx);
nRepeats_buf = double(ReceiveSpec.nRepeats);

fid = fopen(fullfile(recording_dir, 'bf_acq.dat')); H = read_header(fid);
fseek(fid, H.headerSize, 'bof');
nBuffers = double(H.buffersStored);
T = nBuffers * nRepeats_buf;
full = complex(zeros(M, T, 'single'));
for i = 1:nBuffers
    raw = fread(fid, 2*M*nRepeats_buf, '*single');
    full(:, (i-1)*nRepeats_buf + (1:nRepeats_buf)) = ...
        reshape(raw(1:2:end) + 1i*raw(2:2:end), M, nRepeats_buf);
    fseek(fid, H.paddingBytes, 'cof');
end
fclose(fid);

PDISpec = struct('ensembleSize', ENSEMBLE_SIZE, 'shiftSize', SHIFT_SIZE, ...
                 'threshold', single(0.4), 'svdMethod', 'Covariance', 'cropPDI', false);
totalFrames = floor((T - ENSEMBLE_SIZE)/SHIFT_SIZE) + 1;
fprintf('T=%d, ensemble=%d, shift=%d (overlap) -> %d frames expected.\n', ...
        T, ENSEMBLE_SIZE, SHIFT_SIZE, totalFrames);

%% (A) single-shot reference (independent of batch_loading)
ReceiveSpec.nRepeats = int32(T);
StorageSpec.folderStoragePath = '';
ExperimentSpec.numberOfPDIsExperiment = 1;
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec);
PDI_single = echoframe_mex('process_pdi_only', full, false);
echoframe_mex('destroy'); clear mex;
fprintf('single-shot produced %d frames.\n', size(PDI_single,3));

%% (B) batched via batch_loading, streaming the same bf_acq.dat from disk
% Budget sized to hold exactly one ensemble (1x) -> 1 frame/batch, so the overlap
% carry is exercised between every consecutive window.
budgetGB = ENSEMBLE_SIZE * (M*8) / 1024^3;

fidB   = fopen(fullfile(recording_dir, 'bf_acq.dat'));
loader = batch_loading.forBF(fidB, H, M, ENSEMBLE_SIZE, SHIFT_SIZE, budgetGB);
if loader.nBatches < 2
    error('verify_batch_lossless:setup', ...
          'budget did not force batching (nBatches=%d).', loader.nBatches);
end
StorageSpec.folderStoragePath = '';
ExperimentSpec.numberOfPDIsExperiment = loader.nBatches;
ReceiveSpec.nRepeats = int32(loader.slabLen);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec);
PDI_batched = zeros(size(PDI_single), 'single');
framesOut = 0;
while loader.hasNext()
    slab = loader.next();
    PDI  = echoframe_mex('process_pdi_only', slab, false);
    PDI_batched(:, :, framesOut + (1:size(PDI,3))) = PDI;
    framesOut = framesOut + size(PDI,3);
end
echoframe_mex('destroy'); clear mex;
fclose(fidB);
fprintf('batched via batch_loading: %d frames in %d call(s) of %d frame(s).\n', ...
        framesOut, loader.nBatches, loader.framesPerBatch);

%% Compare
if ~isequal(size(PDI_single), size(PDI_batched))
    error('verify_batch_lossless:size', 'frame count differs: single=%d batched=%d', ...
          size(PDI_single,3), size(PDI_batched,3));
end
maxDiff = max(abs(PDI_single(:) - PDI_batched(:)));
if maxDiff ~= 0
    error('verify_batch_lossless:values', 'PDI differs (max abs diff %.3g).', maxDiff);
end
fprintf('\n=== PASS: batch_loading PDI is identical to single-shot (%d frames, overlapping windows) ===\n', ...
        size(PDI_single,3));

% Test output. Must follow the destroy above, which is what closes the files.
echoframe_cleanup_dir(data_root);
