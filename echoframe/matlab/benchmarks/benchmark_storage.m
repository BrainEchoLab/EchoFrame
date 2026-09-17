% benchmark_storage - Disk-write throughput benchmark for EchoFrame storage.
%
% Times per-buffer storage using echoframe_mex 'storage_stats', which reports
% write-completion latency per stream. The per-stage bfStorage timing measures
% only how long queueing took, so it is not used for throughput here.
%
% Reports per-stage time, MB/s throughput, and a real-time fit ratio
% against TARGET_TX_RATE.
%
% Three different times come out of this, and they answer different questions:
%   time_ms             wall clock around process() with storage on. What the
%                       caller pays per buffer, and the only one to quote for a
%                       real-time claim.
%   bf_store_ms_series  the BFStorage CUDA event. BF queueing alone -- the RF
%                       write is queued in the MEX outside the core's timers,
%                       and PDI is not saved here at all.
%   time_*_store_ms     write-completion latency from 'storage_stats'. Writes
%                       overlap, so this is how long a source buffer must stay
%                       untouched, not time the caller spends.
%
% Reuses the same RF generation pattern as generate_echoframe_demo_data:
% simulate one base buffer with simulate_logo_rf, then add fresh int16
% noise per iteration so successive buffers differ.
%
% Three modes (edit MODE below):
%   'compare'    (default) per-buffer acquisition step the OLD way (beamform +
%                separate `storage` MEX) vs the NEW way (beamform + RF stored
%                inside echoframe_mex). Averaged over several independent trials,
%                paired/interleaved and median-based so it is stable run to run;
%                reports pooled median +/- IQR, the paired difference, the
%                win-rate, and each trial's median (to show run-to-run spread).
%   'endurance'  how long can this drive carry this configuration, with RF on?
%                Writes ENDURANCE_GB with every stream the acquisition writes,
%                reporting the rate PER INTERVAL, and says how many frames go by
%                before the drive falls behind. This is the mode to run before
%                planning a recording. The others settle a per-buffer number in
%                a handful of buffers and cap what they write, which measures
%                the drive's write cache and flatters it. Takes minutes.
%   'fast'       single config (RF + BF storage at the default setup).
%                One bar chart with RF / BF / total storage time + budget.
%   'elaborate'  three 1-D sweeps:
%                  (a) which streams to save: RF only / BF only / both
%                  (b) nRepeats in {20, 40, 80, 160} (buffer size)
%                  (c) preallocateFullFile on / off
%                Plots latency and throughput per axis.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built;
%         enough free disk space at output_dir.
% Usage:  edit the parameters block; run.

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
MODE            = 'compare';         % 'compare' | 'endurance' | 'fast' | 'elaborate'
TARGET_TX_RATE  = 10e3;                                         % Hz

fprintf('benchmark_storage: mode ''%s''\n', MODE);

% The volumes under test. This benchmark measures whatever it writes to, so this
% list decides what the numbers describe, not just where the bytes go. Every
% configuration is run against each, which is what makes them comparable, and
% volumes that resolve to the same drive are collapsed.
%
% Just the data drive for now. Adding the system drive back is one entry:
%
%   BENCH_DISKS = unique_volumes({echoframe_data_root(), tempdir});
%
% It is off because a system drive rarely has room for a probe configuration's
% buffer: those rows get skipped, and the smaller ones fill the drive.
BENCH_DISKS = unique_volumes({echoframe_data_root()});

% Ceiling on the bytes one configuration writes while being measured. Sizing by
% buffer count alone gave the GE9LD 73 GB per row: minutes of writing for a
% number that settles in a handful of buffers.
%
% This cap is right for the sweep modes and WRONG for any question about how
% long a recording can run. An SSD holds its burst rate for as long as its cache
% lasts, which is tens to hundreds of GB on a large drive, so 16 GB measures the
% cache and reports a rate the drive cannot hold. 'endurance' mode ignores this
% and writes until the rate settles; see ENDURANCE_GB.
MAX_ROW_BYTES = 16e9;

% 'endurance' target. Big enough to leave any plausible SSD write cache behind,
% which is the whole point: the answer this mode gives is a recording length,
% and a short run answers it optimistically. Clamped to half the free space.
ENDURANCE_GB = 400;

output_dir = fullfile(BENCH_DISKS{1}, 'echoframe_benchmark_storage');
if ~exist(output_dir, 'dir'), mkdir(output_dir); end
fprintf('Storage benchmark measuring %d volume(s):\n', numel(BENCH_DISKS));
for d = 1:numel(BENCH_DISKS)
    fprintf('  %s (%.0f GB free)\n', BENCH_DISKS{d}, ...
            query_free_bytes(BENCH_DISKS{d}) / 1e9);
end

%% 'compare' mode: RF storage OLD (separate storage MEX) vs NEW (inside echoframe_mex)
if strcmp(MODE, 'compare')
    run_rf_method_comparison(output_dir, TARGET_TX_RATE);
    return;
end

%% 'endurance' mode: how long can this drive carry this configuration?
% MODE is a literal above, so only one branch is live per edit of the file.
if strcmp(MODE, 'endurance') %#ok<UNRCH>
    run_endurance_test(output_dir, TARGET_TX_RATE, ENDURANCE_GB);
    return;
end

switch MODE
    case 'fast'
        N_WARMUP  = 2;
        % 10 buffers left the per-buffer queueing time with a 6x spread, which
        % is not a number worth quoting. 50 costs seconds and settles it.
        N_MEASURE = 50;
        sweeps    = { struct('label', 'baseline', 'axis', 'baseline') };
    case 'elaborate'
        N_WARMUP  = 2;
        N_MEASURE = 5;
        sweeps    = build_storage_sweeps();
    otherwise
        error('MODE must be ''compare'', ''endurance'', ''fast'' or ''elaborate''.');
end

% Every configuration against every volume. Done here rather than inside the
% loop so the results table has one row per pair and the two drives can be read
% off against each other.
if numel(BENCH_DISKS) > 1
    expanded = {};
    for s = 1:numel(sweeps)
        for d = 1:numel(BENCH_DISKS)
            one       = sweeps{s};
            one.disk  = BENCH_DISKS{d};
            one.label = sprintf('%s @%s', one.label, volume_tag(BENCH_DISKS{d}));
            expanded{end+1} = one; %#ok<SAGROW>
        end
    end
    sweeps = expanded;
