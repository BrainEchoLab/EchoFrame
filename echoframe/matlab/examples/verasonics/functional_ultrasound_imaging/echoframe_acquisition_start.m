% echoframe_acquisition_start - Live Verasonics + EchoFrame fUS acquisition.
%
% Launches Verasonics Vantage with a plane-wave probe setup, initialises the
% EchoFrame reconstruction pipeline and its storage, and runs a real-time
% acquisition with a live B-mode + PDI display.
%
% RF / BF / PDI / RF-time-tag are written to disk under STORAGE_PATH via
% init_storage. Set the StorageSpec.save* flags below to pick which.
%
% Prereq: Verasonics Vantage installation, VERASONICS_VPF_ROOT env var,
%         ECHOFRAME_PATH env var, echoframe_mex built.
% Usage:  edit STORAGE_PATH and the parameters below; pick a probe setup
%         script (L74_demo / GE9LD_demo); run.

clear all;
clear global;
clear persistent   % ef_external_process counts frames in persistents; a second
                   % run in the same session would otherwise resume the old count
clear mex;


%% Activate Verasonics
fprintf('Starting VS program...\n');
vantage_path = getenv('VERASONICS_VPF_ROOT');
cd(vantage_path);            % Go to Vantage folder and call VS function 'activate'
activate;

%% Assign globals
global ECHOFRAME_PATH Resource ProbeSpec TransmitSpec ReceiveSpec ReconSpec ExperimentSpec

%% EchoFrame paths
% Before the parameters below: STORAGE_PATH calls echoframe_data_root, and
% `activate` has just left the working directory inside Vantage, so nothing of
% ours is reachable until this has run.
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
assignin('base', 'ECHOFRAME_PATH', ECHOFRAME_PATH);

%% User parameters
STORAGE_PATH    = echoframe_data_root();  % Folder the recording is written to
EXPERIMENT_TIME = 30;                   % Recording duration [s]
TIMELINE_ACQS   = 20;                   % Acquisitions shown on the live timeline
SIMULATE        = false;                 % false transmits on the connected probe

%% Storage parameters
% folderStoragePath is the parent; init_storage creates a timestamped
% 'recording_<date>' folder inside it and writes ScanParameters.mat there.
StorageSpec.folderStoragePath   = STORAGE_PATH;
StorageSpec.saveRF              = true;
StorageSpec.saveBF              = true;
StorageSpec.savePDI             = true;
StorageSpec.saveRFTimeTag       = true;
StorageSpec.preallocateFullFile = true;
if ~isfolder(StorageSpec.folderStoragePath)
    mkdir(StorageSpec.folderStoragePath);
end

%% Set up Verasonics variables
import com.verasonics.hal.hardware.*
Hardware.enableAcquisitionTimeTagging(true);
Hardware.setTimeTaggingAttributes(false, true);
Resource.Parameters.simulateMode = double(SIMULATE);   % SIMULATE is set at the top
Resource.Parameters.waitForProcessing = 1;  % Required for mode 'Synchronous Acquisition and Concurrent Processing'
Resource.Parameters.numTransmit = 256;      % number of transmit channels.
Resource.Parameters.numRcvChannels = 256;   % number of receive channels.
Resource.VDAS.dmaTimeout = 120 * 1000;      % In msec
Resource.Parameters.GUI = 'vsx_gui';

% VSX reads the base-workspace variable 'filename' to find the .mat to run.
% It must keep this exact name, otherwise VSX prompts for one interactively.
filename = 'vsx_echoframe_input_file'; % What to name temp workspace .mat file

%% Set up probe and acquisition
% L7-4 is a stock Verasonics probe; GE9LD needs the GE connector.
fprintf('Set up probe and acquisition...\n');
%L74_demo
GE9LD_demo

%% Parse Verasonics structures to EchoFrame structures
[ProbeSpec, TransmitSpec, ReceiveSpec] = vsx_to_ef_structs(Resource, Trans, TX, Receive, ProbeSpec, TransmitSpec, ReceiveSpec);

%% Initialize the image reconstruction
fprintf('Initialize image reconstruction...\n');
ReconSpec.bfDataType = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF = logical(true);
ReconSpec.getPDI = logical(true);
ReconSpec.cropBF = logical(false);
ReconSpec.croppingROI = [0; 128; 0; 128]; % Format [zTop; zBottom; xLeft; xRight]
[ProbeSpec, ReceiveSpec, ReconSpec] = initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

