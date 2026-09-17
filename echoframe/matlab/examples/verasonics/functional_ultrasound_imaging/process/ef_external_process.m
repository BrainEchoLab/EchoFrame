function ef_external_process(RF)
% ef_external_process - Verasonics external-process callback for EchoFrame.
%
% Called by Verasonics for each RF buffer transferred from the host adapter.
% Forwards the RF to echoframe_mex and updates the live B-mode / PDI images and
% the acquisition timeline created by setup_echoframe_figure.m.
%
% BF / PDI / RF / RF-time-tag are all written by echoframe_mex itself when
% save_rf_pdi is true (their storage specs were passed to 'init'). The Store
% button in setup_echoframe_gui.m drives that flag; saving is off until pressed.
%
% Prints one timing line per frame against the acquisition period, and keeps the
% median loop period in EF_LOOP_MS for check_storage_headroom at teardown. The
% whole per-acquisition series goes to EF_TIMING_HISTORY, which outlives the
% scrolling timeline.

persistent pdiSaveCounter call_time frameIdx loopMs pdiStatusBar
persistent echoframeTimeArray vsxCallTimeArray acquisition_count timeXData
persistent histProcessingMs histLoopMs histSaving

timelineLength = evalin('base', 'EF_TIMELINE_ACQS');

if isempty(pdiSaveCounter)
    pdiSaveCounter     = 0;
    frameIdx           = 0;
    loopMs             = [];
    acquisition_count  = 0;
    echoframeTimeArray = nan(1, timelineLength);
    vsxCallTimeArray   = nan(1, timelineLength);
    timeXData          = 1:timelineLength;
    histProcessingMs   = [];
    histLoopMs         = [];
    histSaving         = [];
end
frameIdx = frameIdx + 1;

% Interval between consecutive callbacks: the whole acquisition loop, this
% processing included. NaN on the first frame, which has nothing to compare to.
if isempty(call_time)
    call_diff_ms = NaN;
else
    call_diff_ms = toc(call_time) * 1e3;
    loopMs(end+1) = call_diff_ms; %#ok<AGROW>
    % Median rather than the last value: the teardown headroom report compares
    % the worst write against this, and one slow frame should not skew it.
    assignin('base', 'EF_LOOP_MS', median(loopMs));
end

call_time = tic;

save_rf_pdi           = evalin('base', 'save_rf_pdi');
StorageSpec           = evalin('base', 'StorageSpec');
ExperimentSpec        = evalin('base', 'ExperimentSpec');
updateExperiment      = evalin('base', 'updateExperiment');
SVD_update_flag       = evalin('base', 'SVD_update_flag');
SVD_lower_update_flag = evalin('base', 'SVD_lower_update_flag');

%% Experiment progress, and the stop at numberOfPDIsExperiment
% Storage drops everything past numberOfPDIsExperiment. The counter resets
% whenever saving is off, so each Store press counts a fresh experiment.
if save_rf_pdi
    if pdiSaveCounter == 0
        fprintf('Experiment started storing: %d PDIs\n', ...
                ExperimentSpec.numberOfPDIsExperiment);
    end
    pdiSaveCounter = pdiSaveCounter + 1;

    % Progress dialog for the run.
    label = sprintf('Experiment Progress: %d/%d PDIs', pdiSaveCounter, ...
                    ExperimentSpec.numberOfPDIsExperiment);
    if isempty(pdiStatusBar) || ~isvalid(pdiStatusBar)
        pdiStatusBar = waitbar(0, label, 'Name', 'Experiment Progress');
    end
    waitbar(pdiSaveCounter / double(ExperimentSpec.numberOfPDIsExperiment), ...
            pdiStatusBar, label);
else
    pdiSaveCounter = 0;
    if ~isempty(pdiStatusBar) && isvalid(pdiStatusBar)
        close(pdiStatusBar);
        pdiStatusBar = [];
    end
end

% This frame is the last that fits, and is still saved; clearing the base flag
% stops the next callback.
if save_rf_pdi && pdiSaveCounter >= ExperimentSpec.numberOfPDIsExperiment
    fprintf('Experiment finished: stored %d PDIs\n', pdiSaveCounter);
    if ~isempty(pdiStatusBar) && isvalid(pdiStatusBar)
        close(pdiStatusBar);
        pdiStatusBar = [];
    end
    release_store_button();
end

%% Main MEX Processing
% The SVD sliders only raise a flag; the new threshold is applied here, on the
% processing thread, rather than from the GUI callback.
tic;
if SVD_update_flag
    SVD_threshold = single(evalin('base', 'SVD_threshold'));
    [PDI, Bmode] = echoframe_mex('updatePDIthreshold&process', RF, save_rf_pdi, ...
                                 SVD_threshold);
    assignin('base', 'SVD_update_flag', 0);
