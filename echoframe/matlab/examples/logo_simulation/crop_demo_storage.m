% crop_demo_storage - Cropped storage, end to end: write to disk, read back, look.
%
% Beamforms one simulated logo buffer, then stores it TWICE through the real
% storage path:
%   run FULL : cropBF/cropPDI false -> bf_acq.dat / pdi_acq.dat hold the whole frame
%   run CROP : cropBF/cropPDI true  -> the files hold only croppingROI
% Both files are then read back off disk with read_header + stored_frame_size and
% displayed side by side, and the cropped read is checked against the full read's
% ROI element-wise.
%
% MUST run in an ELEVATED MATLAB. The storage Handler calls assignPriviledges()
% before it opens any file (Handler.t.hpp:37); without SE_MANAGE_VOLUME_NAME it
% prints the error and calls std::terminate(), which takes MATLAB down with it.
%
% Prereq: ECHOFRAME_PATH, echoframe_mex + storage MEX built, a CUDA GPU,
%         elevated MATLAB.
% Usage:  run it. PNGs are written to OUT_DIR.

clear; close all; clear mex;

% Paths first: echoframe_data_root below is one of the functions genpath adds.
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

OUT_DIR = fullfile(echoframe_data_root(), 'echoframe_crop_demo_storage');
if isfolder(OUT_DIR), rmdir(OUT_DIR, 's'); end
mkdir(OUT_DIR);

%% ------------------------------------------------------------------ specs
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

ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(true);
ReconSpec.extraVoxelsZ      = 0;
ReconSpec.extraVoxelsX      = 128;
ReconSpec.c0                = TransmitSpec.c0;

PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.svdMethod    = 'Covariance';

fprintf('Simulating RF...\n');
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

% Size the grid once so the ROI can be expressed in real pixels.
probeS = ProbeSpec; recvS = ReceiveSpec; reconS = ReconSpec;
reconS.cropBF = logical(false);
reconS.croppingROI = [0; 1; 0; 1];
[~, recvS, reconS] = initialize_image_reconstruction(probeS, TransmitSpec, recvS, reconS);
nz = double(reconS.nz);  nx = double(reconS.nx);
fprintf('Grid: %d x %d\n', nz, nx);

% The ROI to store. croppingROI is 0-BASED inclusive (see verify_crop_storage:110),
% so MATLAB slices of the full frame are ROI+1.
ROI = [round(nz*0.30); round(nz*0.78); round(nx*0.22); round(nx*0.72)];
fprintf('ROI: z %d-%d, x %d-%d  ->  %d x %d\n', ROI(1), ROI(2), ROI(3), ROI(4), ...
        ROI(2)-ROI(1)+1, ROI(4)-ROI(3)+1);

%% ------------------------------------------------- store twice, read back
runs = struct('name', {'full', 'cropped'}, 'crop', {false, true});
out  = struct();

