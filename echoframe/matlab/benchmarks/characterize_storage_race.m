% characterize_storage_race - At what frame rate does the storage race stop biting?
%
% MUST be run against a build WITHOUT the producer slot-ring fix; against a fixed
% build every row reads 0 corrupt (it will say so).
%
% A stored buffer is corrupt when the buffer is refilled before its write drains, so
% the governing quantity is the inter-frame period, not processing speed alone. This
% sweeps a pause between frames from 0 upward and counts stored buffers that disagree
% with what process() returned. The smallest pause with zero corruption is the slack
% the write needs, reported as a frame period and rate.
%
% Machine- and drive-specific: it scales with buffer size and inversely with write
% throughput.
%
% Env knobs:
%   EF_CHAR_FRAMES    frames per run (default 12)
%   EF_CHAR_REPEATS   repeats per pause value (default 2; the race is probabilistic)
%   EF_CHAR_PAUSES    comma-separated pause values in ms (default 0,1,2,5,10,20,50,100)
%   EF_CHAR_EXTRA_Z / EF_CHAR_EXTRA_X   grid padding (default 0 / 128)
%
% Prereq: ECHOFRAME_PATH; a PRE-FIX echoframe_mex (pin with MEX_DIR); GPU.
% On Windows must run ELEVATED.
%
% Usage: run

clear; close all; clear mex;

ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);
if ~isempty(getenv('MEX_DIR'))
    addpath(getenv('MEX_DIR'));
end
fprintf('echoframe_mex: %s\n', which('echoframe_mex'));

nFrames  = envnum('EF_CHAR_FRAMES', 12);
nRepeats = envnum('EF_CHAR_REPEATS', 2);
pausesMs = envlist('EF_CHAR_PAUSES', [0 1 2 5 10 20 50 100]);

out_root = fullfile(echoframe_data_root(), 'echoframe_char_race');
if exist(out_root, 'dir'); rmdir(out_root, 's'); end
mkdir(out_root);

%% Specs
ProbeSpec.pitch          = 300e-6;
ProbeSpec.Fc             = 5e6;
ProbeSpec.nElements      = 128;

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = [-10 0 10];
TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);

ReceiveSpec.nRepeats       = 40;
ReceiveSpec.Fs             = 20e6;
ReceiveSpec.nTransmissions = numel(TransmitSpec.steer);
ReceiveSpec.samplingMode   = 'BS100BW';
ReceiveSpec.nBuffers       = 1;

ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(true);
ReconSpec.extraVoxelsZ      = envnum('EF_CHAR_EXTRA_Z', 0);
ReconSpec.extraVoxelsX      = envnum('EF_CHAR_EXTRA_X', 128);
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = int32([0;1;0;1]);

PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

nz = double(ReconSpec.nz);
nx = double(ReconSpec.nx);
nRep = double(ReceiveSpec.nRepeats);
bfMB = nz * nx * nRep * 8 / 2^20;

fprintf('Grid nz=%d nx=%d nRep=%d | BF buffer %.1f MB | %d frames x %d repeats per pause\n', ...
        nz, nx, nRep, bfMB, nFrames, nRepeats);

RFs = cell(1, nFrames);
for k = 1:nFrames
    RFs{k} = circshift(RF, 7 * (k - 1), 1);
end

%% Sweep
rows = struct('pauseMs', {}, 'corrupt', {}, 'total', {}, 'procMs', {}, 'storeMs', {});
fprintf('\n%8s %10s %12s %12s %12s\n', 'pause', 'corrupt', 'of total', 'proc/frame', 'bfStore/frm');
fprintf('%s\n', repmat('-', 1, 60));

for pi = 1:numel(pausesMs)
    p = pausesMs(pi);
    corruptTotal = 0;
    bufTotal = 0;
    procAll = [];
    storeAll = [];

    for r = 1:nRepeats
        folder = fullfile(out_root, sprintf('p%g_r%d', p, r));
        res = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                       RFs, folder, p / 1000);
        corruptTotal = corruptTotal + res.corrupt;
        bufTotal     = bufTotal + res.total;
        procAll      = [procAll  res.procMs];  %#ok<AGROW>
        storeAll     = [storeAll res.storeMs]; %#ok<AGROW>
    end

    rows(end+1) = struct('pauseMs', p, 'corrupt', corruptTotal, 'total', bufTotal, ...
                         'procMs', mean(procAll), 'storeMs', mean(storeAll)); %#ok<AGROW>
    fprintf('%6g ms %10d %12d %10.1f ms %10.1f ms\n', ...
            p, corruptTotal, bufTotal, mean(procAll), mean(storeAll));
end

% Test output, above the verdict because that returns early on two paths.
% run_once drops each recording as it reads it, so this is the empty parent.
echoframe_cleanup_dir(out_root);

