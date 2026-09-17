% benchmark_echoframe - Throughput benchmark for EchoFrame.
%
% Runs Fourier beamforming + PDI on synthetic noise RF (BS100BW), measures
% per-PDI processing time and compares it against a real-time acquisition
% budget. Also reports per-stage timings from the MEX (CUDA events).
%
% Key metrics (per config):
%   time_ms         - mean processing time for one process() call (one PDI).
%   budget_ms       - (nTX * nRepeats) / TARGET_TX_RATE, i.e. the acquisition
%                     window that produced those frames. If processing fits
%                     under this, the library can sustain the target TX rate.
%   realtime_ratio  - budget_ms / time_ms. >=1 means real-time capable.
%   bf_fps          - beamformed frames per second = nTX*nRepeats / time_s.
%   gb_per_s        - RF input throughput in GB/s.
%
% time_ms is the wall clock around process(), called with the same two outputs
% the live loop asks for, so it is the number a real-time claim rests on. The
% stage_* fields are CUDA events on the null stream and do not add up to it:
% they cannot see what the MEX does around the core call (marshalling the
% outputs, queueing the RF write). Quote time_ms for the cost, stage_* for
% where it goes.
%
% Four modes (edit MODE below):
%   'fast'       two configs, quick (~seconds): the Covariance baseline and
%                nTX=16 / nSamples=512 on the 'Full' SVD. Histogram + budget
%                line + stacked stage breakdown.
%   'elaborate'  three 1-D sweeps (nRepeats, nTransmissions, PDI on/off).
%                Time vs. budget curves.
%   'throughput' nTX in {8,16,32} x nSamples in {256..1536}. Plots GB/s
%                vs nSamples, one line per nTX.
%   'plan'       interactive GPU data-size planner: sliders for the dimensions
%                that set data size + the cuFFT plan (fast-time samples,
%                channels, transmit angles, slow-time repeats, output voxels,
%                PDI ensemble) with a live memory estimate, per-buffer
%                breakdown, and fit indicator. No timing; needs a display.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built; nvidia-smi on PATH
%         (or Parallel Computing Toolbox) for the GPU memory check.
% Usage:  set MODE below; run.

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
MODE            = 'fast';   % 'fast' | 'elaborate' | 'throughput' | 'plan'
TARGET_TX_RATE  = 10e3;     % Hz; typical fUS plane-wave transmit rate

fprintf('benchmark_echoframe: mode ''%s''\n', MODE);

switch MODE
    case 'plan'
        % Interactive GPU data-size planner; no timing sweep.
        launch_gpu_planner(TARGET_TX_RATE);
        return;
    case 'fast'
        N_WARMUP  = 3;
        N_MEASURE = 30;
        % A second config so the stage breakdown has something to compare the
        % baseline against. 16 angles at 512 samples is a realistic fUS frame
        % and carries its own budget (16*40 / 10 kHz = 64 ms), which is what
        % makes the per-tower markers worth drawing. It also runs the other
        % clutter filter: the baseline is Covariance, so 'Full' shows what the
        % full SVD costs in the PDI segment of the tower.
        sweeps    = { struct('label', 'baseline', 'axis', 'baseline'), ...
                      struct('label', 'nTX=16,nS=512,Full', 'axis', 'baseline', ...
                             'nTX', 16, 'nSamples', 512, 'svdMethod', 'Full') };
    case 'elaborate'
        N_WARMUP  = 3;
        N_MEASURE = 15;
        sweeps    = build_elaborate_sweeps();
    case 'throughput'
        N_WARMUP  = 3;
        N_MEASURE = 10;
        sweeps    = build_throughput_sweeps();
    otherwise
        error('MODE must be ''fast'', ''elaborate'', ''throughput'', or ''plan''.');
end

%% Pre-allocate results
results(numel(sweeps)) = empty_result();

