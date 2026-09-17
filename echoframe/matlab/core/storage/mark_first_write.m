function mark_first_write(recordingDir)
%MARK_FIRST_WRITE  Stamp the moment the first sample was stored to disk.
% Called by track_recording_saving (rising edge) and by generate_echoframe_demo_data / batch_demo_data.
%
%  MARK_FIRST_WRITE(recordingDir) fills in the "Recording started" line of the
%  recording's RecordingInfo.txt with the current time, the first time it is
%  called for that recording. Later calls for the same recording return
%  immediately, so it is cheap to call from a per-frame acquisition callback --
%  it does file I/O only once per recording.
%
%  This captures when data actually began to be written, which can be well
%  after the folder was created (e.g. in the clinic path the operator presses a
%  Store button some time into the session). init_storage stamps the
%  folder-creation time; finalize_recording_info stamps the end time.
%
%  The per-recording guard is keyed on recordingDir, so starting a new
%  recording (a new folder) automatically re-arms the stamp.
%
%  See also write_recording_info_start, finalize_recording_info, init_storage.

persistent stampedDir

if nargin < 1 || isempty(recordingDir) || ~isfolder(recordingDir)
    return;
end
if ischar(stampedDir) && strcmp(stampedDir, recordingDir)
    return;   % already stamped this recording
end

infoPath = fullfile(recordingDir, 'RecordingInfo.txt');
if exist(infoPath, 'file') ~= 2
    return;   % no start stamp to update; leave it to finalize
end

fmt        = 'yyyy-MM-dd HH:mm:ss:SSS';   % millisecond resolution
startedDT  = datetime('now');
startedDT.Format = fmt;
newLine    = ['Recording started        : ', char(startedDT)];

txt  = fileread(infoPath);
txt2 = regexprep(txt, 'Recording started\s*:[^\r\n]*', newLine, 'once');
if strcmp(txt2, txt)
    % No "Recording started" line present -> insert it after the
    % "Recording folder created" line.
    txt2 = regexprep(txt, '(Recording folder created[^\r\n]*\r?\n)', ...
                     ['$1', newLine, char(10)], 'once'); %#ok<CHARTEN>
end

fid = fopen(infoPath, 'w');
if fid < 0
    return;   % best effort; finalize will still record created + ended
end
cleanup = onCleanup(@() fclose(fid));
fwrite(fid, txt2);          % byte-exact rewrite, preserves existing newlines

stampedDir = recordingDir;

end