for r = 1:numel(runs)
    folder = fullfile(OUT_DIR, runs(r).name);
    mkdir(folder);

    P = ProbeSpec; T = TransmitSpec; R = ReceiveSpec;
    C = ReconSpec; D = PDISpec;
    C.cropBF      = logical(runs(r).crop);
    D.cropPDI     = logical(runs(r).crop);
    C.croppingROI = ROI;

    [P, R, C] = initialize_image_reconstruction(P, T, R, C);

    StorageSpec.folderStoragePath   = folder;
    StorageSpec.saveRF              = logical(false);
    StorageSpec.saveBF              = logical(true);
    StorageSpec.savePDI             = logical(true);
    StorageSpec.saveRFTimeTag       = logical(false);
    StorageSpec.preallocateFullFile = logical(true);
    ExperimentSpec.numberOfPDIsExperiment = 1;

    [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
        init_storage('init', StorageSpec, R, C, D, ExperimentSpec, T, P);
    [P, T, R, C, D] = echoframe_validate_structs(P, T, R, C, D);

    echoframe_mex('init', R, C, D, ...
                  BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);
    echoframe_mex('process', RF, true);        % startStorage -> writes the .dat files
    echoframe_mex('destroy');
    clear mex;

    % --- read the BF and PDI back off disk, sized by what was written
    [fz, fx] = stored_frame_size(C, C.cropBF);
    fid = fopen([BFStorageSpec.filepath '.dat']);
    H   = read_header(fid);
    raw = fread(fid, 2*double(H.effectiveBufferSize), '*single');
    fclose(fid);
    bf  = reshape(raw(1:2:end) + 1i*raw(2:2:end), fz, fx, []);

    [pz, px] = stored_frame_size(C, D.cropPDI);
    fid = fopen([PDIStorageSpec.filepath '.dat']);
    Hp  = read_header(fid);
    rawp = fread(fid, double(Hp.effectiveBufferSize), '*single');
    fclose(fid);
    pdi = reshape(rawp, pz, px, []);

    out.(runs(r).name).bf   = bf;
    out.(runs(r).name).pdi  = pdi;
    out.(runs(r).name).C    = C;
    out.(runs(r).name).hdrBF  = H;
    out.(runs(r).name).hdrPDI = Hp;

    fprintf(['%-8s stored: BF %d elem/buffer -> frame %dx%d | ', ...
             'PDI %d elem/buffer -> frame %dx%d\n'], ...
            runs(r).name, H.effectiveBufferSize, fz, fx, ...
            Hp.effectiveBufferSize, pz, px);
end

%% -------------------------------------------- check: cropped == full(ROI)
fullBF  = out.full.bf(:,:,1);
cropBF_ = out.cropped.bf(:,:,1);
rz = (ROI(1)+1):(ROI(2)+1);  rx = (ROI(3)+1):(ROI(4)+1);
refBF   = fullBF(rz, rx);
fprintf('\nBF  cropped == full(ROI) element-wise : %d  (max|diff| = %g)\n', ...
        isequal(cropBF_, refBF), max(abs(cropBF_(:) - refBF(:))));

fullPDI = out.full.pdi(:,:,1);
cropPDI_= out.cropped.pdi(:,:,1);
refPDI  = fullPDI(rz, rx);
fprintf('PDI cropped == full(ROI) element-wise : %d  (max|diff| = %g)\n', ...
        isequal(cropPDI_, refPDI), max(abs(cropPDI_(:) - refPDI(:))));

bytesFull = numel(fullBF); bytesCrop = numel(cropBF_);
fprintf('Cropped BF is %.0f%% of the full frame (%d vs %d pixels)\n', ...
        100*bytesCrop/bytesFull, bytesCrop, bytesFull);

%% ---------------------------------------------------------------- figures
Cfull = out.full.C;
zF = Cfull.zAxis; xF = Cfull.xAxis;
zC = zF(rz); xC = xF(rx);

for m = {'BF', 'PDI'}
    mod = m{1};
    if strcmp(mod, 'BF')
        A = real(20*log10(abs(fullBF)./max(abs(fullBF(:)))));
        B = real(20*log10(abs(cropBF_)./max(abs(fullBF(:)))));
        cmap = gray; lims = [-40 0];
    else
        A = 10*log10(fullPDI./max(fullPDI(:)));
        B = 10*log10(cropPDI_./max(fullPDI(:)));
        cmap = hot;  lims = [-30 0];
    end

    f = figure('Position', [80 80 1300 640]);
    tl = tiledlayout(f, 1, 2, 'TileSpacing','compact', 'Padding','compact');
    title(tl, sprintf(['%s read back from disk: full recording vs cropped ', ...
                       'recording (written by the storage layer)'], mod), ...
          'FontWeight','bold');

    nexttile;
    imagesc(xF, zF, A); colormap(gca, cmap); clim(lims); axis equal tight; hold on;
    rectangle('Position', [xF(rx(1)), zF(rz(1)), ...
                           xF(rx(end))-xF(rx(1)), zF(rz(end))-zF(rz(1))], ...
              'EdgeColor','c', 'LineWidth', 2); hold off;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title(sprintf('full/%s_acq.dat  -  %d x %d px', lower(mod), size(A,1), size(A,2)), ...
          'Interpreter','none');

    nexttile;
    imagesc(xC, zC, B); colormap(gca, cmap); clim(lims); axis equal tight;
    xlabel('Width [mm]'); ylabel('Depth [mm]');
    title(sprintf('cropped/%s_acq.dat  -  %d x %d px  (%.0f%% of the bytes)', ...
                  lower(mod), size(B,1), size(B,2), 100*numel(B)/numel(A)), ...
          'Interpreter','none');

    png = fullfile(OUT_DIR, sprintf('storage_crop_%s.png', lower(mod)));
    exportgraphics(f, png, 'Resolution', 150);
    fprintf('wrote %s\n', png);
end

fprintf('\nImages and recordings are in: %s\n', OUT_DIR);
clear mex;
