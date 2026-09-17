% process_echoframe_bf_to_pdi_data - Compute PDI from previously beamformed data.
%
% Reads ScanParameters.mat + bf_acq.dat from an EchoFrame storage session and
% runs only the PDI stage (echoframe_mex 'process_pdi_only') with a user-chosen
% PDISpec. The BF stack is streamed through batch_loading (see batch_loading.m)
% so a long recording need not fit in memory at once.
%
% The PDI struct below is set FIRST and is preserved through the load step (only
% the other spec structs come from ScanParameters.mat), so you can change
% ensembleSize, threshold, svdMethod, etc. without re-acquiring -- the offline
% PDI window need not match the per-buffer slow-time count used at acquisition.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built; BF data at load_path.
% Tip:    load_path should point at the recording_<timestamp> subfolder






%         created by init_storage / generate_echoframe_demo_data.
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
load_path = '';                                    % folder with bf_acq.dat + ScanParameters.mat
bf_file   = 'bf_acq.dat';

% Host-memory budget per batch (see batch_loading.m). Larger => fewer, bigger
% batches. Lower it if you hit a GPU out-of-memory error -- the GPU + process()
% allocations sit on top of this host budget.
MEMORY_BUDGET_GB = 4;

% PDI parameters (these win over whatever was saved at acquisition time)
PDISpec.ensembleSize = 100;
PDISpec.shiftSize    = 100;
PDISpec.threshold    = single(0.4);
PDISpec.svdMethod    = 'Covariance';
PDISpec.cropPDI      = logical(false);

% Optional re-storage of the resulting PDI. Leave folderStoragePath empty to skip.
StorageSpec.folderStoragePath   = '';
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(false);
StorageSpec.savePDI             = logical(true);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(true);

if isempty(load_path)
    error('process_echoframe_bf_to_pdi_data:missingPath', ...
          'Set load_path to the recording folder with %s + ScanParameters.mat.', bf_file);
end

%% Load the spec structs (everything except PDISpec, which the user controls above)
S = load(fullfile(load_path, 'ScanParameters.mat'));
ProbeSpec      = S.ProbeSpec;
TransmitSpec   = S.TransmitSpec;
ReceiveSpec    = S.ReceiveSpec;
ReconSpec      = S.ReconSpec;
ExperimentSpec = S.ExperimentSpec;

