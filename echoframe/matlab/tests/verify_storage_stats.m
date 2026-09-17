% verify_storage_stats - Verify the storage slot rings, and the verifier itself.
%
% Storage does not copy: storeBuffer hands its pointer to an async write and the
% disk reads that memory until the write completes. This drives every producer-
% owned stream past that window on purpose, using EF_STORAGE_DELAY_WRITE_MS to
% hold writes back, and checks that EF_STORAGE_VERIFY reports what it should:
%
%   1. defaults,      held write   PDI and tags stay clean; BF is caught
%   2. all rings OFF, held write   BF, PDI and tags must ALL be caught
%   3. all rings ON,  held write   nothing may be caught
%
% Case 1 expects BF to corrupt because the BF ring is off by default -- its slot
% is a whole beamformed frame, so it is opt-in. That is the shipped exposure, and
% asserting it here means a change to the default cannot pass unnoticed. Turn the
% ring on with EF_STORAGE_SLOT_RINGS_BF=1.
%
% Case 2 is the negative control. Without it a clean case 3 proves nothing.
%
% Also prints the bf_storage stage timing next to the measured write-completion
% latency, in the same loop, since the two are routinely confused: the stage
% timer stops when a write is queued.
%
% The summary carries `peak=<peakInFlight>/<queueCapacity> ring=<slotRingDepth>`
% per stream, and marks WRAP-RISK when peak >= ring.
%
% RF is never expected to corrupt here. Nothing in a headless run refills the
% MATLAB array the way the Verasonics DMA refills a receive frame, so the RF
% path can only be exercised during a real acquisition.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built (set MEX_DIR to pin a
% specific build). GPU required. On Windows must run ELEVATED -- storage init
% acquires SeManageVolumePrivilege unconditionally.
%
% Env knobs:
%   EF_STATS_FRAMES   frames per case (default 8; must exceed the ring to wrap)
%   EF_STATS_DELAY_MS held-write duration for cases 2 and 3 (default 300)
%
% Usage: run

clear; close all; clear mex;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));

ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);
if ~isempty(getenv('MEX_DIR'))
    addpath(getenv('MEX_DIR'));   % pin the MEX under test; added last so it wins
end

nFrames = envnum('EF_STATS_FRAMES', 8);
delayMs = envnum('EF_STATS_DELAY_MS', 300);
assert(nFrames >= 2, 'EF_STATS_FRAMES must be >= 2.');

% These knobs persist for the MATLAB session. A stale delay would quietly wreck
% a later recording, so put every one back on the way out, error or not.
saved = struct('verify', getenv('EF_STORAGE_VERIFY'), ...
               'delay',  getenv('EF_STORAGE_DELAY_WRITE_MS'), ...
               'bf',     getenv('EF_STORAGE_SLOT_RINGS_BF'), ...
               'pdi',    getenv('EF_STORAGE_SLOT_RINGS_PDI'), ...
               'tag',    getenv('EF_STORAGE_SLOT_RINGS_TIMETAG'), ...
               'rfbuf',  getenv('EF_RF_STORAGE_BUFFERS'));
restore = onCleanup(@() restore_knobs(saved)); %#ok<NASGU>

out_root = fullfile(echoframe_data_root(), 'echoframe_verify_storage_stats');
if isfolder(out_root); rmdir(out_root, 's'); end
mkdir(out_root);

%% Base specs (deterministic) -- mirrors verify_storage_race
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
ReceiveSpec.nBuffers       = 4;     % the depth the RF write queue is capped to

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
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

% A different frame per call, or a torn write compares equal to a clean one.
RFs = cell(1, nFrames);
for k = 1:nFrames
    RFs{k} = circshift(RF, 7 * (k - 1), 1);
end

fprintf('%d frames per case, %d ms held writes\n', nFrames, delayMs);

%% Cases. expect lists the streams allowed to report corruption.
delayStr = num2str(delayMs);
cases = struct( ...
    'name',    {'defaults + held write', 'all rings OFF + held write', 'all rings ON + held write'}, ...
    'ringBF',  {'',                      '0',                          '1'}, ...
    'ringOth', {'',                      '0',                          '1'}, ...
    'delay',   {delayStr,                delayStr,                     delayStr}, ...
    'expect',  {{'bf'},                 {'bf','pdi','timetag'},       {}});

results = cell(1, numel(cases));
try
    for c = 1:numel(cases)
        fprintf('\n======== case %d: %s ========\n', c, cases(c).name);
        setenv('EF_STORAGE_VERIFY', '1');
        setenv('EF_STORAGE_DELAY_WRITE_MS',     cases(c).delay);
        setenv('EF_STORAGE_SLOT_RINGS_BF',      cases(c).ringBF);
        setenv('EF_STORAGE_SLOT_RINGS_PDI',     cases(c).ringOth);
        setenv('EF_STORAGE_SLOT_RINGS_TIMETAG', cases(c).ringOth);
        setenv('EF_RF_STORAGE_BUFFERS', '');

        results{c} = run_case(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, ...
                              PDISpec, RFs, fullfile(out_root, sprintf('case%d', c)));
    end
