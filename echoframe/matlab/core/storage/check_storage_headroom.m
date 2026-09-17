function report = check_storage_headroom(loopPeriodMs, ReceiveSpec, stats)
%CHECK_STORAGE_HEADROOM  Report whether the storage write queues were deep enough.
%
%  REPORT = CHECK_STORAGE_HEADROOM() reads the write instrumentation collected
%  by echoframe_mex during the run and prints a per-stream verdict.
%
%  REPORT = CHECK_STORAGE_HEADROOM(LOOPPERIODMS) also compares the worst RF
%  write against how long the acquisition ring takes to wrap. LOOPPERIODMS is
%  the measured wall-clock period of one acquisition frame.
%
%  REPORT = CHECK_STORAGE_HEADROOM(LOOPPERIODMS, ReceiveSpec) takes the ring
%  depth from ReceiveSpec.nBuffers.
%
%  REPORT = CHECK_STORAGE_HEADROOM(LOOPPERIODMS, ReceiveSpec, STATS) reports on
%  a stats struct captured earlier with echoframe_mex('storage_stats'), for
%  callers that have already destroyed the MEX instance.
%
%  Fields per stream::
%
%    latencyMaxMs    worst time from handing a buffer to storage to the write
%                    completing; how long the source must stay untouched. The
%                    bf_storage / pdi_storage stage timings are queueing time
%                    and do not measure this.
%    peakInFlight    most writes outstanding at once
%    queueCapacity   numberOfBuffers-1, the most that may be outstanding
%    blockedTotalMs  time storeBuffer spent waiting for a free slot
%    corrupted       records whose source changed mid-write; only counted when
%                    EF_STORAGE_VERIFY=1 was set
%
%  A queue that reaches capacity and blocks means the drive cannot keep ahead
%  at this depth. Raise ReceiveSpec.nBuffers and the storage depth together --
%  the queue must not exceed the ring, or a buffer can be overwritten while it
%  is still being written.
%
%  See also INIT_STORAGE.

if nargin < 1, loopPeriodMs = []; end
if nargin < 2, ReceiveSpec = []; end
if nargin < 3 || isempty(stats)
    stats = echoframe_mex('storage_stats');
end
report = stats;

ringDepth = [];
if ~isempty(ReceiveSpec) && isfield(ReceiveSpec, 'nBuffers')
    ringDepth = double(ReceiveSpec.nBuffers);
end

% Waiting is expected while writes are being held back on purpose.
held = ~isempty(getenv('EF_STORAGE_DELAY_WRITE_MS')) && ...
       str2double(getenv('EF_STORAGE_DELAY_WRITE_MS')) > 0;

fprintf('\n=== Storage write headroom ===\n');

names = {'rf', 'bf', 'pdi', 'timetag'};
for i = 1:numel(names)
    s = stats.(names{i});
    if ~s.saving || s.writes == 0
        fprintf('  %-8s not saving\n', names{i});
        continue;
    end

    fprintf(['  %-8s %5d writes | latency mean %7.2f ms, max %7.2f ms | ' ...
             'peak %d/%d in flight\n'], ...
            names{i}, s.writes, s.latencyMeanMs, s.latencyMaxMs, ...
            s.peakInFlight, s.queueCapacity);

    % A queue that touches capacity always waits a little; that is the queue
    % working, not the drive failing. Only call it saturated when the waiting is
    % a real share of the frame period.
    saturated  = s.peakInFlight >= s.queueCapacity;
    perFrameMs = s.blockedTotalMs / max(double(s.writes), 1);
    if ~isempty(loopPeriodMs) && loopPeriodMs > 0
        limitMs = 0.05 * loopPeriodMs;      % 5% of the frame period
    else
        limitMs = 10;                       % no period given; absolute fallback
    end

    if saturated && perFrameMs > limitMs
        fprintf(2, ['           QUEUE SATURATED: blocked %.2f ms per frame ' ...
                    '(%.1f ms total, %.1f ms worst).\n'], ...
                perFrameMs, s.blockedTotalMs, s.blockedMaxMs);
        if held
            fprintf(2, ['           EF_STORAGE_DELAY_WRITE_MS is set, so this ' ...
                        'is the injected delay, not the drive.\n']);
        else
            fprintf(2, ['           The drive is not keeping ahead at this ' ...
                        'depth. Raise ReceiveSpec.nBuffers and the storage\n' ...
                        '           depth together, or reduce the data rate. ' ...
                        'The recording is intact -- this is back-pressure.\n']);
        end
    elseif saturated
        fprintf(['           queue reached capacity; waits are %.2f ms per ' ...
                 'frame, not limiting.\n'], perFrameMs);
    else
        fprintf('           depth is more than enough (queue never filled).\n');
    end

    if s.verified > 0
        if s.corrupted > 0
            fprintf(2, ['           CORRUPTION: %d of %d verified writes had ' ...
                        'their source overwritten in flight.\n'], ...
                    s.corrupted, s.verified);
        else
            fprintf('           verified %d writes, none corrupted.\n', ...
                    s.verified);
        end
    end
end

% Only meaningful for RF, which is the stream the acquisition ring protects.
if ~isempty(loopPeriodMs) && stats.rf.saving && stats.rf.writes > 0
    if isempty(ringDepth)
        fprintf(['\n  Ring wrap margin needs ReceiveSpec.nBuffers; pass ' ...
                 'ReceiveSpec as the second argument.\n']);
    else
        wrapMs = ringDepth * loopPeriodMs;
        margin = wrapMs / max(stats.rf.latencyMaxMs, eps);
        fprintf(['\n  RF ring wrap margin: worst write %.1f ms against a ' ...
                 '%.0f ms wrap (%d frames x %.1f ms) = %.1fx\n'], ...
                stats.rf.latencyMaxMs, wrapMs, ringDepth, loopPeriodMs, margin);
        if margin < 2
            fprintf(2, ['  [WARN] under 2x. This configuration is at the edge ' ...
                        'of what the drive sustains; expect\n         ' ...
                        'back-pressure on any slowdown.\n']);
        end
    end
end

fprintf('\n');
end
