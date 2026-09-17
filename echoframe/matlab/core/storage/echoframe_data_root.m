function root = echoframe_data_root()
%ECHOFRAME_DATA_ROOT  Where this machine puts EchoFrame data.
%
%  ROOT = ECHOFRAME_DATA_ROOT() returns the folder that recordings, benchmark
%  output and generated test data should be written under. One answer for
%  everything that writes, so a machine is configured in one place rather than
%  in a dozen scripts.
%
%  Resolved in order:
%
%    1. the EF_DATA_ROOT environment variable, when it names a folder
%    2. D:\EchoFrameData, the conventional data drive
%    3. tempdir, so a machine with neither still runs
%
%  RF buffers are why this matters: a probe configuration writes over a
%  gigabyte per frame, which a system drive does not hold for long. The
%  fallback keeps the small configurations working on a developer machine.
%
%  See also INIT_STORAGE, ECHOFRAME_DISK_MONITOR.

candidates = {getenv('EF_DATA_ROOT'), 'D:\EchoFrameData'};
for k = 1:numel(candidates)
    c = candidates{k};
    if isempty(c), continue; end
    c = regexprep(strtrim(c), '[\\/]+$', '');
    if isfolder(c)
        root = c;
        return;
    end
    % EF_DATA_ROOT is a deliberate choice, so create it rather than skipping.
    if k == 1
        [made, ~, ~] = mkdir(c);
        if made
            root = c;
            return;
        end
    end
end
root = tempdir;
end
