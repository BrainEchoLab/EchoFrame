% run_all_matlab - Run every runnable EchoFrame MATLAB script, one after the other.
%
% One driver for the whole MATLAB side: the headless unit tests, the GPU
% verification harnesses, the examples, the Verasonics setup path, and
% (optionally) the benchmarks. Each
% script runs in its own function workspace, so the `clear` most of them start
% with cannot wipe this driver's state. Every run is timed, failures are caught
% and recorded rather than aborting the sweep, and a PASS/FAIL/SKIP table is
% printed at the end. Everything printed also goes to a diary log.
%
% RUN THIS FROM AN ELEVATED MATLAB if RUN_STORAGE is true. Every script that
% writes a recording goes through the storage Handler, and Handler::init calls
% assignPriviledges() before it opens any file (Handler.t.hpp:37); without
% SE_MANAGE_VOLUME_NAME it calls std::terminate(), which takes MATLAB down with
% it - that failure cannot be caught here. The driver checks for elevation up
% front and skips the whole storage group rather than risk it.
%
% verify_verasonics_setup can stop and wait for a Verasonics prompt that has to
% be accepted by hand. The process sits at near-zero CPU with no further output,
% which reads exactly like a hang -- it is not, and killing it loses the run. Two
% passes on this machine took 74 s and 868 s, the difference being how long the
% prompt went unanswered. The dialog is native to Vantage, not a MATLAB one, so
% it cannot be shadowed or answered from here: watch for it when the sweep
% reaches this task. Nothing else in the sweep behaves this way.
%
% Two Verasonics scripts are deliberately NOT in the sweep, because neither
% finishes on its own:
%
%   echoframe_acquisition_start.m  ends in VSX, which blocks in the Verasonics
%                                  GUI until an operator closes it - and it
%                                  transmits and writes a recording first.
%   ef_external_process.m          is the per-frame VSX callback, a function
%                                  taking RF, not a runnable script.
%
% Everything else under examples/verasonics IS covered: verify_verasonics_setup
% runs L74_demo, GE9LD_demo, vsx_to_ef_structs and setup_echoframe_figure and
% stops before VSX, and process_verasonics_workspace replays a saved workspace.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex + storage built (for anything
%         past the headless group); a CUDA GPU. The verasonics group also needs
%         VERASONICS_VPF_ROOT and a Vantage install.
% Usage:  set the options block below, then type run_all_matlab. No arguments.
%
% This is a FUNCTION, not a script, on purpose: the Verasonics path clears the
% base workspace (activate and the probe setup scripts both do), which would
% otherwise wipe this driver's loop state mid-sweep.
%
% See also verify_core_headless, verify_batch_loading_headless, verify_crop_storage.

function run_all_matlab()

close all; clear mex;

%% ---------------------------------------------------------------- options
RUN_HEADLESS   = true;    % MEX-free, GPU-free unit tests. Always safe.
RUN_GPU        = true;    % needs echoframe_mex + a CUDA GPU. No disk writes.
RUN_STORAGE    = true;    % needs the above AND an elevated MATLAB.
RUN_VERASONICS = true;    % needs a Vantage install (VERASONICS_VPF_ROOT). No transmission.
RUN_BENCHMARKS = true;   % slow (minutes each); benchmark_storage also needs elevation.
RUN_HEAVY      = false;   % verify_batch_large: writes ~64 GB to the temp folder.

STOP_ON_ERROR  = false;   % true -> abort the sweep on the first failure
CLOSE_FIGURES  = true;    % close each script's figures before the next one
LOG_DIR        = fullfile(tempdir, 'echoframe_run_all');

% process_verasonics_workspace replays a .mat saved from a Verasonics example;
% nothing here can synthesise one, so point these at a workspace you captured
% (see the header of that script for how). Left empty, the task is skipped.
VERASONICS_WORKSPACE_DIR = '';
VERASONICS_WORKSPACE_MAT = 'echoframe_demo_data.mat';

%% ------------------------------------------------------------ environment
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
if isempty(ECHOFRAME_PATH)
    error('run_all_matlab:noPath', ...
          'ECHOFRAME_PATH is not set. setenv it to the EchoFrame checkout first.');
end
addpath(genpath(ECHOFRAME_PATH));

% The MEX + storage gateways under test. addpath prepends, so this takes
% priority over any other copy on the path (binaries/, ...).
ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);

MATLAB_ROOT = fullfile(ECHOFRAME_PATH, 'echoframe', 'matlab');

hasMex = (exist('echoframe_mex', 'file') == 3);
if ispc
    [netStatus, ~] = system('net session');
    isElevated = (netStatus == 0);
else
    isElevated = true;    % assignPrivileges is a no-op outside Windows
end

