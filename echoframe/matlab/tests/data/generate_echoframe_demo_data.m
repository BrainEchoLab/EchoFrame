% generate_echoframe_demo_data - Produce a multi-buffer demo dataset.
%
% Simulates one logo RF buffer with simulate_logo_rf, then writes N_BUFFERS
% buffers to disk using EchoFrame's storage path. Each buffer gets fresh
% additive noise so successive frames differ — enough for SVD-based PDI to
% reject "tissue" and reveal "blood" (the noise that varies frame to frame).
%
% The output folder contains:
%   ScanParameters.mat   - the spec structs (saved by init_storage)
%   rf_acq.dat           - RF buffers (saved by `storage` MEX)
%   bf_acq.dat           - BF buffers (saved by echoframe_mex 'process')
%
% Use this to feed the consumer scripts in this folder:
%   process_echoframe_data.m
%   process_echoframe_bf_to_pdi_data.m
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built.
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

% --- Output
output_dir = fullfile(echoframe_data_root(), 'echoframe_demo_data');   % parent folder
n_buffers  = 5;                                          % number of buffers to write
noise_std  = 200;                                        % int16 std of additive per-buffer noise

% --- Probe / transmit
ProbeSpec.pitch          = 300e-6;
ProbeSpec.Fc             = 5e6;
ProbeSpec.nElements      = 128;

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

% --- Receive (per-buffer slow-time)
ReceiveSpec.nRepeats       = 40;
ReceiveSpec.Fs             = 20e6;
ReceiveSpec.nTransmissions = length(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';

% --- Reconstruction
ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(false);     % we only need BF on disk; PDI is computed offline by consumers
ReconSpec.extraVoxelsZ      = 0;
ReconSpec.extraVoxelsX      = 128;
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = [0; 128; 0; 128];

% --- PDI (acquisition-time defaults; consumers can re-window with any ensembleSize/shiftSize)
PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

% --- Storage (write RF + BF; PDI/RFTimeTag off)
StorageSpec.folderStoragePath   = output_dir;
StorageSpec.saveRF              = logical(true);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI             = logical(false);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(true);

% --- Experiment metadata (controls preallocated file size)
ExperimentSpec.numberOfPDIsExperiment = n_buffers;

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

%% Simulate one base RF buffer
fprintf('Simulating base RF buffer with simulate_logo_rf...\n');
[RF_base, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

%% Initialise reconstruction + storage + MEX
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

% init_storage builds all storage specs and savesScanParameters.mat
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ... 
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ... 
                ExperimentSpec,TransmitSpec, ProbeSpec);

[ ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec ] = ... 
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ... 
    BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

%% Resolve the actual recording subfolder (init_storage adds a timestamped one)
StorageSpec   = evalin('base', 'StorageSpec');
recording_dir = StorageSpec.experimentStoragePath;
fprintf('Writing %d buffers to:\n  %s\n', n_buffers, recording_dir);

%% Generate and store n_buffers noisy variants of the base buffer
rng(1);   % deterministic per-buffer noise
for k = 1:n_buffers
    noise = int16(round(noise_std * randn(size(RF_base))));
    RF    = RF_base + noise;
    
    [ ~, ~, ~] = echoframe_mex('process', RF, true); % runs BF + writes bf_acq.dat 
    mark_first_write(recording_dir);% stamp first - write time(once)

    fprintf('  buffer %d / %d written\n', k, n_buffers);
end

%% Clean up
echoframe_mex('destroy');   % release BF/RF file handles before clear mex
clear mex;

% Stamp the recording-end time (and the data files' actual write times) into
% RecordingInfo.txt now that the files are flushed and closed.
finalize_recording_info(recording_dir);

fprintf('\nDone. Point the consumer scripts'' load_path at:\n  %s\n', ...
        recording_dir);
