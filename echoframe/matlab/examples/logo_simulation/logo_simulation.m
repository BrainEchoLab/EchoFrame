% logo_simulation - End-to-end EchoFrame demo.
%
% Simulates plane-wave RF data from a phantom built from the EchoFrame logo,
% runs Fourier beamforming and Power Doppler Imaging on GPU via the MEX
% interface, and displays B-mode and PDI side by side.
%
% Prereq: ECHOFRAME_PATH env var set; echoframe_mex built and on the path.
% Usage:  edit the %% Parameters block below; run.

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

% --- Probe geometry
ProbeSpec.pitch          = 300e-6;            % distance between transducer elements [m]
ProbeSpec.Fc             = 5e6;               % centre frequency of the elements [Hz]
ProbeSpec.nElements      = 128;               % number of transducer elements

% --- Transmit
TransmitSpec.c0          = 1540;              % speed of sound [m/s]
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];        % steering angles [degrees]
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

% --- Receive (acquisition)
ReceiveSpec.nRepeats       = 40;              % repeated (compounded) acquisitions
ReceiveSpec.Fs             = 20e6;            % RF sampling frequency [Hz]
ReceiveSpec.nTransmissions = length(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';

% --- Reconstruction
ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(true);
ReconSpec.extraVoxelsZ      = 0;              % z padding (Fourier reconstruction)
ReconSpec.extraVoxelsX      = 128;            % x padding; total Nx = nChannels + extra
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = [0; 128; 0; 128];  % [zTop; zBottom; xLeft; xRight]

% --- PDI
PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);           % fraction of ensemble removed (clutter)
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

% --- ExperimentSpec
ExperimentSpec.numberOfPDIsExperiment = 10;

%% Simulate RF (or load a previously saved RF set)
% ProbeSpec/TransmitSpec/ReceiveSpec are used TWICE: once by simulate_logo_rf to
% synthesise the RF, and again by initialize_image_reconstruction + echoframe_mex to
% reconstruct it. The two must agree -- the beamforming tables are built from pitch,
% Fc, c0, steer and Fs, and the array shape from nSamples/nChannels/nTransmissions.
%
% So a saved RF set has to be processed with the specs it was made from, and loading
% RF_FILE necessarily overrides the probe/transmit/receive parameters above. It says
% so loudly: any edit you made that is being ignored is listed as a warning. Delete
% RF_FILE (or set LOAD_SAVED_RF = false) to re-simulate with your values instead.
%
% ReconSpec and PDISpec are reconstruction-side only and stay editable either way.
RF_FILE       = fullfile(fileparts(mfilename('fullpath')), 'logo_rf.mat');
LOAD_SAVED_RF = isfile(RF_FILE);

if LOAD_SAVED_RF
    fprintf('Loading saved RF from %s\n', RF_FILE);
    saved = load(RF_FILE, 'RF', 'ProbeSpec', 'TransmitSpec', 'ReceiveSpec');

    % Which acquisition parameters set above is the saved RF about to overrule?
    ignored = [ spec_diff('ProbeSpec',    ProbeSpec,    saved.ProbeSpec,    {'pitch','Fc','nElements'}), ...
                spec_diff('TransmitSpec', TransmitSpec, saved.TransmitSpec, {'c0','type','steer','apodization'}), ...
                spec_diff('ReceiveSpec',  ReceiveSpec,  saved.ReceiveSpec,  {'nRepeats','Fs','nTransmissions','samplingMode'}) ];

    % Did the PDI/recon settings just follow ReceiveSpec/TransmitSpec (the defaults
    % above), or were they set deliberately? Deliberate values are kept.
    pdiFollowedRepeats = isequal(double(PDISpec.ensembleSize), double(ReceiveSpec.nRepeats)) && ...
                         isequal(double(PDISpec.shiftSize),    double(ReceiveSpec.nRepeats));
    reconFollowedC0    = isequal(double(ReconSpec.c0), double(TransmitSpec.c0));

    RF           = saved.RF;
    ProbeSpec    = saved.ProbeSpec;
    TransmitSpec = saved.TransmitSpec;
    ReceiveSpec  = saved.ReceiveSpec;

    if ~isempty(ignored)
        warning('logo_simulation:savedRFOverridesParameters', ...
            ['The saved RF in %s was made with different settings, so these ' ...
             'parameters from the block above are being IGNORED:\n    %s\n' ...
             'Delete that file (or set LOAD_SAVED_RF = false) to re-simulate ' ...
             'with your values.'], RF_FILE, strjoin(ignored, ', '));
    end

    % Re-derive only what was left at its default coupling; a value you chose stands.
    if reconFollowedC0,    ReconSpec.c0         = TransmitSpec.c0;   end
    if pdiFollowedRepeats
        PDISpec.ensembleSize = ReceiveSpec.nRepeats;
        PDISpec.shiftSize    = ReceiveSpec.nRepeats;
    elseif PDISpec.ensembleSize > ReceiveSpec.nRepeats
        error('logo_simulation:ensembleTooLong', ...
            ['PDISpec.ensembleSize (%d) exceeds the saved RF''s nRepeats (%d). ' ...
             'Lower it, or delete %s to re-simulate with more repeats.'], ...
            PDISpec.ensembleSize, ReceiveSpec.nRepeats, RF_FILE);
    end
else
    [RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
        simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
    save(RF_FILE, 'RF', 'ProbeSpec', 'TransmitSpec', 'ReceiveSpec');
    fprintf('Saved simulated RF to %s\n', RF_FILE);
end
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;  % derived once nSamples is known

%% Initialise reconstruction
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

%% Validate + initialise MEX
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);

%% Process
[PDI, Bmode, BF] = echoframe_mex('process', RF, false);

%% Show B-mode and PDI side by side
BmodeLog  = real(20*log10(Bmode./max(Bmode(:))));
PDI_frame = PDI(:,:,1);
PDI_norm_db  = 10*log10(PDI_frame ./ max(PDI_frame(:)));

figure;
subplot(1, 2, 1)
imagesc(ReconSpec.xAxis, ReconSpec.zAxis, BmodeLog)
colormap(gca, gray);
clim([-40 0])
colorbar;
axis equal tight
xlabel('Width [mm]')
ylabel('Depth [mm]')
title('B-mode [dB]')

subplot(1, 2, 2)
imagesc(ReconSpec.xAxis, ReconSpec.zAxis, PDI_norm_db)
colormap(gca, hot);
colorbar;
axis equal tight
xlabel('Width [mm]')
ylabel('Depth [mm]')
title('PDI (normalised)')
echoframe_mex('destroy')
%% Clean up
clear mex;


%% Local functions

function names = spec_diff(label, userSpec, savedSpec, fields)
%SPEC_DIFF  Names of FIELDS whose value in USERSPEC differs from SAVEDSPEC.
% Used to report which hand-edited acquisition parameters a saved RF set overrules.
names = {};
for k = 1:numel(fields)
    f = fields{k};
    if ~isfield(userSpec, f) || ~isfield(savedSpec, f), continue; end
    a = userSpec.(f);
    b = savedSpec.(f);
    if isnumeric(a) && isnumeric(b)
        same = isequal(size(a), size(b)) && ...
               all(abs(double(a(:)) - double(b(:))) <= 1e-9 * max(1, abs(double(b(:)))));
    else
        same = isequal(a, b);
    end
    if ~same
        names{end+1} = [label '.' f];  %#ok<AGROW>
    end
end
end
