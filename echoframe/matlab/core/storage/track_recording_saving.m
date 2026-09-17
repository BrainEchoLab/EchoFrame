function track_recording_saving(recordingDir, isSaving)
%TRACK_RECORDING_SAVING  Drive RecordingInfo.txt start/end stamps from the save state.
% Called once per acquisition frame by the Verasonics external-process callback
% (ef_external_process.m).
%
%  TRACK_RECORDING_SAVING(recordingDir, isSaving) is meant to be called once per
%  acquisition frame with the current recording folder and whether data is being
%  saved this frame. It stamps:
%     - "Recording started" on the rising edge (first frame saving begins), via
%       mark_first_write, and
%     - "Recording ended" on the falling edge (saving stops), via
%       finalize_recording_info.
%
%  It also closes out the previous recording when the folder changes while
%  saving is still on (e.g. the clinic 're-init experiment' path starts a new
%  recording folder). File I/O happens only on these edges, so it is cheap to
%  call every frame.
%
%  This is what makes "Recording ended" reliable: it is written the moment the
%  acquisition stops, from inside the live callback -- not only at script exit,
%  which may never run if the VSX window is closed or an error is thrown.
%
%  See also mark_first_write, finalize_recording_info, init_storage.

persistent activeDir

if nargin < 2 || isempty(recordingDir)
    return;
end

if isSaving
    % Rising edge, or a switch to a new recording folder while still saving.
    % Do the filesystem work (mark_first_write / finalize_recording_info) only
    % on this edge; steady-state saving does only a strcmp.
    if isempty(activeDir) || ~strcmp(activeDir, recordingDir)
        if ~isempty(activeDir)
            finalize_recording_info(activeDir);   % close out the previous one
        end
        activeDir = recordingDir;
        mark_first_write(recordingDir);           % stamp first write once
    end
else
    % Falling edge: saving just stopped -> stamp the end of the active recording.
    if ~isempty(activeDir)
        finalize_recording_info(activeDir);
        activeDir = '';
    end
end

end