elseif SVD_lower_update_flag
    SVD_lower_threshold = single(evalin('base', 'SVD_lower_threshold'));
    [PDI, Bmode] = echoframe_mex('updatePDInoiseThreshold&process', RF, ...
                                 save_rf_pdi, SVD_lower_threshold);
    assignin('base', 'SVD_lower_update_flag', 0);
elseif updateExperiment
    % The Store button was switched off and on again: open a new recording
    % rather than write past the end of the one that was closed out.
    fprintf('New experiment initialized.\n');
    ReceiveSpec  = evalin('base', 'ReceiveSpec');
    ReconSpec    = evalin('base', 'ReconSpec');
    PDISpec      = evalin('base', 'PDISpec');
    TransmitSpec = evalin('base', 'TransmitSpec');
    ProbeSpec    = evalin('base', 'ProbeSpec');
    [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
        init_storage('re-init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                     ExperimentSpec, TransmitSpec, ProbeSpec);
    echoframe_mex('re-init experiment', BFStorageSpec, PDIStorageSpec, ...
                  RFTimeTagStorageSpec, RFStorageSpec, ReconSpec, PDISpec);
    [PDI, Bmode] = echoframe_mex('process', RF, save_rf_pdi);
    assignin('base', 'updateExperiment', 0);
    pdiSaveCounter = double(save_rf_pdi);   % fresh files, fresh allowance
    % init_storage stamps the new folder here.
    StorageSpec = evalin('base', 'StorageSpec');
else
    [PDI, Bmode] = echoframe_mex('process', RF, save_rf_pdi);
end
processing_ms = toc * 1e3;

%% Update RecordingInfo.txt start/end stamps from the save state (edge-driven)
track_recording_saving(StorageSpec.experimentStoragePath, save_rf_pdi);

%% Visualize C++ Bmode and PDI
Bmode = Bmode./max(Bmode(:));
Bmode = 20*log10(Bmode);

PDI = PDI./max(PDI(:));
PDI = 10*log10(PDI);

% Retrieve image handles from the base workspace
bmode_im = evalin('base', 'bmode_im');
pdi_im   = evalin('base', 'pdi_im');

% Update Figures
set(bmode_im, 'CData', Bmode);
set(pdi_im,   'CData', PDI);

%% Acquisition timeline
% Scrolls once it is full, so it always shows the most recent acquisitions.
acquisition_count = acquisition_count + 1;
echoframeTimePlot = evalin('base', 'echoframeTimePlot');
vsxCallTimePlot   = evalin('base', 'vsxCallTimePlot');
timing_axes       = evalin('base', 'timing_axes');

% call_diff_ms was measured at the top of this callback, so it is the period of
% the frame *before* this one. It goes against that frame, not this one, or the
% two traces describe different frames at the same x -- which showed up as a
% loop shorter than the processing it is supposed to contain.
if acquisition_count <= timelineLength
    echoframeTimeArray(acquisition_count) = processing_ms;
    vsxCallTimeArray(acquisition_count)   = NaN;   % filled in by the next callback
    if acquisition_count > 1
        vsxCallTimeArray(acquisition_count - 1) = call_diff_ms;
    end
else
    echoframeTimeArray = [echoframeTimeArray(2:end), processing_ms];
    vsxCallTimeArray   = [vsxCallTimeArray(2:end),   NaN];
    vsxCallTimeArray(end-1) = call_diff_ms;
    timeXData = timeXData + 1;
    set(timing_axes, 'XLim',  [timeXData(1), acquisition_count]);
    set(timing_axes, 'XTick', timeXData);
end

set(echoframeTimePlot, 'XData', timeXData, 'YData', echoframeTimeArray);
set(vsxCallTimePlot,   'XData', timeXData, 'YData', vsxCallTimeArray);

%% Whole-run timing history
% The timeline arrays above scroll, so they only ever hold the last
% timelineLength acquisitions. Keep the full series too, and publish it as
% EF_TIMING_HISTORY so it can be read from the base workspace once VSX returns.
% Same one-frame back-fill as the timeline above: this frame's loop period is
% not known until the next callback starts, so it goes in as NaN and the
% previous frame's is filled in now. The last frame keeps its NaN -- nothing
% ever measures it.
histProcessingMs(end+1) = processing_ms; %#ok<AGROW>
histLoopMs(end+1)       = NaN;           %#ok<AGROW>
histSaving(end+1)       = save_rf_pdi;   %#ok<AGROW>
if ~isnan(call_diff_ms)
    histLoopMs(end-1) = call_diff_ms;
end
assignin('base', 'EF_TIMING_HISTORY', ...
         struct('processing_ms', histProcessingMs, ...
                'loop_ms',       histLoopMs, ...
                'saving',        logical(histSaving), ...
                'loopAligned',   true));

%% Live disk-usage bar
% Same loop as the timeline; self-throttled, so this is not once per frame.
echoframe_disk_monitor('update');

drawnow limitrate; % Efficiently update figure window

%% Per-frame timing
% processing is this frame's MEX call; loop is callback-to-callback, which is
% what has to fit the acquisition period. The loop figure belongs to the
% previous frame -- it is only complete once this callback starts -- so it is
% printed against that frame's number. A ratio below 1 means it did not fit.
if ~isnan(call_diff_ms)
    states    = {'idle  ', 'SAVING'};
    budget_ms = evalin('base', 'EF_BUDGET_MS');
    ef_log('verbose', ...
           ['[ef] frame %4d | %s | processing %6.1f ms | frame %4d loop ' ...
            '%6.1f ms | budget %5.0f ms | x%.2f\n'], ...
           frameIdx, states{save_rf_pdi + 1}, processing_ms, frameIdx - 1, ...
           call_diff_ms, budget_ms, budget_ms / call_diff_ms);
    ef_log('trace', '%s', storage_trace_line(save_rf_pdi));
end

end

function s = storage_trace_line(saving)
%STORAGE_TRACE_LINE  Per-frame write instrumentation, for finding where a
%recording turns from keeping up to not.
%
% Only reached at EF_LOG_LEVEL=trace, because it adds a line per frame and calls
% into the MEX for stats the acquisition does not otherwise need. The caller
% gates it; this returns the text.
%
% The per-stream numbers the MEX keeps are cumulative over the recording, so
% what is printed is the DELTA since the previous frame: how much this frame
% waited for a write slot, and how many writes retired. That is the pair that
% separates the two stories. The loop stalling while writes keep retiring at
% the same rate means our queue is the limit; blocked and latency rising
% together while completions per frame fall means the writes themselves slowed.
%
% Resets when saving stops, so a second recording starts from zero the way the
% MEX's own counters do.
persistent prev
s = '';
if ~saving
    prev = [];
    return
end

try
    w = echoframe_mex('storage_stats');
catch
    return   % never let instrumentation break an acquisition
end

streams = {'rf', 'bf', 'pdi'};
now_v   = struct();
for k = 1:numel(streams)
    n = streams{k};
    if isfield(w, n)
        now_v.(n) = [w.(n).blockedTotalMs, double(w.(n).writes), ...
                     w.(n).latencyMeanMs, double(w.(n).peakInFlight)];
    end
end

if ~isempty(prev)
    parts = {};
    for k = 1:numel(streams)
        n = streams{k};
        if ~isfield(now_v, n) || ~isfield(prev, n), continue; end
        d = now_v.(n) - prev.(n);
        parts{end+1} = sprintf('%s blk %6.1f ms, +%d done, mean %6.1f, peak %d', ...
                               n, d(1), round(d(2)), now_v.(n)(3), now_v.(n)(4)); %#ok<AGROW>
    end
    % Free bytes on the volume, per frame. Cheap, and it is the one number that
    % separates "turns after N frames" from "turns at a fill level" without any
    % theory about why -- if the turn tracks this rather than the frame count,
    % that is visible in the trace itself.
    try
        root = evalin('base', 'StorageSpec.folderStoragePath');
        % getFreeSpace returns 0 for a path that does not resolve, so a zero is
        % "could not read it", not "the disk is full". Say nothing rather than
        % print a number that reads as the alarming case.
        free_gb = double(java.io.File(root).getFreeSpace()) / 1e9;
        if free_gb > 0
            parts{end+1} = sprintf('free %.0f GB', free_gb); %#ok<AGROW>
        end
    catch
        % Not worth failing a frame over.
    end

    if ~isempty(parts)
        s = sprintf('      [store] %s\n', strjoin(parts, ' | '));
    end
end
prev = now_v;
end


function release_store_button()
% Put the Store toggle back to NOT SAVING when the experiment ends by itself,
% so the button does not read SAVING while nothing is being written.
%
% The toggle is invoked with UIState 1 on purpose: that is what runs its
% updateStateSaveButton branch, which clears the button and marks the experiment
% for re-init. That path sets save_rf_pdi on the way through, so it has to be
% cleared afterwards -- clearing it first would simply be overwritten.
try
    storeButtonControl = evalin('base', 'storeButtonControl');
    assignin('base', 'updateStateSaveButton', 1);
    if isa(storeButtonControl.Callback, 'vsv.seq.function.ExFunctionDef') && ...
            isa(storeButtonControl.Callback.FunctionHandle, 'function_handle')
        feval(storeButtonControl.Callback.FunctionHandle, [], [], 1);
    end
catch
    % No GUI (headless or a caller that drives save_rf_pdi itself): nothing to
    % put back, and this must not take the acquisition down.
end
assignin('base', 'save_rf_pdi', false);
end