vantagePath   = getenv('VERASONICS_VPF_ROOT');
hasVerasonics = ~isempty(vantagePath) && isfolder(vantagePath);

if ~isfolder(LOG_DIR), mkdir(LOG_DIR); end
stamp   = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
logFile = fullfile(LOG_DIR, ['run_all_' stamp '.log']);
diary(logFile);

fprintf('\n================ EchoFrame MATLAB sweep ================\n');
fprintf('  checkout              : %s\n', ECHOFRAME_PATH);
fprintf('  echoframe_mex on path : %d\n', hasMex);
fprintf('  elevated MATLAB       : %d\n', isElevated);
fprintf('  Vantage install       : %d\n', hasVerasonics);
fprintf('  log                   : %s\n', logFile);
fprintf('========================================================\n\n');

if RUN_GPU && ~hasMex
    warning('run_all_matlab:noMex', ...
            'echoframe_mex is not on the path - the GPU and storage groups will be skipped.');
end
if RUN_STORAGE && ~isElevated
    warning('run_all_matlab:notElevated', ...
            ['MATLAB is not elevated - the storage group will be skipped. Restart ', ...
             'MATLAB as administrator to run it.']);
end
if RUN_VERASONICS && ~hasVerasonics
    warning('run_all_matlab:noVantage', ...
            ['VERASONICS_VPF_ROOT is not set to a folder - the probe-setup check ', ...
             'will be skipped.']);
end
if RUN_VERASONICS && hasVerasonics
    warning('run_all_matlab:vantagePrompt', ...
            ['verify_verasonics_setup may stop at a Verasonics prompt that has ', ...
             'to be accepted by hand. It looks hung - no output, no CPU - and ', ...
             'stays that way until the dialog is answered. Watch for it.']);
end

%% ------------------------------------------------------------- task table
% needs: 'none' = plain MATLAB | 'mex' = echoframe_mex + GPU | 'storage' = + elevation
%        'verasonics' = a Vantage install
tasks = {};
tasks = add_task(tasks, 'verify_core_headless', ...
                 'tests/verify_core_headless.m', 'headless', 'none');
tasks = add_task(tasks, 'verify_batch_loading_headless', ...
                 'tests/verify_batch_loading_headless.m', 'headless', 'none');

% First in the group on purpose: it feeds a `string` to fields that require
% `char`, and the regression it guards is a segfault rather than an error, which
% would take the whole sweep down. Run it where the crash is attributable.
tasks = add_task(tasks, 'verify_mex_string_args', ...
                 'tests/verify_mex_string_args.m', 'gpu', 'mex');
tasks = add_task(tasks, 'logo_simulation', ...
                 'examples/logo_simulation/logo_simulation.m', 'gpu', 'mex');
tasks = add_task(tasks, 'crop_demo', ...
                 'examples/logo_simulation/crop_demo.m', 'gpu', 'mex');
tasks = add_task(tasks, 'fourier_beamforming_matlab', ...
                 'tests/reference/fourier_beamforming_matlab.m', 'gpu', 'mex');

tasks = add_task(tasks, 'verify_crop_storage', ...
                 'tests/verify_crop_storage.m', 'storage', 'storage');
tasks = add_task(tasks, 'crop_demo_storage', ...
                 'examples/logo_simulation/crop_demo_storage.m', 'storage', 'storage');
tasks = add_task(tasks, 'verify_batch_lossless', ...
                 'tests/verify_batch_lossless.m', 'storage', 'storage');
tasks = add_task(tasks, 'verify_batch_lossless_rf', ...
                 'tests/verify_batch_lossless_rf.m', 'storage', 'storage');
tasks = add_task(tasks, 'verify_batch_storage', ...
                 'tests/verify_batch_storage.m', 'storage', 'storage');
tasks = add_task(tasks, 'verify_padding_removal', ...
                 'tests/verify_padding_removal.m', 'storage', 'storage');
% Both of these drive the storage knobs through setenv, and both put them back
% on the way out, so nothing after them inherits a ring setting or a held write.
tasks = add_task(tasks, 'verify_storage_race', ...
                 'tests/verify_storage_race.m', 'storage', 'storage');
tasks = add_task(tasks, 'verify_storage_stats', ...
                 'tests/verify_storage_stats.m', 'storage', 'storage');
tasks = add_task(tasks, 'generate_echoframe_demo_data', ...
                 'tests/data/generate_echoframe_demo_data.m', 'storage', 'storage');
% The two replay examples need a recording to read. generate_* above writes one,
% and the loop patches their empty load_path to point at it.
tasks = add_task(tasks, 'process_echoframe_data', ...
                 'examples/process_echoframe_data/process_echoframe_data.m', 'storage', 'storage');