catch err
    restore_knobs(saved);
    rethrow(err);
end
restore_knobs(saved);

%% Verdict
fprintf('\n======== summary ========\n');
streams = {'rf', 'bf', 'pdi', 'timetag'};
pass = true;
for c = 1:numel(cases)
    s = results{c}.stats;
    for k = 1:numel(streams)
        name    = streams{k};
        got     = s.(name).corrupted > 0;
        allowed = any(strcmp(name, cases(c).expect));
        ok      = (got == allowed);
        pass    = pass && ok;
        ringWrapRisk = s.(name).peakInFlight >= s.(name).slotRingDepth;
        fprintf('  %-28s %-8s corrupt=%-3d peak=%d/%-3d ring=%-3d %-9s expected %-4s %s\n', ...
                cases(c).name, name, s.(name).corrupted, ...
                s.(name).peakInFlight, s.(name).queueCapacity, ...
                s.(name).slotRingDepth, ...
                ternary(ringWrapRisk, 'WRAP-RISK', 'safe'), ...
                ternary(allowed, 'SOME', 'NONE'), ...
                ternary(ok, 'OK', '<-- MISMATCH'));
    end
end

% The negative control has to have fired, or case 3 passing means nothing.
caught = results{2}.stats.bf.corrupted + results{2}.stats.pdi.corrupted + ...
         results{2}.stats.timetag.corrupted;
pass = check('negative control caught unprotected writes', caught > 0) && pass;

fprintf('\n======== queueing vs write completion (same run) ========\n');
for c = 1:numel(cases)
    fprintf('  %-28s bf_storage stage %7.3f ms | bf write latency mean %7.2f ms\n', ...
            cases(c).name, results{c}.bfStageMs, results{c}.stats.bf.latencyMeanMs);
end

fprintf('\n==== %s ====\n', ternary(pass, 'ALL CHECKS PASSED', 'SOME CHECKS FAILED'));
if ~pass
    error('verify_storage_stats:failures', ...
          'A stream corrupted when it should not have, or the control did not fire.');
end

% Test output. Every run_case destroys before it returns, and a failed run
% errors out above and keeps its recordings.
echoframe_cleanup_dir(out_root);

%% ---------------------------------------------------------------- local functions ----
function out = run_case(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, ...
                        PDISpec, RFs, folder)
clear mex;
nFrames = numel(RFs);
if ~isfolder(folder); mkdir(folder); end

StorageSpec.folderStoragePath   = folder;
StorageSpec.saveRF              = logical(true);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI             = logical(true);
StorageSpec.saveRFTimeTag       = logical(true);
StorageSpec.preallocateFullFile = logical(true);
ExperimentSpec.numberOfPDIsExperiment = nFrames;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ...
                               ReconSpec, PDISpec); %#ok<ASGLU>

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

bfStage = zeros(nFrames, 1);
t0 = tic;
for k = 1:nFrames
    [~, ~, ~, t] = echoframe_mex('process', RFs{k}, true);
    bfStage(k) = t.bf_storage * 1000;   % seconds -> ms
end
loopMs = toc(t0) / nFrames * 1000;

out.stats     = echoframe_mex('storage_stats');
out.bfStageMs = mean(bfStage);
check_storage_headroom(loopMs, ReceiveSpec);

echoframe_mex('destroy');   % drains async writes, closes files, unlocks
clear mex;
end

function restore_knobs(saved)
setenv('EF_STORAGE_VERIFY',             saved.verify);
setenv('EF_STORAGE_DELAY_WRITE_MS',     saved.delay);
setenv('EF_STORAGE_SLOT_RINGS_BF',      saved.bf);
setenv('EF_STORAGE_SLOT_RINGS_PDI',     saved.pdi);
setenv('EF_STORAGE_SLOT_RINGS_TIMETAG', saved.tag);
setenv('EF_RF_STORAGE_BUFFERS',         saved.rfbuf);
end

function ok = check(label, cond)
ok = logical(cond);
fprintf('  [%s] %s\n', ternary(ok, 'PASS', 'FAIL'), label);
end

function v = envnum(name, fallback)
v = fallback;
raw = getenv(name);
if ~isempty(raw)
    parsed = str2double(raw);
    if ~isnan(parsed); v = parsed; end
end
end

function out = ternary(cond, a, b)
if cond; out = a; else; out = b; end
end
