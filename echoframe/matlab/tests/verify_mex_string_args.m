% verify_mex_string_args - A `string` where a `char` is required must ERROR, not crash.
%
% MATLAB's double quotes produce a `string`, not a `char`. mxArrayToString returns
% NULL for one, so a `string` that reaches the MEX text validators must be rejected
% by mxIsChar rather than turned into a NULL std::string.
%
% Three MEX-facing text fields carry that check:
%
%   PDISpec.svdMethod          (validatePDIStruct)
%   <storage>.filepath         (validateStorageStruct)
%   <storage>.dataType         (validateStorageStruct)
%
% Covers every field in every struct that carries it: filepath and dataType on all
% four storage structs, so 1 + 4 + 4 = 9 poisoned cases, plus a char control first
% so a failure is attributable to the injected `string`. Reaching the verdict is
% itself part of the assertion -- an unrejected `string` takes the process down.
%
% No elevation needed -- every storage save flag is false, so no Handler is built.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built (set MEX_DIR to pin a build).
%         GPU required -- the control case really initialises EchoFrame.
%
% Usage: run

clear; close all; clear mex;

ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);
if ~isempty(getenv('MEX_DIR'))
    addpath(getenv('MEX_DIR'));
end
fprintf('echoframe_mex: %s\n', which('echoframe_mex'));

%% Base specs -- storage structs are built but every save flag is false
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
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = int32([0;1;0;1]);

PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec); %#ok<ASGLU>
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

% A named folder rather than tempdir itself: init_storage creates recording_<date>
% whether or not a stream saves, and a stray one in the root of tempdir is
% indistinguishable from a real recording.
out_root = fullfile(tempdir, 'echoframe_verify_string_args');
if isfolder(out_root); rmdir(out_root, 's'); end
mkdir(out_root);

StorageSpec.folderStoragePath   = out_root;
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(false);
StorageSpec.savePDI             = logical(false);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(false);
ExperimentSpec.numberOfPDIsExperiment = 1;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec); %#ok<ASGLU>

base = struct('Receive', ReceiveSpec, 'Recon', ReconSpec, 'PDI', PDISpec, ...
              'BF', BFStorageSpec, 'PDIStore', PDIStorageSpec, ...
              'Tag', RFTimeTagStorageSpec, 'RFStore', RFStorageSpec);

pass = true;

%% Control: the unmodified call must succeed, so later failures mean the string, not a bad call
try
    do_init(base);
    echoframe_mex('destroy');
    pass = check('control: all-char specs initialise cleanly', true) && pass;
catch ME
    pass = check(sprintf('control: all-char specs initialise cleanly (got %s: %s)', ...
                         ME.identifier, ME.message), false) && pass;
end
clear mex;

%% Every affected field, in every struct that carries it
cases = {
    'PDI',      'svdMethod', 'PDISpec.svdMethod'
    'BF',       'filepath',  'BFStorageSpec.filepath'
    'BF',       'dataType',  'BFStorageSpec.dataType'
    'PDIStore', 'filepath',  'PDIStorageSpec.filepath'
    'PDIStore', 'dataType',  'PDIStorageSpec.dataType'
    'Tag',      'filepath',  'RFTimeTagStorageSpec.filepath'
    'Tag',      'dataType',  'RFTimeTagStorageSpec.dataType'
    'RFStore',  'filepath',  'RFStorageSpec.filepath'
    'RFStore',  'dataType',  'RFStorageSpec.dataType'
};

for i = 1:size(cases, 1)
    structName = cases{i, 1};
    fieldName  = cases{i, 2};
    label      = cases{i, 3};

    poisoned = base;
    % string(...) is exactly what a double-quoted literal produces.
    poisoned.(structName).(fieldName) = string(base.(structName).(fieldName));

    errored = false;
    msg = '';
    try
        do_init(poisoned);
    catch ME
        errored = true;
        msg = ME.message;
    end
    if ~errored
        try; echoframe_mex('destroy'); catch; end %#ok<NOSEMI>
    end
    clear mex;

    % Not just "something threw": the error must name the offending field, or
    % an unrelated validation firing first would still look green.
    named = errored && contains(msg, fieldName) && contains(msg, 'char');
    pass = check(sprintf('%-32s rejected, error names the field (%s)', ...
                         label, error_detail(msg)), named) && pass;
end

fprintf('\n==== %s ====\n', ternary(pass, 'ALL CHECKS PASSED', 'SOME CHECKS FAILED'));
if ~pass
    error('verify_mex_string_args:failures', ...
          'A string-typed field was accepted where char is required (see above).');
end

% Test output. The last do_init either destroyed or never opened anything.
echoframe_cleanup_dir(out_root);

%% ---------------------------------------------------------------- local functions ----
function do_init(s)
echoframe_mex('init', s.Receive, s.Recon, s.PDI, s.BF, s.PDIStore, s.Tag, s.RFStore);
end

function t = error_detail(msg)
% A C++ exception reaches MATLAB as MATLAB:unexpectedCPPexception, where the
% first line is boilerplate and the useful part is the What() line.
if isempty(msg)
    t = 'no error raised';
    return;
end
parts = strsplit(strtrim(msg), newline);
t = strtrim(parts{1});
for i = 1:numel(parts)
    if contains(parts{i}, 'What() is:')
        t = strtrim(extractAfter(parts{i}, 'What() is:'));
        break;
    end
end
t = strtrim(erase(t, '..'));
if numel(t) > 64
    t = [t(1:61) '...'];
end
end

function ok = check(name, cond)
ok = logical(cond);
fprintf('  [%s] %s\n', ternary(ok, 'PASS', 'FAIL'), name);
end

function s = ternary(cond, a, b)
if cond; s = a; else; s = b; end
end
