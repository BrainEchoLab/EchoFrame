function varargout = ef_log(level, fmt, varargin)
%EF_LOG  Print a line only when EF_LOG_LEVEL asks for it.
%
%   EF_LOG(LEVEL, FMT, ...) prints like fprintf when the current level is at
%   least LEVEL, and does nothing otherwise.
%
%   LVL = EF_LOG() returns the current level without printing.
%
%   LEVEL is a name or a number, and matches the C++ side (write_stats.h):
%
%     'quiet'   0   warnings and errors only
%     'normal'  1   + banners and end-of-recording summaries   (default)
%     'verbose' 2   + one line per acquisition frame
%     'trace'   3   + per-stage timings and per-frame storage deltas
%
%   Set it with setenv('EF_LOG_LEVEL', 'verbose'). One variable covers both
%   sides: the MATLAB prints checked here and the C++ banners and timings.
%
%   Both sides read it live. This function reads it per call, and the MEX reads
%   it at the top of every dispatch, so changing the level mid-session takes
%   effect on the next print from either -- no re-init needed.
%
%   That symmetry is the point: raising the level mid-session to chase a
%   problem has to move both halves of the log, or it moves neither usefully.
%   The storage knobs (EF_STORAGE_VERIFY/_PROBES/_DELAY_WRITE_MS/_STATS) latch
%   at init instead, because those configure a recording that is already open.

names = {'quiet', 'normal', 'verbose', 'trace'};

raw = getenv('EF_LOG_LEVEL');
if isempty(raw)
    current = 1;                                  % normal
else
    idx = find(strncmpi(raw, names, 1), 1);       % first letter is enough
    if ~isempty(idx)
        current = idx - 1;
    elseif isempty(regexp(raw, '^\s*[+-]?\d+\s*$', 'once'))
        current = 1;                              % unreadable value is not a reason to go silent
    else
        % A plain decimal integer only, matching what the C++ side accepts:
        % strtol with nothing but whitespace after the digits. str2double on its
        % own would also take '0x2' and '3.0', which C++ rejects, and one
        % variable must not mean two different things across the two sides.
        n = str2double(raw);
        if n >= 0 && n <= 3
            current = n;
        else
            current = 1;                          % out of range
        end
    end
end

if nargin == 0
    varargout{1} = current;
    return
end
varargout = {};

if nargin < 2
    % Checked before the gate, so a malformed call fails the same way whatever
    % the level happens to be, instead of only once someone turns prints up.
    error('ef_log:noFormat', 'ef_log needs a format string after the level.');
end

% Anything this does not recognise as a level prints at normal rather than
% vanishing: a caller's typo should be loud, not silent. Unchecked, ef_log([])
% and ef_log(NaN) drop the line at every level, and a cell or struct throws from
% the comparison rather than saying anything useful.
want = 1;
if isstring(level) && isscalar(level) && ~ismissing(level)
    level = char(level);
end
if ischar(level)
    idx = find(strncmpi(level, names, 1), 1);
    if ~isempty(idx)
        want = idx - 1;
    end
elseif isnumeric(level) && isscalar(level) && isfinite(level) && ...
       level == fix(level) && level >= 0 && level <= 3
    want = double(level);
end

if current >= want
    fprintf(fmt, varargin{:});
end
end
