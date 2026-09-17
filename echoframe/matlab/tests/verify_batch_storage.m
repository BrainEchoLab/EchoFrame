% verify_batch_storage - batch_loading PDI re-storage round-trips through pdi_acq.dat.
%
% Streams a BF recording through batch_loading with saving ON, then reads
% pdi_acq.dat back and asserts the stored frames match what process_pdi_only
% returned -- i.e. repeated saves append buffers in order without loss.
%
% Run interactively in R2024a (needs the GPU). Errors out on any mismatch.

%% Tunables
N_BUFFERS        = 12;    % tiling: ensemble = shift = nRepeats, so totalFrames = N_BUFFERS
FRAMES_PER_BATCH = 4;     % frames per batch; must divide N_BUFFERS for a uniform run
NOISE_STD        = 200;
assert(mod(N_BUFFERS, FRAMES_PER_BATCH) == 0, ...
       'Pick FRAMES_PER_BATCH dividing N_BUFFERS for a uniform (single-file) run.');

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
prep          = batch_demo_data.prepare();
data_root     = fullfile(echoframe_data_root(), 'echoframe_storage_verify_in');
recording_dir = batch_demo_data.writeBuffers(prep, data_root, ...
                                             N_BUFFERS, NOISE_STD, true, false);   % saveBF only

%% Load specs back
S = load(fullfile(recording_dir, 'ScanParameters.mat'));
ProbeSpec = S.ProbeSpec; TransmitSpec = S.TransmitSpec;
ReceiveSpec = S.ReceiveSpec; ReconSpec = S.ReconSpec; ExperimentSpec = S.ExperimentSpec;
M            = double(ReconSpec.nz) * double(ReconSpec.nx);
nRepeats_buf = double(ReceiveSpec.nRepeats);
ens = nRepeats_buf; shift = nRepeats_buf;             % tiling

%% Stream the BF stack through batch_loading with STORAGE ON; keep returned frames
PDISpec = struct('ensembleSize', ens, 'shiftSize', shift, ...
                 'threshold', single(0.4), 'svdMethod', 'Covariance', 'cropPDI', false);
store_dir = fullfile(echoframe_data_root(), 'echoframe_storage_verify_out');
if exist(store_dir, 'dir'), rmdir(store_dir, 's'); end
mkdir(store_dir);
StorageSpec.folderStoragePath = store_dir;
StorageSpec.saveRF = false; StorageSpec.saveBF = false;
StorageSpec.savePDI = true; StorageSpec.saveRFTimeTag = false;
StorageSpec.preallocateFullFile = true;

fidB = fopen(fullfile(recording_dir, 'bf_acq.dat')); H = read_header(fidB);
% Budget sized (1x) so batch_loading picks exactly FRAMES_PER_BATCH frames per call.
budgetGB = ((FRAMES_PER_BATCH-1)*shift + ens) * (M*8) / 1024^3;
loader   = batch_loading.forBF(fidB, H, M, ens, shift, budgetGB);
assert(loader.framesPerBatch == FRAMES_PER_BATCH, ...
       'budget did not yield FRAMES_PER_BATCH (got %d).', loader.framesPerBatch);
assert(loader.nBatches > 1, 'need >1 batch to exercise appending.');
fprintf('T=%d, %d frames, %d uniform batches x %d frames.\n', ...
        double(H.buffersStored)*nRepeats_buf, loader.totalFrames, loader.nBatches, loader.framesPerBatch);

ExperimentSpec.numberOfPDIsExperiment = loader.nBatches;     % one stored buffer per call
ReceiveSpec.nRepeats = int32(loader.slabLen);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
StorageSpec         = evalin('base', 'StorageSpec');
store_recording_dir = StorageSpec.experimentStoragePath;
echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec);

PDI_returned = zeros(double(ReconSpec.nz), double(ReconSpec.nx), loader.totalFrames, 'single');
framesOut = 0;
while loader.hasNext()
    slab = loader.next();
    PDI  = echoframe_mex('process_pdi_only', slab, true);   % true => write to pdi_acq.dat
    PDI_returned(:, :, framesOut + (1:size(PDI,3))) = PDI;
    framesOut = framesOut + size(PDI,3);
end
echoframe_mex('destroy'); clear mex;                        % flushes writes + header
fclose(fidB);
fprintf('returned %d frames; wrote pdi_acq.dat to %s\n', framesOut, store_recording_dir);

%% Read pdi_acq.dat back and compare
fid = fopen(fullfile(store_recording_dir, 'pdi_acq.dat')); pdiHeader = read_header(fid); fseek(fid, pdiHeader.headerSize, 'bof');
buffersStored         = double(pdiHeader.buffersStored);
storedBufferSize      = double(pdiHeader.effectiveBufferSize);   % elems per stored buffer = nz*nx*FRAMES_PER_BATCH
framesPerStoredBuffer = storedBufferSize / M;
PDI_disk = zeros(double(ReconSpec.nz), double(ReconSpec.nx), buffersStored*framesPerStoredBuffer, 'single');
framesRead = 0;
for i = 1:buffersStored
    chunk = fread(fid, storedBufferSize, '*single');
    PDI_disk(:, :, framesRead + (1:framesPerStoredBuffer)) = ...
        reshape(chunk, double(ReconSpec.nz), double(ReconSpec.nx), framesPerStoredBuffer);
    framesRead = framesRead + framesPerStoredBuffer;
    fseek(fid, pdiHeader.paddingBytes, 'cof');
end
fclose(fid);
fprintf('read back %d buffer(s) x %d frame(s) = %d frames.\n', buffersStored, framesPerStoredBuffer, framesRead);

%% Compare
if ~isequal(size(PDI_returned), size(PDI_disk))
    error('verify_batch_storage:size', 'stored frame count %d ~= returned %d.', ...
          size(PDI_disk,3), size(PDI_returned,3));
end
maxDiff = max(abs(PDI_returned(:) - PDI_disk(:)));
if maxDiff ~= 0
    error('verify_batch_storage:values', 'stored PDI differs from returned (max abs diff %.3g).', maxDiff);
end
fprintf('\n=== PASS: pdi_acq.dat matches the returned frames exactly (%d frames, %d appended buffers) ===\n', ...
        framesRead, buffersStored);

% Test output, both trees: the generated BF input and the re-stored PDI. Must
% follow the destroy above, which is what closes the files.
echoframe_cleanup_dir(data_root);
echoframe_cleanup_dir(store_dir);
