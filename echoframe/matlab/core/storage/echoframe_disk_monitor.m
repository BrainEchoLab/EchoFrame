function varargout = echoframe_disk_monitor(action, varargin)
%ECHOFRAME_DISK_MONITOR  Disk-space check + live disk-usage bar (self-contained).
%   All logic for the disk monitor lives in this one file: the pre-run
%   space check, the GUI bar (current usage + a projected-experiment overlay),
%   and the throttled refresh that runs from the same acquisition loop as the
%   EchoFrame timeline (ef_external_process).
%
%   The refresh is driven by the process loop (NOT a background timer): MATLAB
%   timers are not reliably serviced while VSX is running the acquisition
%   sequence. To stay off the EchoFrame hot path the refresh is self-throttled -
%   the java disk query runs at most once every UPDATE_PERIOD_S seconds, and each
%   refresh is timed into base vars diskBarUpdateTime / diskBarUpdateTimeMax [ms].
%
%   The bar shows two things:
%     * a solid fill  = disk currently used (green, red past 90%);
%     * a dashed orange outline = the space a new experiment would add on top of
%       current usage (based on the size recorded by the last 'check'). If the
%       outline runs off the right edge, the experiment will not fit.
%
% Call forms:
%   echoframe_disk_monitor('check', target_path, required_bytes)
%       Report free/total space, warn if it will not fit, and remember the size
%       and path for the live projection and for 'verify'.
%
%   echoframe_disk_monitor('start', target_path)
%       Add the disk-usage bar (current usage + projection) to the current figure
%       (subplot 4,4,16) and store its handles + the monitored path in base.
%
%   echoframe_disk_monitor('update')
%       Refresh the bar. Call once per acquisition from ef_external_process,
%       where the timeline plots are updated. Self-throttled.
%
%   [fits, msg] = echoframe_disk_monitor('verify')
%       Re-query free space and report whether the experiment sized by the last
%       'check' still fits. fits is true (msg '') when it fits or when no 'check'
%       has run. Used by the Store button before saving starts.

persistent last_required_bytes last_monitor_path

switch lower(char(action))
    case 'check'
        target_path         = varargin{1};
        required_bytes      = varargin{2};
        last_required_bytes = required_bytes;   % remembered for the projection + 'verify'
        last_monitor_path   = target_path;
        [free_bytes, total_bytes] = query_disk_space(target_path);
        fprintf('Disk %s: %.1f GB free of %.1f GB. Estimated recording size: %.1f GB.\n', ...
            char(target_path), free_bytes / 1e9, total_bytes / 1e9, required_bytes / 1e9);
        if required_bytes > free_bytes
            warning('EchoFrame:LowDiskSpace', ...
                ['Estimated recording size (%.1f GB) exceeds free disk space (%.1f GB) on %s. ', ...
                 'The acquisition may run out of space.'], ...
                required_bytes / 1e9, free_bytes / 1e9, char(target_path));
        end

    case 'start'
        target_path = varargin{1};
        subplot(4, 4, 16);
        disk_axes = gca;
        [free_bytes, total_bytes] = query_disk_space(target_path);
        used_pct = 100 * (1 - free_bytes / total_bytes);

        % Background (full capacity), current-usage fill, and projection overlay.
        patch(disk_axes, [0 100 100 0], [0 0 1 1], [0.90 0.90 0.90], 'EdgeColor', [0.5 0.5 0.5]);
        hold(disk_axes, 'on');
        disk_used_patch = patch(disk_axes, [0 used_pct used_pct 0], [0 0 1 1], ...
            [0.20 0.70 0.20], 'EdgeColor', 'none');
        disk_projected_patch = patch(disk_axes, 'XData', [NaN NaN NaN NaN], 'YData', [0 0 1 1], ...
            'FaceColor', 'none', 'EdgeColor', [1.00 0.55 0.00], 'LineStyle', '--', 'LineWidth', 1.5);
        disk_text = text(disk_axes, 50, 0.5, sprintf('%.1f GB free', free_bytes / 1e9), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'FontWeight', 'bold');
        xlim(disk_axes, [0 100]);
        ylim(disk_axes, [0 1]);
        disk_axes.YTick = [];
        xlabel(disk_axes, 'Disk used [%]');
        title(disk_axes, 'Disk space (orange = next experiment)');

        assignin('base', 'disk_used_patch', disk_used_patch);
        assignin('base', 'disk_projected_patch', disk_projected_patch);
        assignin('base', 'disk_text', disk_text);
        assignin('base', 'diskMonitorPath', target_path);

        % Draw the initial projection from the size recorded by 'check' (if any).
        update_projection(disk_projected_patch, used_pct, last_required_bytes, total_bytes);

    case 'update'
        throttled_refresh(last_required_bytes);

    case 'verify'
        if isempty(last_required_bytes) || isempty(last_monitor_path)
            varargout = {true, ''};   % no estimate recorded -> allow saving
            return;
        end
        [free_bytes, ~] = query_disk_space(last_monitor_path);
        fits = last_required_bytes <= free_bytes;
        if fits
            msg = '';
        else
            msg = sprintf(['Not enough disk space to store this experiment: needs %.1f GB but ', ...
                           'only %.1f GB is free on %s. Free up space before saving.'], ...
                           last_required_bytes / 1e9, free_bytes / 1e9, char(last_monitor_path));
        end
        varargout = {fits, msg};

    otherwise
        error('echoframe_disk_monitor:unknownAction', 'Unknown action "%s".', char(action));
