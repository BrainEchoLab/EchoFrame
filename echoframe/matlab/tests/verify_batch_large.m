% verify_batch_large - Stream a stack far larger than the budget through the loader.
%
% Generates a big BF recording (TARGET_STACK_GB) and streams it through
% batch_loading, printing the per-batch host memory vs what a single-shot load
% would need. Raise TARGET_STACK_GB past your RAM for a genuine physical non-fit.
%
% COST: writes TARGET_STACK_GB to the temp folder (16 GB is several minutes and
% needs TARGET_STACK_GB free there); removed again when the run passes. Run
% interactively in R2024a (needs the GPU).

%% Tunables
TARGET_STACK_GB  = 64;    % full-stack size to generate [GiB] -- the point is it won't fit under the budget
MEMORY_BUDGET_GB = 4;     % per-batch host budget
NOISE_STD        = 200;

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

%% Simulate one base buffer (shared helper) to learn the per-buffer size
prep           = batch_demo_data.prepare();
bytesPerBuffer = prep.bytesPerBuffer;                              % complex single

%% Derive a buffer count that hits ~TARGET_STACK_GB AND divides evenly into batches
maxFit         = max(1, floor(MEMORY_BUDGET_GB * 1024^3 / bytesPerBuffer));
nBatchesWant   = max(2, round(TARGET_STACK_GB * 1024^3 / (maxFit * bytesPerBuffer)));
N_BUFFERS      = nBatchesWant * maxFit;    % multiple of maxFit -> clean equal batches
fprintf('=== Target %.0f GB stack -> %d buffers x %.1f MB = %.2f GB (%d batches of %d) ===\n', ...
        TARGET_STACK_GB, N_BUFFERS, bytesPerBuffer/1024^2, ...
        N_BUFFERS*bytesPerBuffer/1024^3, nBatchesWant, maxFit);

%% Generate N_BUFFERS to disk (shared helper)
fprintf('Generating %d buffers (~%.1f GB)...\n', N_BUFFERS, N_BUFFERS*bytesPerBuffer/1024^3);
data_root = fullfile(echoframe_data_root(), 'echoframe_batch_large');
[recording_dir, StorageSpec] = batch_demo_data.writeBuffers(prep, ...
    data_root, N_BUFFERS, NOISE_STD, true, false);   % saveBF only

%% Load specs + header back
S = load(fullfile(recording_dir, 'ScanParameters.mat'));
ProbeSpec = S.ProbeSpec; TransmitSpec = S.TransmitSpec;
ReceiveSpec = S.ReceiveSpec; ReconSpec = S.ReconSpec; ExperimentSpec = S.ExperimentSpec;
nRepeats_buf = double(ReceiveSpec.nRepeats);
PDISpec = struct('ensembleSize', 20, 'shiftSize', 20, ...
                 'threshold', single(0.4), 'svdMethod', 'Covariance', 'cropPDI', false);
bfPath = fullfile(recording_dir, 'bf_acq.dat');
fid = fopen(bfPath); H = read_header(fid); fclose(fid);
nBuffers   = double(H.buffersStored);
bufferSize = double(H.effectiveBufferSize);
fullBytes  = bufferSize * 8 * nBuffers;
fullGB     = fullBytes / 1024^3;

%% Memory picture: why this needs batching
try
    mem     = memory;                                   % Windows base MATLAB
    availGB = mem.MemAvailableAllArrays / 1024^3;
catch
    availGB = NaN;
end
fprintf('\n=== Memory picture ===\n');
fprintf('  per buffer   : %.1f MB\n', bufferSize*8/1024^2);
fprintf('  full stack   : %.2f GB  (all %d buffers at once)\n', fullGB, nBuffers);
fprintf('  batch budget : %.2f GB\n', MEMORY_BUDGET_GB);
if ~isnan(availGB)
    fprintf('  RAM available: %.2f GB\n', availGB);
    if fullGB > availGB
        fprintf('  >>> single-shot load needs %.2f GB > %.2f GB available: it would FAIL. Batching required.\n', fullGB, availGB);
    else
        fprintf('  (full stack fits RAM here, but far exceeds the %.2f GB budget -> batching demonstrated)\n', MEMORY_BUDGET_GB);
    end
end

%% Batch sizing via the loader itself (1x: a slab fits WITHIN the budget)
M      = double(ReconSpec.nz) * double(ReconSpec.nx);
ens    = double(PDISpec.ensembleSize);
shift  = double(PDISpec.shiftSize);
fidB   = fopen(bfPath);
loader = batch_loading.forBF(fidB, H, M, ens, shift, MEMORY_BUDGET_GB);
slabBytes = loader.slabLen * M * 8;
fprintf('\n=== Batching (batch_loading): %d batches x %d frame(s) = %d units/slab (%.0f MB/batch, %.0fx smaller than full) ===\n', ...
        loader.nBatches, loader.framesPerBatch, loader.slabLen, slabBytes/1024^2, fullBytes/slabBytes);

%% Init once for the uniform slab length, stream every batch, report per-batch memory
ReceiveSpec.nRepeats = int32(loader.slabLen);
ExperimentSpec.numberOfPDIsExperiment = loader.nBatches;
StorageSpec.folderStoragePath = '';                     % no re-storage for this test
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec);

totalFrames = 0; peakMB = 0; b = 0;
while loader.hasNext()
    slab = loader.next();                               % [M, slabLen] complex single
    b    = b + 1;
    w = whos('slab'); batchMB = w.bytes / 1024^2;
    peakMB = max(peakMB, batchMB);
    PDI = echoframe_mex('process_pdi_only', slab, false);
    totalFrames = totalFrames + size(PDI, 3);
    fprintf('  batch %3d/%d | slab %d units resident = %7.1f MB | %d PDI frame(s) | full load would be %.0f MB\n', ...
            b, loader.nBatches, loader.slabLen, batchMB, size(PDI, 3), fullBytes/1024^2);
end
fclose(fidB);
echoframe_mex('destroy'); clear mex;

%% Summary
fprintf('\n=== DONE ===\n');
fprintf('Processed %d buffers in %d batches. Peak resident slab: %.1f MB (~1x, no 2x transient).\n', ...
        nBuffers, loader.nBatches, peakMB);
fprintf('Single-shot would have needed %.2f GB resident at once; batching kept it to %.1f MB (%.0fx less).\n', ...
        fullGB, peakMB, (fullBytes/1024^2)/peakMB);
fprintf('Total PDI frames produced: %d.\n', totalFrames);

% Test output. Must follow the destroy above, which is what closes the files.
echoframe_cleanup_dir(data_root);
fprintf('Removed the %.1f GB test recording.\n', N_BUFFERS*bytesPerBuffer/1024^3);
