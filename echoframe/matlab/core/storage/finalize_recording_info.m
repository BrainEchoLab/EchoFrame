function finalize_recording_info(recordingDir)
%FINALIZE_RECORDING_INFO  Record when a recording ended into RecordingInfo.txt.
% Called by track_recording_saving (falling edge) and by the acquisition scripts at exit.
%
%  FINALIZE_RECORDING_INFO(recordingDir) rewrites RecordingInfo.txt in the
%  recording folder with:
%     - when the folder was created (from the start stamp init_storage wrote,
%       or the folder name as a fallback),
%     - when recording started -- the first sample stored, stamped by
%       mark_first_write ("(not recorded)" if no data was ever written),
%     - when recording ended -- the RF data write time (rf_acq.dat), the
%       primary recording; falls back to the latest other data file, then the
%       current time, if RF was not saved. Stamped once, then left unchanged,
%     - the recording duration (started -> ended, or created -> ended if the
%       first-write stamp is missing),
%     - the actual last-write time of each data file (bf_acq / rf_acq /
%       pdi_acq / rfTimeTag_acq) -- i.e. when samples were physically stored,
%       the timing that until now was only visible as the file's modified date.
%
%  Call it once acquisition has stopped and the MEX has been cleared (so the
%  data files are flushed and their headers written). It does nothing if the
%  folder no longer exists -- e.g. an empty recording that clean_empty_files
%  removed -- so it is safe to call unconditionally at the end of a script.
%
%  See also write_recording_info_start, init_storage, clean_empty_files.

if nargin < 1 || isempty(recordingDir) || ~isfolder(recordingDir)
    return;
end

fmt      = 'yyyy-MM-dd HH:mm:ss:SSS';   % millisecond resolution
infoPath = fullfile(recordingDir, 'RecordingInfo.txt');

% --- Idempotent: if the end has already been stamped, leave the file untouched ---
if ~isempty(local_read_field(infoPath, 'Recording ended', fmt))
    return;
end

% --- Recover folder-creation time: from the start stamp, else the folder name ---
createdDT = local_read_field(infoPath, 'Recording folder created', fmt);
if isempty(createdDT)
    createdDT = local_parse_folder_name(recordingDir, fmt);
end

% --- Recover first-write time (stamped by mark_first_write, if any) ---
startedDT = local_read_field(infoPath, 'Recording started', fmt);

% --- Actual data-write times (file last-modified), via Java lastModified at
%     millisecond resolution ---
dataFiles = {'bf_acq.dat', 'rf_acq.dat', 'pdi_acq.dat', 'rfTimeTag_acq.dat'};
names     = {};
times     = datetime.empty;
for k = 1:numel(dataFiles)
    t = local_file_mtime(fullfile(recordingDir, dataFiles{k}), fmt);
    if ~isempty(t)
        names{end+1} = dataFiles{k};   %#ok<AGROW>
        times(end+1) = t;              %#ok<AGROW>
    end
end
if ~isempty(times)
    times.Format = fmt;
end

% --- End time = the RF data write (rf_acq.dat). RF is the primary recording,
%     so "ended" tracks its last write. Fall back to the latest of the other
%     data files, then the current time, when RF was not saved. ---
rfIdx = find(strcmp(names, 'rf_acq.dat'), 1);
if ~isempty(rfIdx)
    endDT = times(rfIdx);
elseif ~isempty(times)
    endDT = max(times);
else
    endDT = datetime('now');
end
endDT.Format = fmt;

% --- Rewrite the file, start stamp through end stamp ---
fid = fopen(infoPath, 'w');
if fid < 0
    warning('finalize_recording_info:open', 'Could not write %s.', infoPath);
    return;
end
cleanup = onCleanup(@() fclose(fid));

fprintf(fid, 'EchoFrame recording times\n');
fprintf(fid, '=========================\n');
if ~isempty(createdDT)
    fprintf(fid, 'Recording folder created : %s\n', char(createdDT));
else
    fprintf(fid, 'Recording folder created : (unknown)\n');
end
if ~isempty(startedDT)
    fprintf(fid, 'Recording started        : %s\n', char(startedDT));
else
    fprintf(fid, 'Recording started        : (not recorded)\n');