end

%% Pre-allocate results
results(numel(sweeps)) = empty_result();

%% Run sweep
for i = 1:numel(sweeps)
    meta = sweeps{i};
    fprintf('[%d/%d] %s\n', i, numel(sweeps), meta.label);

    % Reset MEX state between configs
    if i > 1, clear mex; end

    % Build specs from defaults, apply meta overrides
    [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, StorageSpec] = ...
        default_specs(N_MEASURE);
    % A config may carry a whole spec set (a real probe setup). Storage settings
    % stay with the benchmark: they are what is being measured, not the probe's.
    if isfield(meta, 'specs')
        ProbeSpec    = meta.specs.ProbeSpec;
        TransmitSpec = meta.specs.TransmitSpec;
        ReceiveSpec  = meta.specs.ReceiveSpec;
        ReconSpec    = meta.specs.ReconSpec;
        PDISpec      = meta.specs.PDISpec;
    end
    % Each probe setup transmits at its own rate, so one global rate cannot set
    % every budget.
    if isfield(meta, 'txRate'), tx_rate = meta.txRate; else, tx_rate = TARGET_TX_RATE; end
    if isfield(meta, 'nRepeats')
        ReceiveSpec.nRepeats = meta.nRepeats;
        PDISpec.ensembleSize = meta.nRepeats;
        PDISpec.shiftSize    = meta.nRepeats;
    end
    % So a caller pairing this run with a benchmark_echoframe one can make both
    % do the same work. Left alone otherwise: standalone runs keep PDI off,
    % since what they measure is the writing.
    if isfield(meta, 'getPDI'), ReconSpec.getPDI = logical(meta.getPDI); end
    if isfield(meta, 'saveRF'),       StorageSpec.saveRF              = logical(meta.saveRF);            end
    if isfield(meta, 'saveBF'),       StorageSpec.saveBF              = logical(meta.saveBF);            end
    if isfield(meta, 'preallocate'),  StorageSpec.preallocateFullFile = logical(meta.preallocate);       end

    % Each config writes on its own volume, which is the one being measured.
    if isfield(meta, 'disk'), cfg_root = meta.disk; else, cfg_root = BENCH_DISKS{1}; end
    cfg_out = fullfile(cfg_root, 'echoframe_benchmark_storage');
    StorageSpec.folderStoragePath = fullfile(cfg_out, sprintf('config_%02d_%s', i, meta.axis));
    if ~exist(StorageSpec.folderStoragePath, 'dir'), mkdir(StorageSpec.folderStoragePath); end

    % Simulate one base buffer; we add fresh noise per iteration
    [RF_base, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
        simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
    ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

    % Initialise reconstruction + storage + MEX
    [ProbeSpec, ReceiveSpec, ReconSpec] = ...
        initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

    % Fit the run to the drive before preallocating it. A buffer is one RF frame
    % plus one BF frame, and a probe configuration's is far larger than the
    % default's -- 1.35 GB against 57 MB for the GE9LD -- so a measure count
    % that is comfortable for one fills the disk for the other, and
    % preallocateFullFile then fails with ERROR_DISK_FULL before a single frame
    % is written. Half the free space, so the drive is not left at zero.
    n_measure = N_MEASURE;
    bytes_buf = (StorageSpec.saveRF * double(ReceiveSpec.nSamples) * ...
                 double(ReceiveSpec.nChannels) * double(ReceiveSpec.nTransmissions) * ...
                 double(ReceiveSpec.nRepeats) * 2) + ...
                (StorageSpec.saveBF * double(ReconSpec.nz) * double(ReconSpec.nx) * ...
                 double(ReceiveSpec.nRepeats) * 8);
    free_bytes = query_free_bytes(cfg_out);
    room       = floor((free_bytes / 2) / max(bytes_buf, 1)) - N_WARMUP;
    if room < 1
        % Clamping to 1 here would still preallocate 1 + N_WARMUP buffers, which
        % is what it could not fit in the first place: the GE9LD's 1416 MB
        % buffer against 1 GB free died in SetEndOfFile (ERROR_DISK_FULL) and
        % took the whole sweep with it. Skip the row instead.
        warning('benchmark_storage:volumeTooFull', ...
                ['%s: skipped. One measured buffer plus %d warmups is %.1f GB, ' ...
                 'and only %.1f GB is free at %s.'], meta.label, N_WARMUP, ...
                (1 + N_WARMUP) * bytes_buf / 1e9, free_bytes / 1e9, cfg_out);
        result         = empty_result();
        result.label   = meta.label;
        result.axis    = meta.axis;
        result.disk    = cfg_root;
        if isfield(meta, 'config'), result.config = meta.config; end
        result.skipped = true;
        results(i)     = result;
        local_rmdir(StorageSpec.folderStoragePath);
        continue
    end
    % Cap the bytes a row writes, not just the count. 50 buffers is right for
    % the 57 MB default and absurd for the GE9LD's 1416 MB: 73 GB per row, which
    % is minutes of writing for a number that has already settled. Keeps the
    % probe configurations to a handful of buffers without touching the small
    % ones, where 50 is what makes the queueing time stable.
    byte_room = max(1, floor(MAX_ROW_BYTES / max(bytes_buf, 1)));
    if byte_room < n_measure
        fprintf(['  %s: %d buffers of %.0f MB is %.0f GB per row; measuring %d ' ...
                 'to stay under %.0f GB.\n'], meta.label, n_measure, ...
                bytes_buf / 1e6, n_measure * bytes_buf / 1e9, byte_room, ...
                MAX_ROW_BYTES / 1e9);
        n_measure = byte_room;
    end
    if room < n_measure
        n_measure = room;
        warning('benchmark_storage:measureCountClamped', ...
                ['%s: %d buffers of %.0f MB would need %.0f GB, and only %.0f GB ' ...
                 'is free at %s. Measuring %d instead.'], meta.label, ...
                N_MEASURE + N_WARMUP, bytes_buf / 1e6, ...
                (N_MEASURE + N_WARMUP) * bytes_buf / 1e9, free_bytes / 1e9, ...
                cfg_out, n_measure);
    end
    ExperimentSpec.numberOfPDIsExperiment = n_measure + N_WARMUP;

    [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
        init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                     ExperimentSpec, TransmitSpec, ProbeSpec);
    [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
        echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
    echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
                  BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

    % Warmup (not timed)
    rng(0);
    for k = 1:N_WARMUP
        RF = RF_base + int16(round(50 * randn(size(RF_base))));
        [~, ~] = echoframe_mex('process', RF, true);
    end

    % Measure. Two outputs and a separate 'timings' call, the way the live loop
    % calls it: a third output copies the whole complex BF volume into MATLAB,
    % which ef_external_process never asks for and which would otherwise sit
    % inside the wall clock.
    time_bf_store = zeros(n_measure, 1);
    time_call     = zeros(n_measure, 1);
    % Wall clock across the whole row, closed after the drain below. Dividing
    % one buffer's bytes by one buffer's completion latency answers a different
    % question: with three writes in flight, each 1416 MB write takes ~4.5 s to
    % complete while the drive is retiring three of them at once, so that ratio
    % reported 53 MB/s for a drive doing several hundred. Bytes over elapsed
    % time is concurrency-independent and is what "can it keep up" means.
    row_clock = tic;
    rng(1);
    for k = 1:n_measure
        RF = RF_base + int16(round(50 * randn(size(RF_base))));

        t0 = tic;
        [~, ~] = echoframe_mex('process', RF, true);
        time_call(k) = toc(t0);
        t = echoframe_mex('timings');
        time_bf_store(k) = t.bf_storage;    % CUDA-event-timed BF queueing only
    end

    % Write-completion times, which the per-stage timing above does not measure.
    wstats = echoframe_mex('storage_stats');

    % A stream whose writes all settled during the final drain has completions
    % but no latency: those are counted and deliberately left untimed, so it has
    % no throughput number and must not be read as if it had one.
    untimed = {};
    if StorageSpec.saveRF && wstats.rf.latencyMeanMs <= 0, untimed{end+1} = 'RF'; end %#ok<SAGROW>
    if StorageSpec.saveBF && wstats.bf.latencyMeanMs <= 0, untimed{end+1} = 'BF'; end %#ok<SAGROW>
    if ~isempty(untimed)
        warning('benchmark_storage:untimedStream', ...
                ['%s: %s reported no timed write completions, so this row''s ' ...
                 'throughput describes the other stream only. Measure more ' ...
                 'buffers, so writes finish before the drain.'], ...
                meta.label, strjoin(untimed, ' and '));
    end

    % Compute metrics
    bytes_rf      = double(ReceiveSpec.nSamples) * double(ReceiveSpec.nChannels) * ...
                    double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats) * 2;
    bytes_bf      = double(ReconSpec.nz) * double(ReconSpec.nx) * ...
                    double(ReceiveSpec.nRepeats) * 8;
    bytes_per_buf = (StorageSpec.saveRF * bytes_rf) + (StorageSpec.saveBF * bytes_bf);

    bf_per_pdi    = double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats);
    budget_ms     = bf_per_pdi / tx_rate * 1e3;

    result                    = empty_result();
    result.label              = meta.label;
    result.disk               = cfg_root;
    result.axis               = meta.axis;
    % Which configuration this row belongs to, when a caller grouped them.
    if isfield(meta, 'config'), result.config = meta.config; end
    result.saveRF             = StorageSpec.saveRF;
    result.saveBF             = StorageSpec.saveBF;
    result.preallocate        = StorageSpec.preallocateFullFile;
    result.nRepeats           = double(ReceiveSpec.nRepeats);
    result.nTX                = double(ReceiveSpec.nTransmissions);

    result.bytes_rf_MB        = bytes_rf / 1e6;
    result.bytes_bf_MB        = bytes_bf / 1e6;
    result.bytes_per_buf_MB   = bytes_per_buf / 1e6;

    % Mean write-completion time per stream, 0 when the stream is not saved.
    result.time_rf_store_ms   = wstats.rf.latencyMeanMs  * double(StorageSpec.saveRF);
    result.time_bf_store_ms   = wstats.bf.latencyMeanMs  * double(StorageSpec.saveBF);
    result.time_total_ms      = result.time_rf_store_ms + result.time_bf_store_ms;

    % Throughput must divide each stream's bytes by that stream's own write
    % time. The totals only combine streams that both contributed a time.
    if StorageSpec.saveRF && result.time_rf_store_ms > 0
        result.rf_MB_per_s    = result.bytes_rf_MB / (result.time_rf_store_ms / 1e3);
    end
    if StorageSpec.saveBF && result.time_bf_store_ms > 0
        result.bf_MB_per_s    = result.bytes_bf_MB / (result.time_bf_store_ms / 1e3);
    end
    timedBytesMB = StorageSpec.saveRF * (result.time_rf_store_ms > 0) * result.bytes_rf_MB + ...
                   StorageSpec.saveBF * (result.time_bf_store_ms > 0) * result.bytes_bf_MB;
    if result.time_total_ms > 0
        result.total_MB_per_s = timedBytesMB / (result.time_total_ms / 1e3);
    end

    result.budget_ms          = budget_ms;
    result.realtime_ratio     = budget_ms / max(result.time_total_ms, eps);
    result.realtime_pass      = result.realtime_ratio >= 1;
    result.target_tx_rate     = tx_rate;
    result.wstats             = wstats;
    result.bf_store_ms_series = time_bf_store * 1e3;
    % Wall clock around process() with storage on: processing plus whatever the
    % writing costs the caller, in one number from one run. This is the figure a
    % real-time claim rests on; the two above are where it goes.
    result.time_ms_series     = time_call * 1e3;
    result.time_ms            = mean(result.time_ms_series);
    result.untimedStreams     = untimed;

    fprintf('  RF=%s/BF=%s prealloc=%s | rf=%.2f ms bf=%.2f ms total=%.2f ms | %.0f MB/s | rt=%s\n', ...
            ternary(result.saveRF,'on','off'), ternary(result.saveBF,'on','off'), ...
            ternary(result.preallocate,'on','off'), ...
            result.time_rf_store_ms, result.time_bf_store_ms, result.time_total_ms, ...
            result.total_MB_per_s, ternary(result.realtime_pass,'YES','NO'));

    results(i) = result;

    % Sustained rate, closed after the flush so the drain is inside it: the
    % queue is still several writes deep when the loop exits, and stopping the
    % clock there would credit the row with bytes the drive had not taken yet.
    % Includes the processing between writes, so it is what the pipeline
    % sustained to disk, not a raw drive figure -- which is the number that
    % decides whether a configuration keeps up.
    results(i).bytes_written_MB   = n_measure * bytes_per_buf / 1e6;

    % Free this row's files before the next one sizes itself against the drive.
    % Holding them to the end of the sweep is what turned 3 GB free on C: into
    % 1 GB by the third row, and the clamp then had nothing to work with.
    %
    % 'destroy' first, and not `clear mex` alone: unloading does flush and close
    % eventually, but not before the next statement, so the remove raced the
    % flush and reported "No directories were removed" while the files were
    % still open. destroy is synchronous.
    try
        echoframe_mex('destroy');
    catch destroyErr
        warning('benchmark_storage:destroy', ...
                '%s: echoframe_mex(''destroy'') failed: %s', ...
                meta.label, destroyErr.message);
    end
    release_mex;
    results(i).row_elapsed_s      = toc(row_clock);
    results(i).sustained_MB_per_s = results(i).bytes_written_MB / ...
                                    max(results(i).row_elapsed_s, eps);
    fprintf('  sustained %.0f MB/s (%.1f GB over %.1f s, drain included)\n', ...
            results(i).sustained_MB_per_s, results(i).bytes_written_MB / 1e3, ...
            results(i).row_elapsed_s);
    local_rmdir(StorageSpec.folderStoragePath);