tasks = add_task(tasks, 'process_echoframe_bf_to_pdi_data', ...
                 'examples/process_echoframe_data/process_echoframe_bf_to_pdi_data.m', 'storage', 'storage');

% Verasonics. echoframe_acquisition_start.m is deliberately absent: it ends in
% VSX, which blocks in the Verasonics GUI until an operator closes it, and it
% transmits and writes a recording first. verify_verasonics_setup runs the same
% setup chain (L74_demo, GE9LD_demo, vsx_to_ef_structs, setup_echoframe_figure)
% and stops before VSX. ef_external_process.m is a per-frame callback, not a
% script - it only runs inside a live acquisition.
tasks = add_task(tasks, 'verify_verasonics_setup', ...
                 'tests/verify_verasonics_setup.m', 'verasonics', 'verasonics');
tasks = add_task(tasks, 'process_verasonics_workspace', ...
                 'examples/verasonics/process_verasonics_workspace/process_verasonics_workspace.m', ...
                 'verasonics', 'mex');

tasks = add_task(tasks, 'benchmark_echoframe', ...
                 'benchmarks/benchmark_echoframe.m', 'benchmarks', 'mex');
tasks = add_task(tasks, 'benchmark_storage', ...
                 'benchmarks/benchmark_storage.m', 'benchmarks', 'storage');

tasks = add_task(tasks, 'verify_batch_large', ...
                 'tests/verify_batch_large.m', 'heavy', 'storage');

groupOn = struct('headless', RUN_HEADLESS, 'gpu', RUN_GPU, 'storage', RUN_STORAGE, ...
                 'verasonics', RUN_VERASONICS, 'benchmarks', RUN_BENCHMARKS, ...
                 'heavy', RUN_HEAVY);

%% ------------------------------------------------------------------- run
results = repmat(struct('name', '', 'group', '', 'status', '', 'secs', 0, 'msg', ''), ...
                 1, numel(tasks));
demoDataDir = '';

for k = 1:numel(tasks)
    t = tasks{k};
    results(k).name  = t.name;
    results(k).group = t.group;

    % --- should it run at all?
    skipWhy = '';
    if ~groupOn.(t.group)
        skipWhy = sprintf('group ''%s'' disabled', t.group);
    elseif ~hasMex && ~strcmp(t.needs, 'none')
        skipWhy = 'echoframe_mex not on the path';
    elseif strcmp(t.needs, 'storage') && ~isElevated
        skipWhy = 'needs an elevated MATLAB';
    elseif strcmp(t.needs, 'verasonics') && ~hasVerasonics
        skipWhy = 'VERASONICS_VPF_ROOT not set to a folder';
    end

    scriptPath = fullfile(MATLAB_ROOT, t.file);
    if isempty(skipWhy) && ~isfile(scriptPath)
        skipWhy = 'script not found';
    end

    % --- the replay examples need their data folder patched in
    if isempty(skipWhy) && startsWith(t.name, 'process_echoframe')
        if isempty(demoDataDir)
            demoDataDir = newest_recording(fullfile(echoframe_data_root(), 'echoframe_demo_data'));
        end
        if isempty(demoDataDir)
            skipWhy = 'no recording (generate_echoframe_demo_data did not run)';
        else
            scriptPath = patch_script(scriptPath, LOG_DIR, ...
                {'load_path = '''';', sprintf('load_path = ''%s'';', demoDataDir)});
        end
    end

    if isempty(skipWhy) && strcmp(t.name, 'process_verasonics_workspace')
        if isempty(VERASONICS_WORKSPACE_DIR)
            skipWhy = 'set VERASONICS_WORKSPACE_DIR to a saved Verasonics workspace';
        elseif ~isfile(fullfile(VERASONICS_WORKSPACE_DIR, VERASONICS_WORKSPACE_MAT))
            skipWhy = sprintf('%s not found in VERASONICS_WORKSPACE_DIR', ...
                              VERASONICS_WORKSPACE_MAT);
        else
            scriptPath = patch_script(scriptPath, LOG_DIR, ...
                {'load_path = '''';', ...
                 sprintf('load_path = ''%s'';', VERASONICS_WORKSPACE_DIR)}, ...
                {'data_name   = ''echoframe_demo_data.mat'';', ...
                 sprintf('data_name   = ''%s'';', VERASONICS_WORKSPACE_MAT)});
        end
    end

    if ~isempty(skipWhy)
        results(k).status = 'SKIP';
        results(k).msg    = skipWhy;
        fprintf('\n---- SKIP  %-32s (%s)\n', t.name, skipWhy);
        continue
    end

    fprintf('\n================================================================\n');
    fprintf('  RUN   %s\n', t.name);
    fprintf('  file  %s\n', t.file);
    fprintf('================================================================\n');

    % The Verasonics setup chain only works in the base workspace - see the
    % header of verify_verasonics_setup.m. It also cds into the Vantage tree,
    % so the working directory is restored afterwards.
    startDir = pwd;
    tStart   = tic;
    [ok, msg] = run_one(scriptPath, strcmp(t.needs, 'verasonics'));
    results(k).secs = toc(tStart);
    if ~strcmp(pwd, startDir), cd(startDir); end

    if ok
        results(k).status = 'PASS';
        fprintf('\n---- PASS  %-32s %.1f s\n', t.name, results(k).secs);
    else
        results(k).status = 'FAIL';
        results(k).msg    = msg;
        fprintf(2, '\n---- FAIL  %-32s %.1f s\n       %s\n', t.name, results(k).secs, msg);
        if STOP_ON_ERROR
            fprintf(2, '\nSTOP_ON_ERROR is true - aborting the sweep.\n');
            results = results(1:k);
            break
        end
    end

    if CLOSE_FIGURES, close all; end
    clear mex

    if strcmp(t.name, 'generate_echoframe_demo_data')
        demoDataDir = newest_recording(fullfile(echoframe_data_root(), 'echoframe_demo_data'));
    end
