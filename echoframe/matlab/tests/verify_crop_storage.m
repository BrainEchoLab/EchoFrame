% verify_crop_storage - Verify that BF/PDI storage writes the CROPPED ROI, not the full frame.
%
% Two-run A/B on one deterministic RF buffer:
%   run FULL : cropBF=false, cropPDI=false  -> stores full  bf_acq.dat / pdi_acq.dat
%   run CROP : cropBF=true,  cropPDI=true   -> stores cropped bf_acq.dat / pdi_acq.dat
% Both runs share the same RF and the same reconstruction tables, so the beamformed
% output is identical; only the crop flags differ. We then read both stored files and
% assert:
%   (control) the stored header's per-buffer size tracks the flag
%             full  == nz*nx*nRepeats ,  cropped == cNz*cNx*(nRepeats|nEnsembles)
%   (content) cropped == full(ROI) element-wise  <- proves the RIGHT rectangle is stored
%
% Coverage: BF and PDI; a cropBF=false control (proves the flag toggles, not always-crop);
% and an ASYMMETRIC ROI (cNz != cNx) so a row/column (axis) swap can't pass unnoticed.
%
% Covers TWO PDI ensemble configs in one run: nEnsembles==1 (ensembleSize==shiftSize==
% nRepeats) and a sliding window (ensembleSize=20, shiftSize=10 over nRepeats=40 ->
% nEnsembles=3), exercising the per-ensemble crop offset and the cropped-PDI storage
% sizing.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built (set MEX_DIR to pin a specific
% build, e.g. echoframe\cpp\src\build\Release). GPU required.
%
% MUST run in an ELEVATED MATLAB: the storage Handler acquires SeManageVolumePrivilege
% at init unconditionally (Handler.t.hpp assignPriviledges), so any storage-enabled
% init aborts in a non-elevated process -- regardless of preallocateFullFile.
% preallocateFullFile defaults to true; env EF_NO_PREALLOC=1 turns preallocation off,
% but does not remove the elevation requirement.
% Usage: run (from an elevated MATLAB).

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
if ~isempty(getenv('MEX_DIR'))
    addpath(getenv('MEX_DIR'));   % pin the MEX under test; added last so it wins
end

out_root = fullfile(echoframe_data_root(), 'echoframe_verify_crop');
if exist(out_root, 'dir'); rmdir(out_root, 's'); end
mkdir(out_root);

%% Base specs (deterministic) -- mirrors generate_echoframe_demo_data
ProbeSpec.pitch          = 300e-6;
ProbeSpec.Fc             = 5e6;
ProbeSpec.nElements      = 128;

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

ReceiveSpec.nRepeats       = 40;
ReceiveSpec.Fs             = 20e6;
ReceiveSpec.nTransmissions = numel(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';
ReceiveSpec.nBuffers       = 1;

ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(true);
ReconSpec.extraVoxelsZ      = 0;
ReconSpec.extraVoxelsX      = 128;
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);       % set per run
ReconSpec.croppingROI       = int32([0;1;0;1]);     % set per run

PDISpec.ensembleSize = ReceiveSpec.nRepeats;        % ensembleSize==shiftSize==nRepeats -> nEnsembles==1
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);              % set per run
PDISpec.svdMethod    = 'Covariance';

%% One deterministic RF buffer + reconstruction tables (shared by both runs)
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

% EF_SQUARE=1 forces a SQUARE grid (nx == nz) by padding the lateral axis. nz is
% pinned by the acquisition (nz = nSamplesIQ + extraVoxelsZ), so we raise nx to
% match it. Use this to check the masking hypothesis: the crop lateral-stride bug
% is invisible when nz == nx.
if ~isempty(getenv('EF_SQUARE'))
    Nz_pred = double(ReceiveSpec.nSamplesIQ) + double(ReconSpec.extraVoxelsZ);
    Nz_pred = Nz_pred + rem(Nz_pred, 2);
    ReconSpec.extraVoxelsX = Nz_pred - double(ReceiveSpec.nChannels);
    fprintf('EF_SQUARE: forcing nx == nz == %d (extraVoxelsX = %d)\n', ...
            Nz_pred, ReconSpec.extraVoxelsX);