%% Open BF file (guarded so we don't leak on error)
filepath = fullfile(load_path, bf_file);
fileID   = fopen(filepath);
if fileID < 0
    error('Could not open %s.', filepath);
end
cleanup = onCleanup(@() fclose(fileID));

%% Read header + sizing
HeaderSpec = read_header(fileID);


nBuffers     = double(HeaderSpec.buffersStored);
bufferSize   = double(HeaderSpec.effectiveBufferSize);   % complex elements per buffer
nRepeats_buf = double(ReceiveSpec.nRepeats);             % slow-time columns per buffer
% A recording made with ReconSpec.cropBF stored only the ROI, so the frames on
% disk are smaller than the full nz x nx grid. Size from what was actually
% written, and re-point the reconstruction grid at it so the PDI stage is
% initialised for the frames it will receive.
[M_nz, M_nx, storedCropped] = stored_frame_size(ReconSpec, ReconSpec.cropBF);
M = M_nz * M_nx;                                        % pixels per slow-time column

if storedCropped
    roi = double(ReconSpec.croppingROI);
    fprintf(['Stored BF is cropped: %d x %d (ROI z %g-%g, x %g-%g) out of a ', ...
             '%d x %d grid. Processing the cropped frames.\n'], ...
            M_nz, M_nx, roi(1), roi(2), roi(3), roi(4), ...
            double(ReconSpec.nz), double(ReconSpec.nx));

    % Display axes must follow the ROI, or the PDI image is labelled with the
    % full-frame depths. Do this before nz/nx are overwritten below.
    % croppingROI is 0-based inclusive, so MATLAB indices are roi+1.
    rz = (roi(1) + 1):(roi(2) + 1);
    rx = (roi(3) + 1):(roi(4) + 1);
    if isfield(ReconSpec, 'zAxis') && numel(ReconSpec.zAxis) >= rz(end)
        ReconSpec.zAxis = ReconSpec.zAxis(rz);
    end
    if isfield(ReconSpec, 'xAxis') && numel(ReconSpec.xAxis) >= rx(end)
        ReconSpec.xAxis = ReconSpec.xAxis(rx);
    end

    % The cropped frame IS the grid from here on. croppingROI is reset to span
    % it, and both crop flags are cleared so nothing crops a second time.
    ReconSpec.nz          = int32(M_nz);
    ReconSpec.nx          = int32(M_nx);
    ReconSpec.croppingROI = int32([0; M_nz - 1; 0; M_nx - 1]);   % 0-based inclusive
    ReconSpec.cropBF      = logical(false);
    PDISpec.cropPDI       = logical(false);
end

if M * nRepeats_buf ~= bufferSize
    error('process_echoframe_bf_to_pdi_data:geometry', ...
          ['Frame size %d x %d x %d repeats (%d) does not match the stored ', ...
           'buffer size (%d). ScanParameters.mat may not belong to this ', ...
           'recording.'], ...
          M_nz, M_nx, nRepeats_buf, M * nRepeats_buf, bufferSize);



end

ens   = double(PDISpec.ensembleSize);
shift = double(PDISpec.shiftSize);
T     = nBuffers * nRepeats_buf;                         % total slow-time columns

%% Size + stream the BF stack through batch_loading
loader = batch_loading.forBF(fileID, HeaderSpec, M, ens, shift, MEMORY_BUDGET_GB);
nEnsembles = loader.totalFrames;   % PDI frames over the whole recording = floor((T-ens)/shift)+1

fprintf('%d buffers, %d slow-time samples. %d PDI frame(s) total (ensemble=%d, shift=%d).\n', ...
        nBuffers, T, nEnsembles, ens, shift);
if loader.wholeLoad
    fprintf('Whole recording fits the %.1f GB budget: loading all %d frame(s) in one call.\n', ...
            MEMORY_BUDGET_GB, nEnsembles);
else
    fprintf('Batching %d frame(s)/call in %d call(s), budget %.1f GB.\n', ...
            loader.framesPerBatch, loader.nBatches, MEMORY_BUDGET_GB);
end

%% Storage bookkeeping
saveFlag = ~isempty(StorageSpec.folderStoragePath);
ExperimentSpec.numberOfPDIsExperiment = loader.nBatches;   % one stored PDI buffer per process call
if saveFlag && loader.nBatches > 1
    fprintf('Saving: appending %d PDI buffer(s) to one pdi_acq.dat.\n', loader.nBatches);
end

%% Init the MEX once
ReceiveSpec.nRepeats = int32(loader.slabLen);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec,RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);

echoframe_mex('init_pdi_only', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

%% Process each batch and show its PDI frames in a reused figure
figHandle = figure('Name', 'PDI frames (BF -> PDI offline)');
frameNo   = 0;
while loader.hasNext()
    slab = loader.next();                          % [M, slabLen] complex single
    PDI  = echoframe_mex('process_pdi_only', slab, saveFlag);

    for idx = 1:size(PDI, 3)
        frameNo     = frameNo + 1;
        PDI_frame   = PDI(:,:,idx);
        PDI_norm_db = 10*log10(PDI_frame ./ max(PDI_frame(:)));
        imagesc(PDI_norm_db);
        colormap hot; colorbar;
        axis equal ij tight;
        title(sprintf('frame %d/%d  (ensemble=%d, shift=%d, threshold=%.3f)', ...
                      frameNo, nEnsembles, ens, shift, PDISpec.threshold));
        drawnow;
        pause(0.5);
    end
end

%% Clean up
echoframe_mex('destroy')
clear mex;