end

%% --------------------------------------------------------------- summary
fprintf('\n\n======================= SUMMARY =======================\n');
fprintf('%-6s %-11s %-34s %8s\n', 'STATUS', 'GROUP', 'SCRIPT', 'TIME [s]');
fprintf('%s\n', repmat('-', 1, 63));
for k = 1:numel(results)
    r = results(k);
    if strcmp(r.status, 'SKIP')
        fprintf('%-6s %-11s %-34s %8s   (%s)\n', r.status, r.group, r.name, '-', r.msg);
    else
        fprintf('%-6s %-11s %-34s %8.1f\n', r.status, r.group, r.name, r.secs);
    end
end
fprintf('%s\n', repmat('-', 1, 63));

nPass = sum(strcmp({results.status}, 'PASS'));
nFail = sum(strcmp({results.status}, 'FAIL'));
nSkip = sum(strcmp({results.status}, 'SKIP'));
fprintf('%d passed, %d failed, %d skipped, %.1f s total\n', ...
        nPass, nFail, nSkip, sum([results.secs]));

if nFail > 0
    fprintf(2, '\nFailures:\n');
    for k = 1:numel(results)
        if strcmp(results(k).status, 'FAIL')
            fprintf(2, '  %s: %s\n', results(k).name, results(k).msg);
        end
    end
end
fprintf('\nLog: %s\n', logFile);
fprintf('======================================================\n');

diary off

end

%% ------------------------------------------------------------ local funcs
function tasks = add_task(tasks, name, file, group, needs)
tasks{end+1} = struct('name', name, 'file', file, ...
                      'group', group, 'needs', needs);
end

function [ok, msg] = run_one(scriptPath, inBase)
% Run one script and report whether it finished. It normally runs in this
% function's workspace, so a script's own `clear` only clears these locals.
%
% inBase runs it in the base workspace instead, which the Verasonics helpers
% need: they use evalin('base', ...) and globals, so that chain only works when
% the script itself runs in base.
try
    if inBase
        evalin('base', sprintf('run(''%s'')', scriptPath));
    else
        run(scriptPath);
    end
    ok  = true;
    msg = '';
catch ME
    ok  = false;
    msg = ME.message;
end
end

function d = newest_recording(parentDir)
% Newest recording_<timestamp> folder under parentDir, or '' if there is none.
d = '';
if ~isfolder(parentDir), return; end
listing = dir(fullfile(parentDir, 'recording_*'));
listing = listing([listing.isdir]);
if isempty(listing), return; end
[~, ix] = max([listing.datenum]);
d = fullfile(listing(ix).folder, listing(ix).name);
end

function outFile = patch_script(srcFile, outDir, varargin)
% The replay examples ship with an empty data path and `clear` on their first
% line, so the folder cannot be injected from here. Write a copy with the real
% values substituted and run that instead; the original is left untouched.
% Each trailing argument is a {needle, replacement} pair.
txt = fileread(srcFile);
for p = 1:numel(varargin)
    pair = varargin{p};
    if ~contains(txt, pair{1})
        error('run_all_matlab:patchFailed', ...
              'Could not find "%s" in %s', pair{1}, srcFile);
    end
    txt = strrep(txt, pair{1}, pair{2});
end
[~, base] = fileparts(srcFile);
outFile = fullfile(outDir, [base '_runall.m']);
fid = fopen(outFile, 'w');
if fid < 0
    error('run_all_matlab:patchFailed', 'Could not write %s', outFile);
end
fwrite(fid, txt);
fclose(fid);
end
