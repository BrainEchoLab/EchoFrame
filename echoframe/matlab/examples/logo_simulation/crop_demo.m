% crop_demo - See what ReconSpec.cropBF / PDISpec.cropPDI actually keep.
%
% Beamforms one simulated logo buffer on the GPU, then shows the full B-mode and
% PDI next to several croppingROI choices, with the depth/width axes subset to
% each ROI so the crops are labelled correctly.
%
% The crop the storage layer writes is exactly full(ROI) element-wise - that is
% what verify_crop_storage asserts - so slicing the full frame here reproduces
% the stored crop without needing an elevated MATLAB for the storage path.
%
% Prereq: ECHOFRAME_PATH, echoframe_mex built, a CUDA GPU. No storage, so no
%         elevation needed.
% Usage:  run it. Figures open, and PNGs are written to OUT_DIR.

clear; close all; clear mex;

%% Where to write the images
OUT_DIR = fullfile(tempdir, 'echoframe_crop_demo');
if ~isfolder(OUT_DIR), mkdir(OUT_DIR); end

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

%% Acquisition + reconstruction specs (same shape as the logo demo)
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
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = [0; 128; 0; 128];

PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

%% Simulate + reconstruct once; every crop below is a view of this same frame
fprintf('Simulating RF (this takes ~25 s)...\n');
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);
[PDI, Bmode, ~] = echoframe_mex('process', RF, false);
echoframe_mex('destroy');

nz = double(ReconSpec.nz);
nx = double(ReconSpec.nx);
fprintf('Reconstructed grid: %d x %d\n', nz, nx);

BmodeLog  = real(20*log10(Bmode ./ max(Bmode(:))));
PDIFrame  = PDI(:,:,1);
PDILog    = 10*log10(PDIFrame ./ max(PDIFrame(:)));

%% The ROIs to show. [zTop; zBottom; xLeft; xRight], 1-based inclusive.
rois = { ...
    'full frame',            [1;   nz;      1;   nx     ]; ...
    'centre half',           [round(nz/4); round(3*nz/4); round(nx/4); round(3*nx/4)]; ...
    'shallow band',          [1;   round(nz/3); 1;   nx     ]; ...
    'deep band',             [round(2*nz/3); nz; 1;   nx     ]; ...
    'left third',            [1;   nz;      1;   round(nx/3)]; ...
    'tall narrow (off-centre)', [round(nz/5); round(4*nz/5); round(nx/2); round(nx/2)+round(nx/5)] ...
};

%% One figure per modality, ROIs as tiles
for modality = {'Bmode', 'PDI'}
    name = modality{1};
    if strcmp(name, 'Bmode'), img = BmodeLog; cmap = gray; lims = [-40 0];
    else,                     img = PDILog;   cmap = hot;  lims = [-30 0];
    end

    f = figure('Name', [name ' - cropping'], 'Position', [80 80 1500 850]);
    tl = tiledlayout(f, 2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, sprintf('%s: full frame vs croppingROI choices (grid %d x %d)', ...
                      name, nz, nx), 'FontWeight', 'bold');

    for k = 1:size(rois, 1)
        label = rois{k, 1};
        roi   = rois{k, 2};
        zT = roi(1); zB = roi(2); xL = roi(3); xR = roi(4);

        % This is exactly what the storage layer writes when the crop flag is set.
        sub   = img(zT:zB, xL:xR);
        zSub  = ReconSpec.zAxis(zT:zB);
        xSub  = ReconSpec.xAxis(xL:xR);

        nexttile;
        imagesc(xSub, zSub, sub);
        colormap(gca, cmap); clim(lims); axis equal tight;
        xlabel('Width [mm]'); ylabel('Depth [mm]');
        title(sprintf('%s  -  %d x %d px', label, zB-zT+1, xR-xL+1));
        if k == 1
            % Mark every other ROI on the full frame for orientation.
            hold on;
            for j = 2:size(rois, 1)
                r = rois{j, 2};
                rectangle('Position', [ReconSpec.xAxis(r(3)), ReconSpec.zAxis(r(1)), ...
                                       ReconSpec.xAxis(r(4)) - ReconSpec.xAxis(r(3)), ...
                                       ReconSpec.zAxis(r(2)) - ReconSpec.zAxis(r(1))], ...
                          'EdgeColor', 'c', 'LineWidth', 1.2);
            end
            hold off;
        end
    end

    png = fullfile(OUT_DIR, sprintf('crop_%s.png', lower(name)));
    exportgraphics(f, png, 'Resolution', 150);
    fprintf('wrote %s\n', png);
end

%% Same ROI, side by side at true relative scale, to show it is a subset not a zoom
roi = rois{2, 2};
f = figure('Name', 'full vs cropped, same pixel scale', 'Position', [80 80 1300 620]);
tl = tiledlayout(f, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, 'Cropping keeps a sub-rectangle of the same pixels (no resampling)', ...
      'FontWeight', 'bold');

nexttile;
imagesc(ReconSpec.xAxis, ReconSpec.zAxis, BmodeLog);
colormap(gca, gray); clim([-40 0]); axis equal tight; hold on;
rectangle('Position', [ReconSpec.xAxis(roi(3)), ReconSpec.zAxis(roi(1)), ...
                       ReconSpec.xAxis(roi(4)) - ReconSpec.xAxis(roi(3)), ...
                       ReconSpec.zAxis(roi(2)) - ReconSpec.zAxis(roi(1))], ...
          'EdgeColor', 'c', 'LineWidth', 2);
hold off;
xlabel('Width [mm]'); ylabel('Depth [mm]');
title(sprintf('stored full: %d x %d px', nz, nx));

nexttile;
imagesc(ReconSpec.xAxis(roi(3):roi(4)), ReconSpec.zAxis(roi(1):roi(2)), ...
        BmodeLog(roi(1):roi(2), roi(3):roi(4)));
colormap(gca, gray); clim([-40 0]); axis equal tight;
xlabel('Width [mm]'); ylabel('Depth [mm]');
title(sprintf('stored cropped: %d x %d px  (%.0f%% of the bytes)', ...
              roi(2)-roi(1)+1, roi(4)-roi(3)+1, ...
              100 * ((roi(2)-roi(1)+1)*(roi(4)-roi(3)+1)) / (nz*nx)));

png = fullfile(OUT_DIR, 'crop_side_by_side.png');
exportgraphics(f, png, 'Resolution', 150);
fprintf('wrote %s\n', png);

fprintf('\nImages are in: %s\n', OUT_DIR);
clear mex;
