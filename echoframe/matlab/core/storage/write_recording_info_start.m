function write_recording_info_start(recordingDir, createdSerial)
%WRITE_RECORDING_INFO_START  Stamp a recording's start time into RecordingInfo.txt.
%
%  WRITE_RECORDING_INFO_START(recordingDir, createdSerial) writes a
%  RecordingInfo.txt in the recording folder recording the moment the folder
%  was created (createdSerial, a serial date number as returned by NOW). The
%  end time is filled in later by finalize_recording_info once acquisition
%  stops.
%
%  Called by init_storage right after it creates the recording folder, so the
%  start time is on disk even if the acquisition crashes before it finishes.
%
%  See also finalize_recording_info, init_storage.

if nargin < 2 || isempty(recordingDir) || ~isfolder(recordingDir)
    return;
end

fmt        = 'yyyy-MM-dd HH:mm:ss:SSS';   % millisecond resolution
createdDT  = datetime(createdSerial, 'ConvertFrom', 'datenum');
createdDT.Format = fmt;
infoPath   = fullfile(recordingDir, 'RecordingInfo.txt');

fid = fopen(infoPath, 'w');
if fid < 0
    warning('write_recording_info_start:open', 'Could not write %s.', infoPath);
    return;
end
cleanup = onCleanup(@() fclose(fid));

fprintf(fid, 'EchoFrame recording times\n');
fprintf(fid, '=========================\n');
fprintf(fid, 'Recording folder created : %s\n', char(createdDT));
fprintf(fid, 'Recording started        : (pending first write)\n');
fprintf(fid, 'Recording ended          : (in progress)\n');

end