end

[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

nz   = double(ReconSpec.nz);
nx   = double(ReconSpec.nx);
nRep = double(ReceiveSpec.nRepeats);

% Asymmetric ROI (0-based, inclusive). cNz != cNx catches an axis swap.
zTop = round(0.20 * nz);  zBot = round(0.55 * nz);
xLeft = round(0.30 * nx); xRight = round(0.45 * nx);
ROI  = int32([zTop; zBot; xLeft; xRight]);
cNz  = zBot  - zTop  + 1;
cNx  = xRight - xLeft + 1;
assert(cNz ~= cNx, 'ROI must be asymmetric to catch axis swaps.');
fprintf('Grid nz=%d nx=%d nRep=%d | ROI z[%d..%d]=%d  x[%d..%d]=%d\n', ...
        nz, nx, nRep, zTop, zBot, cNz, xLeft, xRight, cNx);

%% Test each PDI ensemble configuration: nEns==1 and a sliding window (nEns>1)
configs = { struct('ens', nRep, 'shift', nRep), ...   % ensembleSize==shiftSize==nRepeats -> nEns==1
            struct('ens', 20,   'shift', 10) };        % sliding window over nRepeats=40 -> nEns==3
pass = true;
rz = (zTop + 1):(zBot + 1);
rx = (xLeft + 1):(xRight + 1);

for i = 1:numel(configs)
    PDISpec.ensembleSize = configs{i}.ens;
    PDISpec.shiftSize    = configs{i}.shift;
    nEns = max(0, floor((nRep - double(PDISpec.ensembleSize)) / double(PDISpec.shiftSize)) + 1);
    fprintf('\n--- Config %d: ensembleSize=%d shiftSize=%d -> nEnsembles=%d ---\n', ...
            i, PDISpec.ensembleSize, PDISpec.shiftSize, nEns);

    full = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RF, false, ROI, fullfile(out_root, sprintf('cfg%d_full', i)));
    crop = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RF, true,  ROI, fullfile(out_root, sprintf('cfg%d_crop', i)));

    % -- BF (independent of nEns): header sizes + content --
    pass = check(sprintf('BF  full header == nz*nx*nRep     (%d)', nz*nx*nRep), ...
                 full.bfHdr.effectiveBufferSize == nz*nx*nRep) && pass;
    pass = check(sprintf('BF  crop header == cNz*cNx*nRep    (%d)', cNz*cNx*nRep), ...
                 crop.bfHdr.effectiveBufferSize == cNz*cNx*nRep) && pass;
    pass = check('BF  crop header < full header (flag toggles)', ...
                 crop.bfHdr.effectiveBufferSize < full.bfHdr.effectiveBufferSize) && pass;
    if full.bfHdr.effectiveBufferSize == nz*nx*nRep && crop.bfHdr.effectiveBufferSize == cNz*cNx*nRep
        BF_full = reshape(full.bfVec, nz, nx, nRep);
        BF_crop = reshape(crop.bfVec, cNz, cNx, nRep);
        ref     = BF_full(rz, rx, :);
        dBF     = max(abs(BF_crop(:) - ref(:)));
        tolBF   = 1e-4 * max(abs(ref(:))) + eps;
        pass = check(sprintf('BF  cropped == full(ROI)   (max|diff|=%.3g, tol=%.3g)', dBF, tolBF), dBF <= tolBF) && pass;
    else
        pass = check('BF  content compare (SKIPPED -- header size mismatch)', false) && pass;
    end

    % -- PDI (nEns frames): header sizes + content across ALL frames --
    pass = check(sprintf('PDI full header == nz*nx*nEns     (%d)', nz*nx*nEns), ...
                 full.pdiHdr.effectiveBufferSize == nz*nx*nEns) && pass;
    pass = check(sprintf('PDI crop header == cNz*cNx*nEns   (%d)', cNz*cNx*nEns), ...
                 crop.pdiHdr.effectiveBufferSize == cNz*cNx*nEns) && pass;
    if full.pdiHdr.effectiveBufferSize == nz*nx*nEns && crop.pdiHdr.effectiveBufferSize == cNz*cNx*nEns
        PDI_full = reshape(full.pdiVec, nz, nx, nEns);
        PDI_crop = reshape(crop.pdiVec, cNz, cNx, nEns);
        refp     = PDI_full(rz, rx, :);
        dPDI     = max(abs(PDI_crop(:) - refp(:)));
        tolPDI   = 1e-4 * max(abs(refp(:))) + eps;
        pass = check(sprintf('PDI cropped == full(ROI) [%d frame(s)] (max|diff|=%.3g, tol=%.3g)', nEns, dPDI, tolPDI), dPDI <= tolPDI) && pass;
    else
        pass = check('PDI content compare (SKIPPED -- header size mismatch)', false) && pass;
    end