%% Define Power Doppler processing parameters
PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold = single(0.4);   % Fraction of ensemble removed (clutter)
PDISpec.shiftSize = ReceiveSpec.nRepeats;
PDISpec.cropPDI = logical(false);
PDISpec.svdMethod = 'Covariance';

%% Experiment struct init
% How many PDIs the run produces, which sets the preallocated file length.
ExperimentSpec.experimentTime = EXPERIMENT_TIME;
ExperimentSpec.numberOfPDIsExperiment = ceil(ExperimentSpec.experimentTime / ...
    (1 / TransmitSpec.txrxFrameRate * single(ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats)));

%% Validate EchoFrame inputs
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

%% Page-lock the receive buffers
% Safe here because Verasonics keeps Resource.RcvBuffer for the whole session.
% See core/storage/README.md before setting it anywhere else.
setenv('EF_PIN_RF', '1');

%% What this configuration asks of the drive
% Printed before anything is written, so a rate the disk cannot hold is visible
% up front rather than as queued writes later.
demand = report_storage_demand(StorageSpec, ReceiveSpec, ReconSpec, PDISpec, TransmitSpec);
assignin('base', 'EF_BUDGET_MS', demand.framePeriodMs);   % ef_external_process reports against it
% Seeded with the nominal period so the teardown report works even if the
% acquisition never ran; ef_external_process replaces it with the measured one.
assignin('base', 'EF_LOOP_MS', demand.framePeriodMs);
assignin('base', 'EF_TIMELINE_ACQS', TIMELINE_ACQS);   % width of the live timeline

% Checks the recording fits, and sizes the projection on the live disk bar.
echoframe_disk_monitor('check', StorageSpec.folderStoragePath, ...
                       demand.bytesPerFrame * double(ExperimentSpec.numberOfPDIsExperiment));

%% Init Storage
% Builds the per-stream storage specs from the acquisition specs, creates the
% recording folder, and saves ScanParameters.mat. RF is stored inside
% echoframe_mex (RFStorageSpec is passed to 'init' below).
[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);

%% Initialize EchoFrame
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

%% Create figures for live mode
setup_echoframe_figure

%% Add the Store toggle to the VSX controls
setup_echoframe_gui

%% Extra assignins
assignin('base', 'ProbeSpec', ProbeSpec);
assignin('base', 'TransmitSpec', TransmitSpec);
assignin('base', 'ReceiveSpec', ReceiveSpec);
assignin('base', 'PDISpec', PDISpec);
assignin('base', 'ReconSpec', ReconSpec);
assignin('base', 'ExperimentSpec', ExperimentSpec);
% Seeds for the SVD sliders; the callback applies a change on its next frame.
assignin('base', 'SVD_update_flag', 0);
assignin('base', 'SVD_threshold', double(PDISpec.threshold));
assignin('base', 'SVD_lower_update_flag', 0);
assignin('base', 'SVD_lower_threshold', 0);
% Saving starts off; the Store button turns it on.
assignin('base', 'save_rf_pdi', false);
assignin('base', 'updateExperiment', 0);        % set when Store is switched off
assignin('base', 'updateStateSaveButton', 0);   % set when a run fills its files

%% Run Acquisition
save(filename);
close all
VSX

%% Storage write headroom
% Reads the write instrumentation out of echoframe_mex, so it has to run before
% 'destroy'. Reports how close each stream came to filling its write queue and
% whether any write outlasted the acquisition ring.
check_storage_headroom(evalin('base', 'EF_LOOP_MS'), ReceiveSpec);

%% Cleanup
% destroy flushes and closes the storage files; it must run before clear mex,
% otherwise they stay locked and clean_empty_files cannot remove an unused
% recording folder.
try
    echoframe_mex('destroy')
catch destroyErr
    warning('echoframe_acquisition_start:destroy', ...
            'echoframe_mex(''destroy'') failed: %s', destroyErr.message);
end
clear mex

%% Release the RF page-lock for the rest of the session
% setenv persists for the whole MATLAB process, and EF_PIN_RF is only safe
% while the caller keeps its RF buffers alive, as this acquisition does with
% Resource.RcvBuffer. Anything run afterwards in the same session allocates RF
% per call, so leaving it set page-locks a transient array and the next
% transfer from that reused address fails -- three storage harnesses died in
% RF_formatter's cudaMemcpy with "invalid argument" for exactly this reason,
% having passed in the same session before the acquisition ran.
setenv('EF_PIN_RF', '');

%% Stamp the recording-end time into RecordingInfo.txt
finalize_recording_info(StorageSpec.experimentStoragePath)

%% Clean up empty folders
clean_empty_files(StorageSpec.folderStoragePath)
return