end
fprintf(fid, 'Recording ended          : %s\n', char(endDT));

% Duration is measured from the first sample stored when we have it, otherwise
% from folder creation.
if ~isempty(startedDT)
    durFrom = startedDT;
else
    durFrom = createdDT;
end
if ~isempty(durFrom)
    durSecs = seconds(endDT - durFrom);
    fprintf(fid, 'Recording duration       : %s  (%.3f s)\n', ...
            local_hms(floor(durSecs)), durSecs);
end
fprintf(fid, '\n');
fprintf(fid, 'Data files (last write = when samples were actually stored):\n');
if isempty(names)
    fprintf(fid, '  (no data files found)\n');
else
    for k = 1:numel(names)
        fprintf(fid, '  %-18s : %s\n', names{k}, char(times(k)));
    end
end
fprintf(fid, '\n');
fprintf(fid, '("created" = folder made; "started" = first sample stored;\n');
fprintf(fid, ' "ended" = RF data (rf_acq.dat) last write; duration is\n');
fprintf(fid, ' started -> ended.)\n');

end

% -------------------------------------------------------------------------

function dt = local_read_field(infoPath, label, fmt)
% Read a "<label> : <timestamp>" line from an existing RecordingInfo.txt.
% Returns an empty datetime if the file, the line, or a valid timestamp is
% absent (e.g. a "(pending first write)" placeholder does not parse).
dt = datetime.empty;
if exist(infoPath, 'file') ~= 2
    return;
end
txt = fileread(infoPath);
tok = regexp(txt, [regexptranslate('escape', label), ...
                   '\s*:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?::\d{3})?)'], ...
             'tokens', 'once');
if isempty(tok)
    return;   % line absent, or a "(pending)"/"(in progress)" placeholder
end
% The stamps use a colon before the milliseconds (HH:mm:ss:SSS) for display, but
% datetime only parses a decimal there, so normalise ss:SSS -> ss.SSS first.
raw = regexprep(strtrim(tok{1}), ':(\d{3})$', '.$1');
if contains(raw, '.')
    inFmt = 'yyyy-MM-dd HH:mm:ss.SSS';
else
    inFmt = 'yyyy-MM-dd HH:mm:ss';
end
try
    dt = datetime(raw, 'InputFormat', inFmt, 'Format', fmt);
    if isnat(dt)
        dt = datetime.empty;
    end
catch
    dt = datetime.empty;
end
end

% -------------------------------------------------------------------------

function dt = local_parse_folder_name(recordingDir, fmt)
% Fallback: pull the timestamp out of a recording_YYYY-mm-DD_HHMMSS folder name.
dt = datetime.empty;
rd = recordingDir;
if endsWith(rd, {'\', '/'})
    rd = rd(1:end-1);
end
[~, name] = fileparts(rd);
tok = regexp(name, 'recording_(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2})', ...
             'tokens', 'once');
if isempty(tok)
    return;
end
v = str2double(tok);
try
    dt = datetime(v(1), v(2), v(3), v(4), v(5), v(6), 'Format', fmt);
catch
    dt = datetime.empty;
end
end

% -------------------------------------------------------------------------

function s = local_hms(secs)
% Format a non-negative second count as HH:MM:SS.
secs = max(0, secs);
hh   = floor(secs / 3600);
mm   = floor(mod(secs, 3600) / 60);
ss   = mod(secs, 60);
s    = sprintf('%02d:%02d:%02d', hh, mm, ss);
end

% -------------------------------------------------------------------------

function dt = local_file_mtime(filepath, fmt)
% Last-modified time of a file at millisecond resolution. Uses Java's
% lastModified (ms since the epoch); dir()'s datenum is only second-resolution.
% Returns an empty datetime if the file is absent or the query fails.
dt = datetime.empty;
try
    jf = java.io.File(filepath);
    if ~jf.exists()
        return;
    end
    ms = double(jf.lastModified());              % ms since 1970-01-01 UTC
    if ms <= 0
        return;
    end
    dt = datetime(ms / 1000, 'ConvertFrom', 'posixtime', 'TimeZone', 'local');
    dt.TimeZone = '';                            % local wall clock, matches now()
    dt.Format   = fmt;
catch
    dt = datetime.empty;
end
end