end

%% Report + plot
print_results(results);
plot_results(results, MODE, TARGET_TX_RATE);

fprintf('\nFiles written under: %s\n', output_dir);
fprintf('(safe to delete that folder when you''re done)\n');

%% =====================================================================
%% Local functions
%% =====================================================================

function [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, StorageSpec] = ...
    default_specs(N_MEASURE)
ProbeSpec.pitch          = 300e-6;
ProbeSpec.Fc             = 5e6;
ProbeSpec.nElements      = 128;

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

ReceiveSpec.nRepeats       = 40;
ReceiveSpec.Fs             = 20e6;
ReceiveSpec.nTransmissions = length(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';

ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(false);
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

% Default storage: write both RF and BF, preallocated
StorageSpec.saveRF              = logical(true);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI             = logical(false);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(true);
StorageSpec.folderStoragePath   = '';   % set per-config

% Preallocated file size tracks measured buffers + warmup margin
ExperimentSpec.numberOfPDIsExperiment = N_MEASURE + 8;
end

function sweeps = build_storage_sweeps()
sweeps = {};

% (a) which streams to save
sweeps{end+1} = struct('label','RF only',  'axis','streams','saveRF',true, 'saveBF',false); %#ok<AGROW>
sweeps{end+1} = struct('label','BF only',  'axis','streams','saveRF',false,'saveBF',true);  %#ok<AGROW>
sweeps{end+1} = struct('label','RF + BF',  'axis','streams','saveRF',true, 'saveBF',true);  %#ok<AGROW>

% (b) nRepeats sweep (RF + BF storage on)
for r = [20 40 80 160]
    sweeps{end+1} = struct('label',sprintf('nRepeats=%d',r), 'axis','nRepeats', 'nRepeats',r); %#ok<AGROW>
end

% (c) preallocate on / off
sweeps{end+1} = struct('label','prealloc=on',  'axis','prealloc','preallocate',true);  %#ok<AGROW>
sweeps{end+1} = struct('label','prealloc=off', 'axis','prealloc','preallocate',false); %#ok<AGROW>
end

function roots = unique_volumes(candidates)
%UNIQUE_VOLUMES  The candidate paths that exist, one per distinct volume.
% Two entries on the same drive would measure the same disk twice and report it
% as a comparison, so they are collapsed to the first.
roots = {};
seen  = {};
for k = 1:numel(candidates)
    c = regexprep(strtrim(char(candidates{k})), '[\\/]+$', '');
    if isempty(c) || ~isfolder(c), continue; end
    tag = volume_tag(c);
    if any(strcmpi(seen, tag)), continue; end
    seen{end+1}  = tag; %#ok<AGROW>
    roots{end+1} = c;   %#ok<AGROW>
end
if isempty(roots), roots = {tempdir}; end
end


function tag = volume_tag(target_path)
%VOLUME_TAG  Short name for the volume holding TARGET_PATH, e.g. 'C:'.
% Used to label results, so a row says which disk it describes.
p = char(target_path);
if numel(p) >= 2 && p(2) == ':'
    tag = upper(p(1:2));
else
    tag = p;
end
end


function bytes = query_free_bytes(target_path)
%QUERY_FREE_BYTES  Usable bytes on the volume holding TARGET_PATH.
% Same java.io.File approach echoframe_disk_monitor uses; walks up to the
% nearest folder that exists, since the config subfolder may not be there yet.
check_path = char(target_path);
while ~isempty(check_path) && ~isfolder(check_path)
    parent = fileparts(check_path);
    if strcmp(parent, check_path), break; end
    check_path = parent;
end
if isempty(check_path) || ~isfolder(check_path)
    check_path = pwd;
end
bytes = double(java.io.File(check_path).getUsableSpace());
end

function result = empty_result()
result.label              = '';
result.axis               = '';
result.config             = '';
result.disk               = '';
result.saveRF             = false;
result.saveBF             = false;
result.preallocate        = false;
result.nRepeats           = NaN;
result.nTX                = NaN;
result.bytes_rf_MB        = NaN;
result.bytes_bf_MB        = NaN;
result.bytes_per_buf_MB   = NaN;
result.time_rf_store_ms   = 0;
result.time_bf_store_ms   = 0;
result.time_total_ms      = 0;
result.rf_MB_per_s        = 0;
result.bf_MB_per_s        = 0;
result.total_MB_per_s     = 0;
result.budget_ms          = NaN;
result.realtime_ratio     = NaN;
result.realtime_pass      = false;
result.target_tx_rate     = NaN;
% The raw write instrumentation for this config. The derived times above are
% latencies; the stall the producer actually paid is only in here.
result.wstats             = struct();
result.bf_store_ms_series = [];
result.time_ms_series     = [];
result.time_ms            = NaN;
% Saved streams that completed only during the drain, so their writes were
% counted but not timed and this row's throughput leaves them out.
result.untimedStreams     = {};
% Set when the volume had no room for even one measured buffer, so nothing was
% written and every number above is the empty default rather than a measurement.
result.skipped            = false;
% Bytes over elapsed time across the whole row, drain included. Unlike the
% per-stream rates above it does not divide by a completion latency, so
% overlapped writes do not deflate it.
result.bytes_written_MB   = NaN;
result.row_elapsed_s      = NaN;
result.sustained_MB_per_s = NaN;
end

function print_results(results)
fprintf('\n======== Storage Benchmark Results ========\n');
fprintf(['%-26s | disk | RF | BF | prealloc | rf ms | bf ms | total ms | MB/buf | ' ...
         'MB/s | sust MB/s | budget ms | real-time\n'], 'label');
fprintf('%s\n', repmat('-', 1, 139));
for i = 1:numel(results)
    r = results(i);
    if r.skipped
        fprintf('%-26s | %4s | %2s | %2s | %8s | %5s | %5s | %8s | %6s | %4s | %9s | %9s | %s\n', ...
                r.label, volume_tag(r.disk), '-', '-', '-', '-', '-', '-', '-', '-', '-', '-', ...
                'SKIPPED (volume full)');
        continue
    end
    fprintf('%-26s | %4s | %2s | %2s | %8s | %5.2f | %5.2f | %8.2f | %6.1f | %4.0f | %9.0f | %9.2f | %s\n', ...
            r.label, volume_tag(r.disk), ...
            ternary(r.saveRF,'on','off'), ternary(r.saveBF,'on','off'), ...
            ternary(r.preallocate,'on','off'), ...
            r.time_rf_store_ms, r.time_bf_store_ms, r.time_total_ms, ...
            r.bytes_per_buf_MB, r.total_MB_per_s, r.sustained_MB_per_s, ...
            r.budget_ms, ternary(r.realtime_pass,'YES','NO'));
end
fprintf('\n');
end

function plot_results(results, mode, target_tx_rate)
switch mode
    case 'fast'
        r = results(1);
        figure('Name', 'Storage benchmark (fast)');

        stages = {'RF write','BF write','Total'};
        vals   = [r.time_rf_store_ms, r.time_bf_store_ms, r.time_total_ms];
        bar(categorical(stages, stages), vals);
        hold on;
        yline(r.budget_ms, 'r--', ...
              sprintf(' budget @ %g kHz = %.2f ms', target_tx_rate/1e3, r.budget_ms), ...
              'LineWidth', 2, 'LabelHorizontalAlignment','left');
        ylabel('Time per buffer [ms]');
        title(sprintf('%s | %.0f MB/buf | %.0f MB/s | real-time: %s', ...
                      r.label, r.bytes_per_buf_MB, r.total_MB_per_s, ...
                      ternary(r.realtime_pass,'YES','NO')));
        grid on;

    case 'elaborate'
        figure('Name', 'Storage benchmark (elaborate)');

        % Panel 1: streams (RF only / BF only / both)
        subplot(1, 3, 1);
        sel      = strcmp({results.axis}, 'streams');
        selected = results(sel);
        labels   = {selected.label};
        bar(categorical(labels, labels), ...
            [[selected.time_rf_store_ms]; [selected.time_bf_store_ms]; [selected.time_total_ms]].');
        legend({'RF write','BF write','Total'}, 'Location','best');
        ylabel('Time per buffer [ms]');
        title('Streams to save');
        grid on;

        % Panel 2: nRepeats sweep - total time + budget
        subplot(1, 3, 2);
        sel      = strcmp({results.axis}, 'nRepeats');
        selected = results(sel);
        plot([selected.nRepeats], [selected.time_total_ms], '-o', 'LineWidth', 1.5); hold on;
        plot([selected.nRepeats], [selected.budget_ms], '-s', 'LineWidth', 1.5);
        xlabel('nRepeats'); ylabel('Time per buffer [ms]');
        title(sprintf('nRepeats sweep (target %.0f kHz)', target_tx_rate/1e3));
        legend('actual','budget','Location','best'); grid on;

        % Panel 3: preallocate on/off
        subplot(1, 3, 3);
        sel      = strcmp({results.axis}, 'prealloc');
        selected = results(sel);
        labels   = {selected.label};
        bar(categorical(labels, labels), [selected.time_total_ms]); hold on;
        yline(selected(1).budget_ms, 'r--', 'LineWidth', 2);
        ylabel('Time per buffer [ms]'); title('Preallocate full file');
        grid on;
end
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

function run_endurance_test(output_dir, target_tx_rate, endurance_gb)
% How long can this drive carry this configuration, with RF on?
%
% This is the mode to run before planning a recording. It answers one question:
% at the rate this configuration produces data, how many frames go by before the
% drive stops keeping up. Everything else here measures a settled per-buffer
% number; this one measures the number NOT settling.
%
% Why it has to be long. An SSD absorbs writes into a fast cache and reports its
% burst rate for as long as that cache lasts -- tens to hundreds of GB on a large
% drive. A short run measures the cache, calls it the sustained rate, and reports
% a recording length the drive cannot hold.
%
% What it prints is a rate PER INTERVAL, not an average. An average over a run
% that crosses the cliff smears the two regimes together and hides the thing
% being looked for.
%
% RF is forced on, because RF is the load: it is ~83% of the bytes in a probe
% configuration, and a run without it answers a question nobody asked.

REPORT_EVERY = 8;        % buffers between progress lines
SETTLE_TAIL  = 0.33;     % fraction of the run averaged for the settled rate

% The configuration under test. Edit default_specs to measure the setup you will
% record with; the defaults here are small enough to flatter the drive.
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, StorageSpec] = ...
    default_specs(1);
tx_rate = target_tx_rate;

% What the acquisition writes: every stream it writes live, RF included.
StorageSpec.saveRF        = true;
StorageSpec.saveBF        = true;
StorageSpec.savePDI       = true;
StorageSpec.saveRFTimeTag = true;

[RF_base, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

nEns      = max(0, floor((double(ReceiveSpec.nRepeats) - double(PDISpec.ensembleSize)) / ...
                          double(PDISpec.shiftSize)) + 1);
bytes_rf  = double(ReceiveSpec.nSamples) * double(ReceiveSpec.nChannels) * ...
            double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats) * 2;
bytes_bf  = double(ReconSpec.nz) * double(ReconSpec.nx) * double(ReceiveSpec.nRepeats) * 8;
bytes_pdi = double(ReconSpec.nz) * double(ReconSpec.nx) * nEns * 4;
bytes_buf = bytes_rf + bytes_bf + bytes_pdi;

frame_s   = double(ReceiveSpec.nTransmissions) * double(ReceiveSpec.nRepeats) / tx_rate;
need_MBs  = bytes_buf / 1e6 / frame_s;

% Size the run: the target, or half the free space, whichever is smaller.
cfg_out    = fullfile(output_dir, 'endurance');
if ~exist(cfg_out, 'dir'), mkdir(cfg_out); end
free_bytes = query_free_bytes(cfg_out);
target_b   = min(endurance_gb * 1e9, free_bytes / 2);
n_buffers  = floor(target_b / max(bytes_buf, 1));
if n_buffers < 4
    error('benchmark_storage:enduranceNoRoom', ...
          ['A buffer is %.0f MB and only %.1f GB is free at %s, so an ' ...
           'endurance run cannot get past its own warmup. Free space, or ' ...
           'test a configuration that writes less.'], ...
           bytes_buf / 1e6, free_bytes / 1e9, cfg_out);
end

fprintf('\n==== endurance: how long can this drive carry this configuration? ====\n');
fprintf('  per frame   RF %.0f MB + BF %.0f MB + PDI %.0f MB = %.0f MB\n', ...
        bytes_rf / 1e6, bytes_bf / 1e6, bytes_pdi / 1e6, bytes_buf / 1e6);
fprintf('  frame period %.0f ms  ->  needs %.0f MB/s sustained\n', ...
        frame_s * 1e3, need_MBs);
fprintf('  writing %d buffers = %.0f GB to %s\n', ...
        n_buffers, n_buffers * bytes_buf / 1e9, cfg_out);
fprintf(['  NOTE: this is the benchmark''s own small configuration, not a ' ...
         'probe setup.\n        Edit default_specs to match the setup you ' ...
         'will record with for an answer about a real recording.\n']);

StorageSpec.folderStoragePath          = cfg_out;
ExperimentSpec.numberOfPDIsExperiment  = n_buffers;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

fprintf('\n  %8s %10s %12s %12s %10s\n', ...
        'buffers', 'written', 'interval', 'cumulative', 'vs need');
fprintf('  %8s %10s %12s %12s %10s\n', ...
        '', 'GB', 'MB/s', 'MB/s', '');

% Every rate below divides bytes by accumulated process() time.
per_buf_s = zeros(n_buffers, 1);
rng(1);
proc_s    = 0;       % accumulated process() time for the whole run
mark_s    = 0;       % ... and since the last progress line
mark_at   = 0;
turned_at = NaN;
kept_up   = false;   % did any interval ever meet the requirement?

for k = 1:n_buffers
    RF = RF_base + int16(round(50 * randn(size(RF_base))));
    t0 = tic;
    [~, ~] = echoframe_mex('process', RF, true);
    per_buf_s(k) = toc(t0);
    proc_s       = proc_s + per_buf_s(k);
    mark_s       = mark_s + per_buf_s(k);

    if mod(k, REPORT_EVERY) == 0 || k == n_buffers
        span_MBs = (k - mark_at) * bytes_buf / 1e6 / max(mark_s, eps);
        cum_MBs  = k * bytes_buf / 1e6 / max(proc_s, eps);
        ok       = span_MBs >= need_MBs;
        % "Turned" means it kept up and then stopped. A configuration that was
        % behind from the first interval never turned -- it never fit - and
        % saying it "fell behind after 8 frames" would invite someone to record
        % 7 frames and expect them to be fine.
        if ok
            kept_up = true;
        elseif kept_up && isnan(turned_at)
            turned_at = k;
        end
        fprintf('  %8d %10.1f %12.0f %12.0f %10s\n', ...
                k, k * bytes_buf / 1e9, span_MBs, cum_MBs, ...
                ternary(ok, 'ok', 'BEHIND'));
        mark_s  = 0;
        mark_at = k;
    end
end

wstats = echoframe_mex('storage_stats');
release_mex;

% The settled rate is the tail, not the mean: the mean includes whatever burst
% the cache absorbed at the start, which is not a rate anything can be planned
% against.
tail_from   = max(1, round(n_buffers * (1 - SETTLE_TAIL)));
tail_s      = sum(per_buf_s(tail_from:end));
tail_n      = n_buffers - tail_from + 1;
settled_MBs = tail_n * bytes_buf / 1e6 / max(tail_s, eps);

fprintf('\n  settled %.0f MB/s over the last %.1f GB, need %.0f MB/s\n', ...
        settled_MBs, tail_n * bytes_buf / 1e9, need_MBs);
if ~kept_up
    fprintf(['  never kept up: behind from the first interval, so there is no ' ...
             'recording length\n  at this configuration -- it does not fit at ' ...
             'all.\n']);
elseif isnan(turned_at)
    fprintf(['  kept up for the whole %.1f GB. A longer run may still find a ' ...
             'limit;\n  this says the drive holds at least that far.\n'], ...
            n_buffers * bytes_buf / 1e9);
else
    fprintf(['  fell behind after %d frames -- %.1f GB, %.1f s of recording ' ...
             'at this configuration.\n'], turned_at, ...
            turned_at * bytes_buf / 1e9, turned_at * frame_s);
end
if settled_MBs < need_MBs
    fprintf(['  This configuration cannot be recorded continuously on this ' ...
             'volume:\n  it produces %.0f MB/s and the drive settles at %.0f. ' ...
             'Turn RF off (%.0f MB/s\n  without it), lower the bandwidth, or ' ...
             'split the streams across drives.\n'], ...
            need_MBs, settled_MBs, (bytes_bf + bytes_pdi) / 1e6 / frame_s);
end
report_blocked(wstats);

% Say what actually happened. local_rmdir warns and carries on when it cannot
% delete, so announcing success unconditionally was a lie on exactly the runs
% where it mattered.
local_rmdir(cfg_out);
if exist(cfg_out, 'dir')
    fprintf(['\nNOTE: %s could not be removed and still holds about %.1f GB. ' ...
             'Delete it by hand.\n'], cfg_out, n_buffers * bytes_buf / 1e9);
else
    fprintf('\n(test files removed)\n');
end
end


function report_blocked(w)
%REPORT_BLOCKED  Producer stall per stream, which is the trustworthy number.
% Not latency: completions are only reaped when the next buffer is handed over,
% so latency quantises to the caller's period and reads the same for a 1 GB
% stream and a few-KB one. blockedTotalMs wraps the actual wait.
fprintf('\n  producer stall (time storeBuffer spent waiting for a slot):\n');
for f = {'rf', 'bf', 'pdi', 'timetag'}
    if ~isfield(w, f{1}), continue; end
    s = w.(f{1});
    if ~s.saving, continue; end
    fprintf('    %-8s %9.1f ms total, %8.1f ms worst, %d writes\n', ...
            f{1}, s.blockedTotalMs, s.blockedMaxMs, s.writes);
end
end


function run_rf_method_comparison(output_dir, target_tx_rate)
% Compare the per-buffer ACQUISITION STEP two ways, on the same RF buffers:
%   OLD: beamform, then store RF via the separate `storage` MEX
%        -> echoframe_mex('process', RF, false) + storage('store', RF)
%   NEW: beamform and store RF together inside echoframe_mex
%        -> echoframe_mex('process', RF, true)   (RFStorageSpec passed to 'init')
% Both beamform once and persist one rf_acq.dat buffer, so they are directly
% comparable; the only difference is how RF is stored.
%
% A single run tracks whatever else the machine is doing, so the comparison is:
%   * N_TRIALS independent trials, each re-initialising from scratch,
%   * each path's full per-buffer time measured directly, paired and interleaved
%     (alternating order) so drift cancels,
%   * all trials pooled and summarised as median +/- IQR with the paired
%     difference and a win-rate, plus each trial's own median.

N_TRIALS  = 5;       % independent repeats (each re-inits everything)
N_WARMUP  = 10;      % per trial, not timed
N_MEASURE = 30;      % paired buffers per trial. Peak disk ~= 2*(N_WARMUP+N_MEASURE)
                     % * RF-buffer size. Raise for tighter medians if disk allows.
NREPEATS  = 40;      % slow-time samples per buffer -- the main buffer-size knob.
                     % 40 is the light demo value (quick run). For a realistic
                     % fUS / Power Doppler case use ~100-300 here (and lower
                     % N_MEASURE to bound disk); RF buffer size scales with it.
noiseStd  = 50;

% ---- Baseline specs + one base RF buffer (computed once; deterministic) -------
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, StorageSpec] = ...
    default_specs(N_MEASURE);
