% process_verasonics_workspace - Process saved Verasonics data with EchoFrame.
%
% Loads a .mat workspace saved from a Verasonics example (Resource, TW, Trans,
% TX, Receive, RcvData), converts the structures into EchoFrame's specs, runs
% Fourier beamforming on the recorded RF, and shows the B-mode result.
%
% Capturing a compatible workspace:
%   1. Run a Verasonics plane-wave example (e.g. SetUpGE9LDFlashAngles.m).
%      Make sure the Receive uses 'BS100BW' and that startDepth = 1.
%   2. Hit "Freeze", close the Verasonics console.
%   3. Save: save(fullfile(load_path, data_name), ...
%               'Resource','TW','Trans','TX','Receive','RcvData')
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built; workspace .mat at data_path.
% Usage:  edit data_path below; run.

clear; close all; clc; clear mex;

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

% --- Data path (folder containing the .mat workspace)
load_path = '';
data_name   = 'echoframe_demo_data.mat';

% --- Reconstruction
ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(false);
ReconSpec.extraVoxelsZ      = 0;
ReconSpec.extraVoxelsX      = 128;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = [0; 128; 0; 128];      % [zTop; zBottom; xLeft; xRight]

% --- PDI (only used if ReconSpec.getPDI = true)
PDISpec.threshold    = single(0.4);
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

% --- Optional storage
StorageSpec.folderStoragePath   = '';                % empty = no storage
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(false);
StorageSpec.savePDI             = logical(false);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(true);

% --- Experiment metadata
ExperimentSpec.numberOfPDIsExperiment = 10;

if isempty(load_path)
    error('process_verasonics_workspace:missingPath', ...
          'Set load_path to the directory containing %s.', data_name);
end

%% Load Verasonics workspace
load(fullfile(load_path, data_name));

%% Convert Verasonics structures to EchoFrame specs
ProbeSpec.init    = 1;
TransmitSpec.init = 1;
ReceiveSpec.init  = 1;
[ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    vsx_to_ef_structs(Resource, Trans, TX, Receive, ProbeSpec, TransmitSpec, ReceiveSpec);
ReconSpec.c0     = TransmitSpec.c0;

% Slow-time / ensemble are derived from the recording
PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.shiftSize    = ReceiveSpec.nRepeats;

%% Initialise reconstruction + storage
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);

%% Validate + initialise MEX
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

%% Reshape RcvData into the layout EchoFrame expects
%  Source: (nSamples*nTransmissions, nChannels, nRepeats)
%  Target: (nSamples*nTransmissions*nRepeats, nChannels)
RF = RcvData{1};
RF = RF(1:Receive(end).endSample, :, :);
RF = permute(RF, [1, 3, 2]);
RF = reshape(RF, size(RF, 1) * size(RF, 2), size(RF, 3));

%% Process
[PDI, Bmode, BF] = echoframe_mex('process', RF, true);

%% Show B-mode
BmodeLog = 20*log10(Bmode ./ max(Bmode(:)) + eps);
figure;
imagesc(ReconSpec.xAxis, ReconSpec.zAxis, BmodeLog);
colormap(gray);
clim([-40 0]);
colorbar;
axis equal ij tight;
xlabel('Width [mm]'); ylabel('Depth [mm]');
title('B-mode [dB]');

%% Clean up
echoframe_mex('destroy');   % release BF/RF file handles before clear mex
clear mex;