%% Verdict
fprintf('\n');
anyCorrupt = any([rows.corrupt] > 0);
if ~anyCorrupt
    fprintf(['NO CORRUPTION AT ANY PAUSE.\n' ...
             'Either this is a FIXED build (check the MEX path above -- then this sweep\n' ...
             'is measuring nothing), or the race did not reproduce on this machine at\n' ...
             'this grid size. Raise EF_CHAR_EXTRA_X/Z, EF_CHAR_FRAMES, or add competing\n' ...
             'disk I/O, and re-run.\n']);
    return;
end

% Threshold: smallest pause at and above which every larger pause is also clean.
thresholdIdx = NaN;
for i = numel(rows):-1:1
    if rows(i).corrupt > 0
        thresholdIdx = i + 1;
        break;
    end
end

if isnan(thresholdIdx) || thresholdIdx > numel(rows)
    fprintf(['STILL CORRUPTING AT THE LARGEST PAUSE TESTED (%g ms).\n' ...
             'The safe frame period is above the swept range -- extend EF_CHAR_PAUSES.\n'], ...
            rows(end).pauseMs);
    return;
end

thr    = rows(thresholdIdx).pauseMs;
lastBad = rows(thresholdIdx - 1).pauseMs;
procMs = mean([rows.procMs]);
periodMs = procMs + thr;

fprintf('THRESHOLD\n');
fprintf('  last pause that still corrupted : %g ms\n', lastBad);
fprintf('  smallest clean pause            : %g ms\n', thr);
fprintf('  mean process() time per frame   : %.1f ms\n', procMs);
fprintf('  => safe frame period            : ~%.1f ms  (process + slack)\n', periodMs);
fprintf('  => safe frame rate              : ~%.1f fps or slower\n', 1000 / periodMs);
fprintf(['\nAbove that rate the unfixed build silently corrupts stored buffers on this\n' ...
         'machine and drive, at BF buffer %.1f MB. The threshold scales with buffer size\n' ...
         'and inversely with write throughput -- treat it as a measurement here, not a\n' ...
         'portable constant.\n'], bfMB);

%% ---------------------------------------------------------------- local functions ----
function r = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                      RFs, folder, pauseSec)
% Process every frame with a controlled pause between calls, storing BF, then compare
% each stored buffer against the in-memory BF that process() returned for that frame.
clear mex;
nFrames = numel(RFs);
if ~exist(folder, 'dir'); mkdir(folder); end

StorageSpec.folderStoragePath   = folder;
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI             = logical(false);
StorageSpec.saveRFTimeTag       = logical(false);
StorageSpec.preallocateFullFile = logical(isempty(getenv('EF_NO_PREALLOC')));
ExperimentSpec.numberOfPDIsExperiment = nFrames;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec); %#ok<ASGLU>

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

mem = cell(1, nFrames);
procMs = zeros(1, nFrames);
storeMs = zeros(1, nFrames);
for k = 1:nFrames
    if k > 1 && pauseSec > 0
        pause(pauseSec);
    end
    [~, ~, bfOut, t] = echoframe_mex('process', RFs{k}, true);
    procMs(k)  = t.total * 1000;
    storeMs(k) = t.bf_storage * 1000;
    bfCol = bfOut(:);
    inter = zeros(2 * numel(bfCol), 1, 'single');
    inter(1:2:end) = real(bfCol);
    inter(2:2:end) = imag(bfCol);
    mem{k} = inter;
end
echoframe_mex('destroy');
clear mex;

stored = read_all_buffers([BFStorageSpec.filepath '.dat']);

n = min(numel(stored), numel(mem));
r.corrupt = 0;
for i = 1:n
    if ~isequal(stored{i}, mem{i})
        r.corrupt = r.corrupt + 1;
    end
end
r.total   = n;
r.procMs  = procMs;
r.storeMs = storeMs;

% Drop the recording once read -- one per pause per repeat is tens of GB.
if exist(folder, 'dir')
    rmdir(folder, 's');
end
end

function buffers = read_all_buffers(path)
% Every stored buffer as a raw interleaved single vector, honouring header padding.
fid = fopen(path, 'r');
assert(fid > 0, 'cannot open %s', path);
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
hdr = read_header(fid);
nUnits       = double(hdr.effectiveBufferSize) * 2;   % complex single -> 2 singles
strideBytes  = nUnits * 4 + double(hdr.paddingBytes);
buffers = cell(1, double(hdr.buffersStored));
for i = 1:double(hdr.buffersStored)
    assert(fseek(fid, double(hdr.headerSize) + (i - 1) * strideBytes, 'bof') == 0, ...
           'seek to buffer %d failed', i);
    buffers{i} = fread(fid, nUnits, '*single');
end
end

function v = envnum(name, default)
raw = getenv(name);
if isempty(raw); v = default; return; end
v = str2double(raw);
if isnan(v)
    error('characterize_storage_race:badEnv', '%s=%s is not numeric.', name, raw);
end
end

function v = envlist(name, default)
raw = getenv(name);
if isempty(raw); v = default; return; end
v = str2double(strsplit(raw, ','));
if any(isnan(v))
    error('characterize_storage_race:badEnv', '%s=%s is not a numeric list.', name, raw);
end
end