end

fprintf('\n==== %s ====\n', ternary(pass, 'ALL CHECKS PASSED', 'SOME CHECKS FAILED'));
if ~pass
    error('verify_crop_storage:failures', 'One or more crop-storage checks failed (see above).');
end

% Test output. Every run_once destroys before it returns, and a failed run
% errors out above and keeps its recordings.
echoframe_cleanup_dir(out_root);

%% ---------------------------------------------------------------- local functions ----
function r = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RF, doCrop, ROI, folder)
% Process RF once with crop on/off, store BF+PDI, then read the raw buffers back.
clear mex;
ReconSpec.cropBF      = logical(doCrop);
PDISpec.cropPDI       = logical(doCrop);
ReconSpec.croppingROI = ROI;
if ~exist(folder, 'dir'); mkdir(folder); end

StorageSpec.folderStoragePath   = folder;
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI            = logical(true);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(isempty(getenv('EF_NO_PREALLOC')));  % true unless EF_NO_PREALLOC=1
ExperimentSpec.numberOfPDIsExperiment = 1;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec); %#ok<ASGLU>

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);
echoframe_mex('process', RF, true);   % startStorage=true -> writes bf_acq.dat / pdi_acq.dat
echoframe_mex('destroy');             % EchoFrameDestroy: drains async writes, closes files, unlocks
clear mex;

[r.bfVec,  r.bfHdr]  = read_complex_vec([BFStorageSpec.filepath  '.dat']);
[r.pdiVec, r.pdiHdr] = read_single_vec([PDIStorageSpec.filepath '.dat']);
end

function [vec, hdr] = read_complex_vec(path)
% Read the first stored buffer as a complex-single column vector, plus its header.
fid = fopen(path, 'r');
assert(fid > 0, 'cannot open %s', path);
c = onCleanup(@() fclose(fid));
hdr = read_header(fid);
fseek(fid, hdr.headerSize, 'bof');
raw = fread(fid, 2 * double(hdr.effectiveBufferSize), '*single');
vec = double(raw(1:2:end)) + 1i * double(raw(2:2:end));
end

function [vec, hdr] = read_single_vec(path)
% Read the first stored buffer as a single column vector, plus its header.
fid = fopen(path, 'r');
assert(fid > 0, 'cannot open %s', path);
c = onCleanup(@() fclose(fid));
hdr = read_header(fid);
fseek(fid, hdr.headerSize, 'bof');
vec = double(fread(fid, double(hdr.effectiveBufferSize), '*single'));
end

function ok = check(name, cond)
ok = logical(cond);
fprintf('  [%s] %s\n', ternary(ok, 'PASS', 'FAIL'), name);
end

function s = ternary(cond, a, b)
if cond; s = a; else; s = b; end
end