%% Run sweep (MEX calls at script scope)
for i = 1:numel(sweeps)
    meta = sweeps{i};
    fprintf('[%d/%d] %s\n', i, numel(sweeps), meta.label);

    % A config may carry a whole spec set (a real probe setup); otherwise start
    % from the defaults and apply the meta overrides below.
    if isfield(meta, 'specs')
        ProbeSpec    = meta.specs.ProbeSpec;
        TransmitSpec = meta.specs.TransmitSpec;
        ReceiveSpec  = meta.specs.ReceiveSpec;
        ReconSpec    = meta.specs.ReconSpec;
        PDISpec      = meta.specs.PDISpec;
    else
        [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = default_specs();
    end

    % Each probe setup transmits at its own rate, so one global rate cannot set
    % every budget.
    if isfield(meta, 'txRate'), tx_rate = meta.txRate; else, tx_rate = TARGET_TX_RATE; end

    if isfield(meta, 'nRepeats')
        ReceiveSpec.nRepeats = meta.nRepeats;
        PDISpec.ensembleSize = meta.nRepeats;
        PDISpec.shiftSize   = meta.nRepeats;
    end
    if isfield(meta, 'nTX')
        TransmitSpec.steer          = linspace(-10, 10, meta.nTX);
        TransmitSpec.apodization    = ones(ProbeSpec.nElements, 1);
        ReceiveSpec.nTransmissions  = meta.nTX;
    end
    if isfield(meta, 'getPDI')
        ReconSpec.getPDI = logical(meta.getPDI);
    end
    if isfield(meta, 'samplingMode')
        % Receive bandwidth. It changes the pre/post-resample ratio and the
        % samples per wavelength, so it changes the work without changing the
        % byte count once nSamples is pinned -- which is the point of sweeping
        % it. sampling_mode_factors rejects anything it cannot handle.
        sampling_mode_factors(meta.samplingMode);
        ReceiveSpec.samplingMode = meta.samplingMode;
    end
    if isfield(meta, 'svdMethod')
        % Checked here because the MEX does not: convertPDISpecStructs treats
        % anything that is not 'Full' as CovarianceEig, so a typo would run the
        % baseline filter a second time under the other name.
        if ~any(strcmp(meta.svdMethod, {'Full', 'Covariance'}))
            error('benchmark_echoframe:svdMethod', ...
                  'svdMethod must be ''Full'' or ''Covariance'', got ''%s''.', ...
                  meta.svdMethod);
        end
        PDISpec.svdMethod = meta.svdMethod;
    end
    nSamples_override = [];
    if isfield(meta, 'nSamples')
        nSamples_override = meta.nSamples;
    end

    % Reset MEX between configs (not on first, already cleared at script top)
    if i > 1
        clear mex;
    end

    % Generate noise RF
    [RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
        simulate_noise_rf(ProbeSpec, TransmitSpec, ReceiveSpec, nSamples_override);

    ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

    % Derive nz/nx
    [ProbeSpec, ReceiveSpec, ReconSpec] = ...
        initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

    result          = empty_result();
    result.label    = meta.label;
    result.axis     = meta.axis;
    % Which configuration this row belongs to, when a caller grouped them.
    if isfield(meta, 'config'), result.config = meta.config; end
    result.nRepeats = ReceiveSpec.nRepeats;
    result.nTX      = ReceiveSpec.nTransmissions;
    result.getPDI   = ReconSpec.getPDI;
    result.svdMethod    = PDISpec.svdMethod;
    result.samplingMode = char(ReceiveSpec.samplingMode);

    % GPU check
    [fits, info] = check_gpu_memory_fit(ReceiveSpec, ReconSpec, PDISpec);
    result.fits          = fits;
    result.mem_estimate  = info.estimated_bytes;
    result.mem_available = info.available_bytes;

    if ~fits
        fprintf('  SKIPPED: %.2f GB estimate > %.2f GB available\n', ...
                info.estimated_bytes/1e9, info.available_bytes/1e9);
        for s = 1:numel(info.suggestions)
            fprintf('    - %s\n', info.suggestions{s});
        end
        results(i) = result;
        continue;
    end

    % Validate + init
    [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
        echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
    echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec);

    % Warmup. Two outputs, like the live loop: a third asks the MEX for the
    % whole complex BF volume, which ef_external_process never requests and
    % which would put a nz*nx*nRepeats*8 allocate-and-copy inside the timed
    % region (127.8 MB per call on the GE9LD).
    for k = 1:N_WARMUP
        [~, ~] = echoframe_mex('process', RF, false);
    end

    % Measure. Capture MEX-side per-stage timings alongside wall-clock time.
    times              = zeros(N_MEASURE, 1);
    time_rf_transfer   = zeros(N_MEASURE, 1);
    time_rf_formatting = zeros(N_MEASURE, 1);
    time_beamforming   = zeros(N_MEASURE, 1);
    time_bf_formatting = zeros(N_MEASURE, 1);
    time_pdi_processing = zeros(N_MEASURE, 1);
    time_pdi_transfer  = zeros(N_MEASURE, 1);
    time_bf_storage    = zeros(N_MEASURE, 1);
    time_pdi_storage   = zeros(N_MEASURE, 1);
    time_total_mex     = zeros(N_MEASURE, 1);
    for k = 1:N_MEASURE
        t0 = tic;
        [~, ~] = echoframe_mex('process', RF, false);
        times(k)               = toc(t0);
        % Collected after the clock stops: the stage timings are from the last
        % call either way, and asking for them as a fourth output would change
        % what the call costs.
        tt = echoframe_mex('timings');
        time_rf_transfer(k)    = tt.rf_transfer;
        time_rf_formatting(k)  = tt.rf_formatting;
        time_beamforming(k)    = tt.beamforming;
        time_bf_formatting(k)  = tt.bf_formatting;
        time_pdi_processing(k) = tt.pdi_processing;
        time_pdi_transfer(k)   = tt.pdi_transfer;
        time_bf_storage(k)     = tt.bf_storage;
        time_pdi_storage(k)    = tt.pdi_storage;
        time_total_mex(k)      = tt.total;
    end

    echoframe_mex('destroy');   % release this config's resources (next config re-inits)

    % Derived metrics (wall-clock)
    result.skipped         = false;
    result.latency_ms_all  = times * 1e3;
    result.time_ms         = mean(result.latency_ms_all);
    result.time_ms_median  = median(result.latency_ms_all);
    result.nSamples        = double(ReceiveSpec.nSamples);
    result.nChannels       = double(ReceiveSpec.nChannels);
    bf_per_pdi             = double(result.nTX) * double(result.nRepeats);
    result.bf_fps          = bf_per_pdi / mean(times);
    result.pdi_fps         = 1 / mean(times);
    result.budget_ms       = bf_per_pdi / tx_rate * 1e3;
    result.realtime_ratio  = result.budget_ms / result.time_ms;
    result.realtime_pass   = result.realtime_ratio >= 1;
    result.target_tx_rate  = tx_rate;
    % Stored samples per second per channel. The PRF cannot exceed
    % sample_rate_hz/nSamples -- the receive window has to fit the pulse
    % interval -- so this is what caps the RF rate the front end can
    % deliver, independent of depth. Figure 2 saturates its acquisition
    % line with it.
    result.sample_rate_hz  = double(ReceiveSpec.samplesPerWavelength) * ...
                             double(ProbeSpec.Fc);
    % RF input throughput (GB/s). int16 = 2 bytes per sample.
    rf_bytes_per_pdi       = result.nSamples * result.nChannels * result.nTX * result.nRepeats * 2;
    result.gb_per_s        = rf_bytes_per_pdi / mean(times) / 1e9;
    % Recorded, not just divided out: a sweep that holds the input size fixed
    % while varying bandwidth and ensemble has to be able to show it held.
    result.rf_MB_per_pdi   = rf_bytes_per_pdi / 1e6;

    % Stage breakdown (ms, mean across iterations):
    %   IO          = RF host -> GPU transfer + RF formatting (type cast)
    %   Beamforming = Fourier beamforming stage
    %   PDI         = BF formatting + PDI processing + PDI transfer back
    %   Saving      = BF storage + PDI storage
    %   Sum         = IO + Beamforming + PDI + Saving
    result.stage_io_ms        = mean(time_rf_transfer + time_rf_formatting) * 1e3;
    result.stage_beam_ms      = mean(time_beamforming) * 1e3;
    result.stage_pdi_ms       = mean(time_bf_formatting + time_pdi_processing + time_pdi_transfer) * 1e3;
    result.stage_save_ms      = mean(time_bf_storage + time_pdi_storage) * 1e3;
    result.stage_sum_ms       = result.stage_io_ms + result.stage_beam_ms + ...
                                result.stage_pdi_ms + result.stage_save_ms;
    result.stage_mex_total_ms = mean(time_total_mex) * 1e3;

    fprintf('  %s: %.2f ms/PDI | budget %.2f ms | ratio %.2f | PDI %.1f fps | BF %.0f fps | %.2f GB/s | real-time: %s\n', ...
            meta.label, result.time_ms, result.budget_ms, result.realtime_ratio, ...
            result.pdi_fps, result.bf_fps, result.gb_per_s, ternary(result.realtime_pass, 'YES', 'NO'));

    results(i) = result;
end

%% Report + plot
print_results(results);
plot_results(results, MODE, TARGET_TX_RATE);
plot_stage_breakdown(results, TARGET_TX_RATE);

%% =====================================================================
%% Local functions (pure computation, no MEX calls)
%% =====================================================================

function [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = default_specs()
ProbeSpec.pitch              = 300e-6;
ProbeSpec.Fc                 = 5e6;
ProbeSpec.nElements          = 128;

TransmitSpec.c0              = 1540;
TransmitSpec.type            = 'planewave';
TransmitSpec.steer           = [-10 0 10];
TransmitSpec.apodization     = ones(ProbeSpec.nElements, 1);

ReceiveSpec.nRepeats         = 40;
ReceiveSpec.Fs              = 20e6;
ReceiveSpec.nTransmissions   = length(TransmitSpec.steer);
ReceiveSpec.samplingMode    = 'BS100BW';

ReconSpec.bfDataType         = 'complex single';
ReconSpec.filterFrequencies  = logical(false);
ReconSpec.getBF              = logical(true);
ReconSpec.getPDI             = logical(true);
ReconSpec.extraVoxelsZ     = 0;
ReconSpec.extraVoxelsX     = 128;
ReconSpec.c0                 = TransmitSpec.c0;
ReconSpec.cropBF             = logical(false);
ReconSpec.croppingROI        = [0; 128; 0; 128];

PDISpec.ensembleSize         = ReceiveSpec.nRepeats;
PDISpec.threshold            = single(0.4);
PDISpec.shiftSize           = ReceiveSpec.nRepeats;
PDISpec.cropPDI              = logical(false);
PDISpec.svdMethod           = 'Covariance';
end

function sweeps = build_elaborate_sweeps()
sweeps = {};
for r = [20 40 80 160]
    sweeps{end+1} = struct('label', sprintf('nRepeats=%d', r), 'axis', 'nRepeats', 'nRepeats', r); %#ok<AGROW>
end
for n = [1 3 5 10]
    sweeps{end+1} = struct('label', sprintf('nTX=%d', n), 'axis', 'nTX', 'nTX', n); %#ok<AGROW>
end
for p = [false true]
    sweeps{end+1} = struct('label', sprintf('PDI=%s', ternary(p,'on','off')), 'axis', 'pdi', 'getPDI', p); %#ok<AGROW>
end
end

function sweeps = build_throughput_sweeps()
% Throughput curves: nTX in {8,16,32}, nSamples (post-resample) in a range.
sweeps   = {};
nTX_vals = [8 16 32];
nS_vals  = [96 192 288 384 480 576 672 768 864 960 1056 1152 1248 1344 1440 1536];
for nTX = nTX_vals
    for ns = nS_vals
        sweeps{end+1} = struct( ...
            'label',    sprintf('nTX=%d,nS=%d', nTX, ns), ...
            'axis',     'throughput', ...
            'nTX',      nTX, ...
            'nSamples', ns); %#ok<AGROW>
    end
end
end

function result = empty_result()
result.label              = '';
result.axis               = '';
result.config             = '';
result.nRepeats           = NaN;
result.nTX                = NaN;
result.nSamples           = NaN;
result.nChannels          = NaN;
result.getPDI             = false;
result.svdMethod          = '';
result.samplingMode       = '';
result.rf_MB_per_pdi      = NaN;
result.time_ms            = NaN;
result.time_ms_median     = NaN;
result.latency_ms_all     = [];
result.bf_fps             = NaN;
result.pdi_fps            = NaN;
result.gb_per_s           = NaN;
result.budget_ms          = NaN;
result.realtime_ratio     = NaN;
result.realtime_pass      = false;
result.target_tx_rate     = NaN;
result.sample_rate_hz     = NaN;
result.stage_io_ms        = NaN;
result.stage_beam_ms      = NaN;
result.stage_pdi_ms       = NaN;
result.stage_save_ms      = NaN;
result.stage_sum_ms       = NaN;
result.stage_mex_total_ms = NaN;
result.fits               = false;
result.skipped            = true;
result.mem_estimate       = NaN;
result.mem_available      = NaN;
end

function [RF, ProbeSpec, TransmitSpec, ReceiveSpec] = simulate_noise_rf(ProbeSpec, TransmitSpec, ReceiveSpec, nSamples_override)
% Fast stub for benchmarking: populates the fields simulate_logo_rf
% sets, but fills RF with int16 noise. Values are not physically meaningful;
% kernel timing is independent of the data.
%
% A spec set that came from a recording already carries the acquisition's own
% geometry, so this fills in gaps rather than overwriting. Every field it used
% to compute unconditionally is kept when the caller supplied one: nSamples,
% nChannels, the channel map, element positions and transmit delays. That
% matters because overwriting them benchmarked a configuration no probe runs --
% the GE9LD's 1152 x 256 became 832 x 192, 54% of the data volume, while the
% figure still called it GE9LD.
%
% Optional nSamples_override (post-resample, i.e. what ReceiveSpec.nSamples
% will end up as) still wins over both, so throughput mode can sweep the depth
% axis of any configuration.

if nargin < 4, nSamples_override = []; end

rng(0);

dt = 1 / ReceiveSpec.Fs;

% Pre/post-resample ratio and samples per wavelength for this sampling mode.
[mult, ReceiveSpec.samplesPerWavelength] = ...
    sampling_mode_factors(ReceiveSpec.samplingMode);

if ~isempty(nSamples_override)
    % Override is post-resample. Back-compute the pre-resample length so the
    % multiple-of-64 rule the acquisition imposes still holds.
    nRaw = nSamples_override * mult;
    if mod(nRaw, 64) ~= 0
        warning('simulate_noise_rf:nSamplesNotMultipleOf64', ...
                'nSamples override rounded to multiple of 64.');
        nRaw = floor(nRaw / 64) * 64;
    end
    ReceiveSpec.nSamples         = nRaw / mult;
    ReceiveSpec.startDepthMm     = 0;
    ReceiveSpec.actualEndDepthMm = ((nRaw-1) * dt / 2) * TransmitSpec.c0 * 1e3;
elseif isfield(ReceiveSpec, 'nSamples') && ~isempty(ReceiveSpec.nSamples)
    % A recording's own imaging depth. Its startDepthMm/actualEndDepthMm came
    % from the same acquisition, so they are left alone too.
    ReceiveSpec.nSamples = double(ReceiveSpec.nSamples);
else
    image_depth_physical = 50e-3;
    z_vec = 0:dt:(image_depth_physical * 2.5) / TransmitSpec.c0;
    nRaw  = floor(length(z_vec) / 64) * 64;
    ReceiveSpec.nSamples         = nRaw / mult;
    ReceiveSpec.startDepthMm     = 0;
    ReceiveSpec.actualEndDepthMm = ((nRaw-1) * dt / 2) * TransmitSpec.c0 * 1e3;
end

if ~isfield(ProbeSpec, 'elementPosition') || isempty(ProbeSpec.elementPosition) || ...
        size(ProbeSpec.elementPosition, 1) ~= ProbeSpec.nElements
    x_vec = (1:ProbeSpec.nElements) * ProbeSpec.pitch;
    x_vec = x_vec - mean(x_vec);
    ProbeSpec.elementPosition = [x_vec(:), zeros(ProbeSpec.nElements, 4)];
end

% nChannels is the RF array width, which is a system property, not a probe one:
% get_system_parameters gives a 192-element probe on a 256-channel Vantage 256
% channels, and channel2ElementMap says which of them carry elements. Only fall
% back to one column per element when the caller knows neither.
if ~isfield(ReceiveSpec, 'nChannels') || isempty(ReceiveSpec.nChannels)
    ReceiveSpec.nChannels = ProbeSpec.nElements;
end
if ~isfield(ReceiveSpec, 'channel2ElementMap') || isempty(ReceiveSpec.channel2ElementMap)
    ReceiveSpec.channel2ElementMap = (0:ProbeSpec.nElements-1)';
end

nRows = ReceiveSpec.nSamples * ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats;
rf_scale = 2^10;
% In row blocks. A probe configuration's RF is 590M elements, and one randn that
% size plus the scaled temporary is ~9 GB of doubles before anything is cast to
% int16 -- enough to swap on a machine that has the GPU for the run.
RF = zeros(nRows, ReceiveSpec.nChannels, 'int16');
rows_per_block = max(1, floor(4e7 / double(ReceiveSpec.nChannels)));
for r0 = 1:rows_per_block:nRows
    r1 = min(r0 + rows_per_block - 1, nRows);
    RF(r0:r1, :) = int16(randn(r1 - r0 + 1, ReceiveSpec.nChannels) * rf_scale);
end

% Recompute only when the delays cannot describe this transmit set -- a sweep
% that overrode nTX leaves a recording's table the wrong size.
if ~isfield(TransmitSpec, 'transmitDelays') || isempty(TransmitSpec.transmitDelays) || ...
        numel(TransmitSpec.transmitDelays) ~= ProbeSpec.nElements * ReceiveSpec.nTransmissions
    TransmitSpec.transmitDelays = zeros(ProbeSpec.nElements, 1, ReceiveSpec.nTransmissions);
    for i = 1:ReceiveSpec.nTransmissions
        delays = ProbeSpec.elementPosition(:,1) * tand(TransmitSpec.steer(i)) / TransmitSpec.c0;
        TransmitSpec.transmitDelays(:,1,i) = delays;
    end
end
end

function [mult, samplesPerWavelength] = sampling_mode_factors(mode)
% Ratio of pre- to post-resample sample count, and samples per wavelength.
switch mode
    case 'BS50BW'
        mult = 4; samplesPerWavelength = 1;
    case 'BS100BW'
        mult = 2; samplesPerWavelength = 2;
    case 'NS200BW'
        mult = 1; samplesPerWavelength = 4;
    case 'BS67BW'
        error('simulate_noise_rf:unsupportedMode', ...
              'Sampling mode ''BS67BW'' is not yet supported.');
    otherwise
        error('simulate_noise_rf:unknownMode', ...
              'Unknown samplingMode ''%s''.', mode);
end
end

function print_results(results)
fprintf('\n======== Benchmark Results ========\n');
fprintf('%-18s | nRepeats | nTX | PDI | SVD        | time ms | budget ms | ratio | PDI fps | BF fps   | real-time | fits\n', 'label');
fprintf('%s\n', repmat('-', 1, 133));
for i = 1:numel(results)
    result = results(i);
    if result.skipped
        fprintf('%-18s | %8d | %3d | %3s | %-10s | %7s | %9s | %5s | %7s | %8s | %9s | %s\n', ...
                result.label, result.nRepeats, result.nTX, ternary(result.getPDI,'on','off'), ...
                result.svdMethod, '-', '-', '-', '-', '-', '-', ternary(result.fits,'YES','NO'));
    else
        fprintf('%-18s | %8d | %3d | %3s | %-10s | %7.2f | %9.2f | %5.2f | %7.1f | %8.0f | %9s | %s\n', ...
                result.label, result.nRepeats, result.nTX, ternary(result.getPDI,'on','off'), ...
                result.svdMethod, ...
                result.time_ms, result.budget_ms, result.realtime_ratio, result.pdi_fps, result.bf_fps, ...
                ternary(result.realtime_pass,'YES','NO'), ternary(result.fits,'YES','NO'));
    end
end
fprintf('\n');
end

function plot_results(results, mode, target_tx_rate)
switch mode
    case 'fast'
        % One histogram per config: 'fast' runs more than one now, and only
        % plotting results(1) would drop the others without saying so.
        valid = results(~[results.skipped]);
        if isempty(valid), return; end
        figure('Name', 'EchoFrame benchmark (fast)');
        for i = 1:numel(valid)
            result = valid(i);
            subplot(1, numel(valid), i);
            histogram(result.latency_ms_all, 20);
            hold on;
            yl = ylim;
            plot([result.budget_ms result.budget_ms], yl, 'r--', 'LineWidth', 2);
            text(result.budget_ms, yl(2)*0.95, sprintf(' budget @ %g kHz = %.2f ms', ...
                target_tx_rate/1e3, result.budget_ms), 'Color', 'r');
            hold off;
            xlabel('Processing time per PDI [ms]');
            ylabel('Count');
            title(sprintf('%s | %.2f ms/PDI | ratio %.2f | BF %.0f fps | real-time: %s', ...
                result.label, result.time_ms, result.realtime_ratio, result.bf_fps, ...
                ternary(result.realtime_pass,'YES','NO')));
            grid on;
        end

    case 'throughput'
        plot_throughput(results);
        return;

    case 'elaborate'
        figure('Name', 'EchoFrame benchmark (elaborate)');

        % time vs nRepeats
        subplot(1, 3, 1);
        sel  = strcmp({results.axis}, 'nRepeats') & ~[results.skipped];
        rows = results(sel);
        plot([rows.nRepeats], [rows.time_ms], '-o', 'LineWidth', 1.5); hold on;
        plot([rows.nRepeats], [rows.budget_ms], '-s', 'LineWidth', 1.5);
        xlabel('nRepeats'); ylabel('time per PDI [ms]');
        title('nRepeats sweep'); legend('actual','budget','Location','best'); grid on;

        % time vs nTX
        subplot(1, 3, 2);
        sel  = strcmp({results.axis}, 'nTX') & ~[results.skipped];
        rows = results(sel);
        plot([rows.nTX], [rows.time_ms], '-o', 'LineWidth', 1.5); hold on;
        plot([rows.nTX], [rows.budget_ms], '-s', 'LineWidth', 1.5);
        xlabel('nTransmissions'); ylabel('time per PDI [ms]');
        title('nTX sweep'); legend('actual','budget','Location','best'); grid on;

        % PDI on/off
        subplot(1, 3, 3);
        sel  = strcmp({results.axis}, 'pdi') & ~[results.skipped];
        rows = results(sel);
        labels = arrayfun(@(r) ternary(r.getPDI,'on','off'), rows, 'UniformOutput', false);
        bar(categorical(labels, labels), [rows.time_ms]); hold on;
        yline(rows(1).budget_ms, 'r--', 'LineWidth', 2);
        ylabel('time per PDI [ms]'); title('PDI on/off'); grid on;
end
end

function plot_throughput(results)
% Throughput: GB/s vs nSamples, one line per nTX.
valid = results(~[results.skipped]);
if isempty(valid)
    warning('No valid configs to plot.'); return;
end

% The bandwidth in the labels is the receive mode the rows were measured in,
% not a constant: the sweep can be run in any of them.
bw = bandwidth_label(valid);

nTX_values = unique([valid.nTX]);
figure('Name', sprintf('EchoFrame benchmark (throughput, %s)', bw));
hold on;
for nTX = nTX_values
    sel  = [valid.nTX] == nTX;
    rows = valid(sel);
    [xs, order] = sort([rows.nSamples]);
    ys = [rows.gb_per_s];
    ys = ys(order);
    plot(xs, ys, '-o', 'LineWidth', 1.5, ...
         'DisplayName', sprintf('nTX = %d', nTX));
end
xlabel(sprintf('nSamples (post-resample, %s)', bw));
ylabel('RF input throughput [GB/s]');
title(sprintf('EchoFrame throughput vs. RF depth (%s)', bw));
legend('Location', 'best'); grid on;
end


function s = bandwidth_label(rows)
%BANDWIDTH_LABEL  The receive bandwidth these rows were measured at, as "100% BW".
%
% Falls back to the mode name when the rows disagree or predate samplingMode
% being recorded, rather than claiming a bandwidth none of them used.
s = 'mixed BW';
if ~isfield(rows, 'samplingMode'), return; end
modes = unique(cellstr(char(rows.samplingMode)));
if numel(modes) ~= 1, return; end
switch modes{1}
    case 'BS50BW',  s = '50% BW';
    case 'BS67BW',  s = '67% BW';
    case 'BS100BW', s = '100% BW';
    case 'NS200BW', s = '200% BW';
    otherwise,      s = modes{1};
end
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

function plot_stage_breakdown(results, target_tx_rate)
% One stacked tower per non-skipped config: IO / Beamforming / PDI / Saving in
% shades of one hue, darkest at the bottom. The stages are sequential inside a
% single process() call, so stacking them is what they actually are, and the
% tower height is stage_sum_ms by construction -- it needs no bar of its own.
%
% Budgets scale with nTX*nRepeats, so they differ between configs. Each tower
% gets a marker across its own width rather than the chart getting one line.

valid = results(~[results.skipped]);
if isempty(valid), return; end

stages = {'IO', 'Beamforming', 'PDI', 'Saving'};
shades = [0.05 0.28 0.45;
          0.16 0.44 0.64;
          0.35 0.60 0.79;
          0.62 0.78 0.90];
vals   = [ [valid.stage_io_ms]; [valid.stage_beam_ms];
           [valid.stage_pdi_ms]; [valid.stage_save_ms] ].';  % rows = configs

figure('Name', 'EchoFrame stage breakdown');
% x is passed explicitly: with one config vals is a single row, which bar()
% would otherwise read as four groups of one instead of one tower of four.
hb = bar(1:numel(valid), vals, 'stacked', 'BarWidth', 0.6);
for k = 1:numel(hb)
    hb(k).FaceColor   = shades(k, :);
    hb(k).EdgeColor   = 'none';
    hb(k).DisplayName = stages{k};
end
hold on;

% Budget across each tower, plus the tower total above it. Only the first
% budget line carries a legend entry; the rest are the same thing repeated.
halfBar = 0.30;
hBudget = gobjects(1, numel(valid));
for i = 1:numel(valid)
    hBudget(i) = plot([i-halfBar i+halfBar], ...
                      [valid(i).budget_ms valid(i).budget_ms], ...
                      'r--', 'LineWidth', 2);
    text(i, valid(i).stage_sum_ms, sprintf('%.2f ms', valid(i).stage_sum_ms), ...
         'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');
end
set(hBudget(2:end), 'HandleVisibility', 'off');
hBudget(1).DisplayName = sprintf('real-time budget @ %.0f kHz', target_tx_rate/1e3);

% Headroom for the totals, and for a budget that sits above the tallest tower.
ymax = max([valid.stage_sum_ms, valid.budget_ms]);
ylim([0, ymax * 1.15]);

set(gca, 'XTick', 1:numel(valid), ...
         'XTickLabel', {valid.label}, ...
         'XTickLabelRotation', 30);
legend([hb, hBudget(1)], 'Location', 'bestoutside');
ylabel('Time per PDI [ms]');
if isscalar(valid)
    title(sprintf('%s | real-time: %s (ratio %.2f)', valid.label, ...
                  ternary(valid.realtime_pass,'YES','NO'), valid.realtime_ratio));
else
    title(sprintf('Stage breakdown vs. real-time budget (target %.0f kHz)', ...
                  target_tx_rate/1e3));
end
grid on;
end

function launch_gpu_planner(target_tx_rate)
% Interactive GPU data-size planner ('plan' MODE). Sliders for the dimensions
% that drive data size and the cuFFT plan; live estimate via check_gpu_memory_fit
% plus the acquisition budget at target_tx_rate. Needs a display.

% Each row: field, label, [min max], default. All are integer-valued.
params = {
    'nSamplesIQ',     'Fast-time samples (nSamplesIQ)',   [128 4096], 512
    'nChannels',      'Channels (nChannels)',             [16  256],  128
    'nTransmissions', 'Transmit angles (nTransmissions)', [1   21],   3
    'nRepeats',       'Slow-time repeats (nRepeats)',     [10  400],  40
    'nz',             'Output voxels z (nz)',             [64  1024], 400
    'nx',             'Output voxels x (nx)',             [64  1024], 256
    'ensembleSize',   'PDI ensemble size',                [2   400],  40
    'shiftSize',      'PDI shift size',                   [1   400],  40
    };
nP = size(params, 1);

fig = uifigure('Name', 'EchoFrame GPU data-size planner', 'Position', [100 100 900 520]);
outer = uigridlayout(fig, [1 2]);
outer.ColumnWidth = {'1.1x', '1x'};

% ---- Left: sliders ----
left = uipanel(outer, 'Title', 'Dimensions');
lg = uigridlayout(left, [nP 3]);
lg.ColumnWidth = {'2x', '3x', 60};
lg.RowHeight = repmat({'fit'}, 1, nP);

sliders = struct();
for i = 1:nP
    field = params{i, 1};
    uilabel(lg, 'Text', params{i, 2});
    s = uislider(lg, 'Limits', params{i, 3}, 'Value', params{i, 4});
    vl = uilabel(lg, 'Text', num2str(params{i, 4}), 'HorizontalAlignment', 'right');
    % Update the value label live while dragging (cheap); recompute the estimate
    % only on release, so check_gpu_memory_fit's nvidia-smi call is not spawned
    % on every drag tick.
    s.ValueChangingFcn = @(~, ev) set(vl, 'Text', num2str(round(ev.Value)));
    s.ValueChangedFcn = @(~, ~) refresh();
    sliders.(field) = s;
end

% ---- Right: results ----
right = uigridlayout(outer, [3 1]);
right.RowHeight = {'fit', '1x', 'fit'};

status = uipanel(right, 'Title', 'Estimate');
sg = uigridlayout(status, [6 2]);
sg.ColumnWidth = {'1.5x', '1x'};
mkRow = @(name) deal(uilabel(sg, 'Text', name), ...
                     uilabel(sg, 'Text', '-', 'HorizontalAlignment', 'right'));
[~, lblEstimate]  = mkRow('Estimated peak (GB)');
[~, lblAvailable] = mkRow('Available VRAM (GB)');
[~, lblTotal]     = mkRow('Total VRAM (GB)');
[~, lblEns]       = mkRow('Derived nEnsembles');
[~, lblBudget]    = mkRow(sprintf('Acq budget @ %.0f kHz (ms)', target_tx_rate/1e3));
[~, lblFits]      = mkRow('Fits device');

ax = uiaxes(right);
title(ax, 'Per-buffer breakdown (GB)');
ax.XTickLabelRotation = 30;

suggest = uitextarea(right, 'Editable', 'off', 'Value', '');

refresh();

    function refresh()
        v = struct();
        for k = 1:nP
            f = params{k, 1};
            v.(f) = round(sliders.(f).Value);
        end

        ReceiveSpec = struct('nSamplesIQ', v.nSamplesIQ, 'nChannels', v.nChannels, ...
                             'nTransmissions', v.nTransmissions, 'nRepeats', v.nRepeats);
        ReconSpec = struct('nz', v.nz, 'nx', v.nx);
        PDISpec = struct('ensembleSize', v.ensembleSize, 'shiftSize', v.shiftSize);

        nEns = max(0, floor((v.nRepeats - v.ensembleSize) / v.shiftSize) + 1);
        lblEns.Text = num2str(nEns);
        lblBudget.Text = sprintf('%.2f', v.nTransmissions * v.nRepeats / target_tx_rate * 1e3);

        try
            [fits, info] = check_gpu_memory_fit(ReceiveSpec, ReconSpec, PDISpec);
        catch err
            [lblEstimate.Text, lblAvailable.Text, lblTotal.Text] = deal('-');
            lblFits.Text = 'GPU query failed';
            lblFits.FontColor = [0.6 0.6 0.6];
            cla(ax);
            suggest.Value = ['check_gpu_memory_fit error: ', err.message];
            return;
        end

        lblEstimate.Text  = sprintf('%.2f', info.estimated_bytes / 1e9);
        lblAvailable.Text = sprintf('%.2f', info.available_bytes / 1e9);
        lblTotal.Text     = sprintf('%.2f', info.total_bytes / 1e9);
        if fits
            lblFits.Text = 'YES'; lblFits.FontColor = [0 0.5 0];
        else
            lblFits.Text = 'NO';  lblFits.FontColor = [0.8 0 0];
        end

        fnames = fieldnames(info.breakdown);
        vals = cellfun(@(f) info.breakdown.(f) / 1e9, fnames);
        bar(ax, vals);
        ax.XTick = 1:numel(fnames);
        ax.XTickLabel = fnames;
        ylabel(ax, 'GB');
        title(ax, 'Per-buffer breakdown (GB)');

        if isempty(info.suggestions)
            suggest.Value = 'Fits comfortably.';
        else
            suggest.Value = info.suggestions;
        end
    end
end