end
end

% ============================= local helpers =============================

function throttled_refresh(required_bytes)
% Refresh the bar at most once every UPDATE_PERIOD_S seconds. Called every
% acquisition from the process loop; near-zero cost on throttled-out calls.
persistent last_tic update_time_max_ms
UPDATE_PERIOD_S = 2;

if isempty(last_tic)
    last_tic = tic;   % first call: prime and skip so the first frame is not slowed
    return;
end
if toc(last_tic) < UPDATE_PERIOD_S
    return;            % not time yet - only a toc() comparison was spent
end
last_tic = tic;

cost_tic = tic;
try
    disk_used_patch      = evalin('base', 'disk_used_patch');
    disk_projected_patch = evalin('base', 'disk_projected_patch');
    disk_text            = evalin('base', 'disk_text');
    monitor_path         = evalin('base', 'diskMonitorPath');
catch
    return;            % bar not set up (yet)
end
if ~isgraphics(disk_used_patch) || ~isgraphics(disk_text)
    return;            % figure/bar closed
end

[free_bytes, total_bytes] = query_disk_space(monitor_path);
used_pct = 100 * (1 - free_bytes / total_bytes);
set(disk_used_patch, 'XData', [0 used_pct used_pct 0]);
if used_pct > 90
    set(disk_used_patch, 'FaceColor', [0.85 0.20 0.20]);   % red when nearly full
else
    set(disk_used_patch, 'FaceColor', [0.20 0.70 0.20]);   % green otherwise
end
set(disk_text, 'String', sprintf('%.1f GB free', free_bytes / 1e9));
update_projection(disk_projected_patch, used_pct, required_bytes, total_bytes);

update_time_ms = toc(cost_tic) * 1e3;
if isempty(update_time_max_ms)
    update_time_max_ms = update_time_ms;
else
    update_time_max_ms = max(update_time_max_ms, update_time_ms);
end
assignin('base', 'diskBarUpdateTime', update_time_ms);
assignin('base', 'diskBarUpdateTimeMax', update_time_max_ms);
end

function update_projection(proj_patch, used_pct, required_bytes, total_bytes)
% Draw the projected-experiment overlay from used_pct to used_pct+experiment%.
if ~isgraphics(proj_patch)
    return;
end
if isempty(required_bytes) || required_bytes <= 0 || total_bytes <= 0
    set(proj_patch, 'XData', [NaN NaN NaN NaN]);   % nothing to project -> hide
    return;
end
projected_pct = 100 * required_bytes / total_bytes;
x0 = used_pct;
x1 = used_pct + projected_pct;   % may exceed 100; the axis clips it, showing "won't fit"
set(proj_patch, 'XData', [x0 x1 x1 x0]);
end

function [free_bytes, total_bytes] = query_disk_space(target_path)
% Free/total bytes of the volume holding target_path (java.io.File; Windows-safe).
check_path = char(target_path);
if numel(check_path) == 2 && check_path(2) == ':'
    check_path = [check_path filesep];   % normalise a bare drive letter 'C:'
end
while ~isempty(check_path) && ~isfolder(check_path)
    parent_path = fileparts(check_path);
    if strcmp(parent_path, check_path)
        break;
    end
    check_path = parent_path;
end
if isempty(check_path) || ~isfolder(check_path)
    check_path = pwd;
end
disk = java.io.File(check_path);
free_bytes  = double(disk.getUsableSpace());
total_bytes = double(disk.getTotalSpace());
end