ReceiveSpec.nRepeats = NREPEATS;     % realistic ensemble size (see NREPEATS above)
PDISpec.ensembleSize = NREPEATS;     % keep the PDI window consistent (PDI is off here)
PDISpec.shiftSize    = NREPEATS;
StorageSpec.saveRF        = true;    % isolate RF storage (BF/PDI/time-tag off)
StorageSpec.saveBF        = false;
StorageSpec.savePDI       = false;
StorageSpec.saveRFTimeTag = false;
% Each file must hold every warmup + measured store in a trial (storeBuffer
% silently drops past maxNumberBuffers), with a little margin.
ExperimentSpec.numberOfPDIsExperiment = N_WARMUP + N_MEASURE + 4;

[RF_base, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

% Freeze the un-validated baseline so every trial starts identically (validate
% is applied to per-trial working copies, in the canonical init_storage->validate
% order).
P0 = ProbeSpec; T0 = TransmitSpec; R0 = ReceiveSpec; Rec0 = ReconSpec; PDI0 = PDISpec;

bytes_rf = double(R0.nSamples) * double(R0.nChannels) * ...
           double(R0.nTransmissions) * double(R0.nRepeats) * 2;
peak_gb  = 2 * (N_WARMUP + N_MEASURE) * bytes_rf / 1e9;
fprintf('Compare mode: %d trials x %d paired buffers of %.1f MB (peak ~%.1f GB, deleted each trial).\n', ...
        N_TRIALS, N_MEASURE, bytes_rf / 1e6, peak_gb);

new_dir = fullfile(output_dir, 'new_method');
old_dir = fullfile(output_dir, 'old_method');

% ---- Pooled + per-trial accumulators -----------------------------------------
T_new       = zeros(N_TRIALS * N_MEASURE, 1);
T_old       = zeros(N_TRIALS * N_MEASURE, 1);
trial_med_d = zeros(N_TRIALS, 1);
trial_win   = zeros(N_TRIALS, 1);

for trial = 1:N_TRIALS
    % Fresh MEX + fresh files each trial => independent trials.
    clear mex;
    local_rmdir(new_dir);
    local_rmdir(old_dir);

    P = P0; T = T0; R = R0; Rec = Rec0; PDI = PDI0;   % un-validated working copies

    % NEW backend: echoframe_mex writes new_method/rf_acq.dat
    StorageSpec.folderStoragePath = new_dir;
    [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpecNew] = ...
        init_storage('init', StorageSpec, R, Rec, PDI, ExperimentSpec, T, P);
    % OLD backend: separate storage MEX writes old_method/rf_acq.dat
    StorageSpec.folderStoragePath = old_dir;
    [~, ~, ~, RFStorageSpecOld] = ...
        init_storage('init', StorageSpec, R, Rec, PDI, ExperimentSpec, T, P);

    [P, T, R, Rec, PDI] = echoframe_validate_structs(P, T, R, Rec, PDI); %#ok<ASGLU>
    echoframe_mex('init', R, Rec, PDI, ...
                  BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpecNew);
    storage('init', RFStorageSpecOld);

    % Warmup (not timed)
    rng(0);
    for k = 1:N_WARMUP
        RF = RF_base + int16(round(noiseStd * randn(size(RF_base))));
        echoframe_mex('process', RF, true);
        echoframe_mex('process', RF, false); storage('store', RF);
    end

    % Paired, interleaved measurement (alternating order)
    tn = zeros(N_MEASURE, 1);
    to = zeros(N_MEASURE, 1);
    rng(trial);   % different buffers each trial
    for k = 1:N_MEASURE
        RF = RF_base + int16(round(noiseStd * randn(size(RF_base))));
        if mod(k, 2) == 1
            a = tic; echoframe_mex('process', RF, true);  tn(k) = toc(a);
            b = tic; echoframe_mex('process', RF, false); storage('store', RF); to(k) = toc(b);
        else
            b = tic; echoframe_mex('process', RF, false); storage('store', RF); to(k) = toc(b);
            a = tic; echoframe_mex('process', RF, true);  tn(k) = toc(a);
        end
    end

    try
        echoframe_mex('destroy');   % release BF/RF file handles before clear mex
    catch
    end
    clear mex;
    local_rmdir(new_dir);
    local_rmdir(old_dir);

    % Accumulate (ms)
    tn  = tn * 1e3;   to = to * 1e3;
    idx = (trial - 1) * N_MEASURE + (1:N_MEASURE);
    T_new(idx) = tn;
    T_old(idx) = to;
    dd = to - tn;
    trial_med_d(trial) = median(dd);
    trial_win(trial)   = mean(dd > 0) * 100;
    fprintf('  trial %d/%d: old %.2f ms | new %.2f ms | diff %+.2f ms | new wins %3.0f%%\n', ...
            trial, N_TRIALS, median(to), median(tn), median(dd), trial_win(trial));
end

% ---- Pooled robust statistics ------------------------------------------------
med_new = median(T_new);  p25_new = local_prctile(T_new, 25);  p75_new = local_prctile(T_new, 75);
med_old = median(T_old);  p25_old = local_prctile(T_old, 25);  p75_old = local_prctile(T_old, 75);
D       = T_old - T_new;                    % > 0 => NEW faster this buffer
med_d   = median(D);  p25_d = local_prctile(D, 25);  p75_d = local_prctile(D, 75);
new_wins = mean(D > 0) * 100;

trials_agree_new = all(trial_med_d > 0);
trials_agree_old = all(trial_med_d < 0);
if new_wins >= 75 && trials_agree_new
    verdict = sprintf('NEW is reliably faster: %.0f%% of buffers, all %d trials agree, median %.2f ms/buffer (%.1f%%).', ...
                      new_wins, N_TRIALS, med_d, 100 * med_d / max(med_old, eps));
elseif new_wins <= 25 && trials_agree_old
    verdict = sprintf('OLD is reliably faster: %.0f%% of buffers, all %d trials agree, median %.2f ms/buffer.', ...
                      100 - new_wins, N_TRIALS, -med_d);
else
    verdict = sprintf('No consistent winner: NEW wins %.0f%% of buffers; per-trial median diff ranges %.2f..%.2f ms (within noise).', ...
                      new_wins, min(trial_med_d), max(trial_med_d));
end

fprintf('\n===== Per-buffer acquisition step: OLD (process + storage MEX) vs NEW (process stores RF) =====\n');
fprintf('RF buffer size    : %.1f MB   |   %d trials x %d paired buffers = %d samples\n', ...
        bytes_rf / 1e6, N_TRIALS, N_MEASURE, N_TRIALS * N_MEASURE);
fprintf('OLD  (pooled)     : median %.2f ms  [IQR %.2f-%.2f]\n', med_old, p25_old, p75_old);
fprintf('NEW  (pooled)     : median %.2f ms  [IQR %.2f-%.2f]\n', med_new, p25_new, p75_new);
fprintf('paired (old-new)  : median %.2f ms  [IQR %.2f-%.2f]  (>0 => NEW faster)\n', med_d, p25_d, p75_d);
fprintf('per-trial diff    : %s ms\n', mat2str(round(trial_med_d', 2)));
fprintf('per-trial new-win : %s %%\n', mat2str(round(trial_win')));
fprintf('=> %s\n', verdict);

bf_per_pdi = double(R0.nTransmissions) * double(R0.nRepeats);
budget_ms  = bf_per_pdi / target_tx_rate * 1e3;

figure('Name', 'RF storage: old vs new (multi-trial)');
subplot(1, 2, 1);
x = [1 2];
bar(x, [med_old, med_new]); hold on;
errorbar(x, [med_old, med_new], ...
         [med_old - p25_old, med_new - p25_new], [p75_old - med_old, p75_new - med_new], ...
         'k', 'linestyle', 'none', 'LineWidth', 1.5);
yline(budget_ms, 'r--', sprintf(' budget %.2f ms', budget_ms), 'LineWidth', 1.5);
set(gca, 'XTick', x, 'XTickLabel', {'OLD (process+store)', 'NEW (process stores RF)'});
ylabel('per-buffer time [ms]');
title(sprintf('pooled median \\pm IQR (%d samples)', N_TRIALS * N_MEASURE)); grid on;

subplot(1, 2, 2);
bar(1:N_TRIALS, trial_med_d); hold on;
yline(0, 'r--', 'LineWidth', 1.5);
xlabel('trial'); ylabel('median (OLD - NEW) [ms]');
title('per-trial paired diff (>0: NEW faster)'); grid on;

% Final safety cleanup (each trial already removed its files).
local_rmdir(old_dir);
local_rmdir(new_dir);
fprintf('\nTemporary benchmark files cleaned up under: %s\n', output_dir);
end

function q = local_prctile(x, p)
% Toolbox-free percentile (linear interpolation between order statistics), so
% the benchmark does not depend on the Statistics Toolbox.
x = sort(x(:));
n = numel(x);
if n == 0, q = NaN; return; end
if n == 1, q = x(1); return; end
idx  = (p / 100) * (n - 1) + 1;
lo   = floor(idx);
hi   = ceil(idx);
frac = idx - lo;
q    = x(lo) * (1 - frac) + x(hi) * frac;
end

function release_mex()
%RELEASE_MEX  Close the storage files, then drop the module.
%
% Order matters and `clear mex` alone is not enough. echoframe_mex calls
% mexLock, so clearing does not unload it and the storage handles stay open --
% every local_rmdir that followed a bare `clear mex` failed, warned, and left
% the row's files behind. They accumulate: 76 GB had built up in tempdir here
% before anyone looked, on a drive whose free space is exactly what the
% endurance question turns on.
%
% 'destroy' is what closes the files. Guarded because a row that never got as
% far as initialising has nothing to destroy, and throwing here would lose the
% results the caller is about to write.
try
    echoframe_mex('destroy');
catch
    % Not initialised, or already gone. Either way there is nothing holding a
    % file open, which is all this needs to be true.
end
clear mex
end


function local_rmdir(p)
% Best-effort recursive remove: retries briefly, then warns instead of erroring.
if ~exist(p, 'dir'), return; end
msg = '';
for attempt = 1:5
    [ok, msg] = rmdir(p, 's');
    if ok, return; end
    pause(0.3);
end
warning('benchmark_storage:cleanup', 'Could not remove %s (%s).', p, strtrim(msg));
end
