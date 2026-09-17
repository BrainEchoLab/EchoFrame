% verify_storage_race - Verify that EVERY stored buffer is correct, not just the first.
%
% Regression test for the storage overlapped-write race: Storage::Handler DMAs out of
% the buffer passed to storeBuffer and keeps writes in flight, so a producer that
% refills one buffer per frame corrupts writes still running. Existing storage tests
% only compare buffer 1, which is the one buffer that is always clean.
%
% Two checks, over every buffer of every stream:
%   (A) A/B      : two identical runs, no pause -> byte-identical
%   (B) vs memory: the BF/PDI process() returns is copied from the buffer handed to
%                  storeBuffer, so the file must match it exactly
%
% Each frame gets a different RF (base buffer circularly shifted), without which a
% torn write still compares equal. Streams: BF, PDI and RF time tags.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built (set MEX_DIR to pin a specific
% build). GPU required. On Windows must run ELEVATED -- storage init acquires
% SeManageVolumePrivilege unconditionally.
%
% Env knobs:
%   EF_RACE_FRAMES   frames per run (default 6; must exceed the ring to wrap)
%   EF_NO_PREALLOC   set to 1 to disable full-file preallocation
%   EF_RACE_RINGS    slot rings under test (default '1' = all on). Set to '0' to
%                    run against the unfixed path, where this test SHOULD fail.
%
% Usage: run

clear; close all; clear mex;

% Force all three ringed streams to one value, so EF_RACE_RINGS alone decides
% what is under test -- the library's own default is on for each. RF has no ring;
% it is protected by the acquisition ring. Set before the first MEX call.
%
% They persist for the whole MATLAB session, and a stale ring setting would
% quietly change how a later recording is written, so put them back on the way
% out, error or not.
savedRings = struct('all', getenv('EF_STORAGE_SLOT_RINGS'), ...
                    'bf',  getenv('EF_STORAGE_SLOT_RINGS_BF'), ...
                    'pdi', getenv('EF_STORAGE_SLOT_RINGS_PDI'), ...
                    'tag', getenv('EF_STORAGE_SLOT_RINGS_TIMETAG'));
restoreRings = onCleanup(@() restore_rings(savedRings)); %#ok<NASGU>

rings = getenv('EF_RACE_RINGS');
if isempty(rings); rings = '1'; end
setenv('EF_STORAGE_SLOT_RINGS', rings);
setenv('EF_STORAGE_SLOT_RINGS_BF', '');
setenv('EF_STORAGE_SLOT_RINGS_PDI', '');
setenv('EF_STORAGE_SLOT_RINGS_TIMETAG', '');
fprintf('Slot rings under test: EF_STORAGE_SLOT_RINGS=%s\n', rings);

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));

ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);
if ~isempty(getenv('MEX_DIR'))
    addpath(getenv('MEX_DIR'));   % pin the MEX under test; added last so it wins
end

nFrames = 6;
if ~isempty(getenv('EF_RACE_FRAMES'))
    nFrames = str2double(getenv('EF_RACE_FRAMES'));
end
assert(nFrames >= 2, 'EF_RACE_FRAMES must be >= 2.');

out_root = fullfile(echoframe_data_root(), 'echoframe_verify_race');
if exist(out_root, 'dir'); rmdir(out_root, 's'); end
mkdir(out_root);

%% Base specs (deterministic) -- mirrors verify_crop_storage
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
% Grid size is the main sensitivity knob: a bigger buffer means a longer write
% and a wider race window.
ReconSpec.extraVoxelsZ      = envnum('EF_RACE_EXTRA_Z', 0);
ReconSpec.extraVoxelsX      = envnum('EF_RACE_EXTRA_X', 128);
ReconSpec.c0                = TransmitSpec.c0;
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = int32([0;1;0;1]);

PDISpec.ensembleSize = ReceiveSpec.nRepeats;
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = ReceiveSpec.nRepeats;
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';

%% One deterministic RF buffer + reconstruction tables (shared by both runs)
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;

[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

nz   = double(ReconSpec.nz);
nx   = double(ReconSpec.nx);
nRep = double(ReceiveSpec.nRepeats);
nEns = max(0, floor((nRep - double(PDISpec.ensembleSize)) / double(PDISpec.shiftSize)) + 1);

% A DIFFERENT frame for each process() call. Without this every buffer holds
% identical bytes and a torn write compares equal to a clean one.
RFs = cell(1, nFrames);
for k = 1:nFrames
    RFs{k} = circshift(RF, 7 * (k - 1), 1);
end

bfBufferMB = nz * nx * nRep * 8 / 2^20;   % complex single = 8 B/element
fprintf('Grid nz=%d nx=%d nRep=%d nEns=%d | %d frames per run, no pause | BF buffer %.1f MB\n', ...
        nz, nx, nRep, nEns, nFrames, bfBufferMB);

%% Two identical runs, back to back
A = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RFs, ...
             fullfile(out_root, 'runA'));
B = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RFs, ...
             fullfile(out_root, 'runB'));

pass = true;

%% Control: the recordings actually hold the frames we asked for
pass = check(sprintf('BF  run A stored %d buffers', nFrames), numel(A.bf)  == nFrames) && pass;
pass = check(sprintf('PDI run A stored %d buffers', nFrames), numel(A.pdi) == nFrames) && pass;
pass = check(sprintf('TAG run A stored %d buffers', nFrames), numel(A.tag) == nFrames) && pass;
pass = check(sprintf('BF  run B stored %d buffers', nFrames), numel(B.bf)  == nFrames) && pass;
pass = check(sprintf('PDI run B stored %d buffers', nFrames), numel(B.pdi) == nFrames) && pass;
pass = check(sprintf('TAG run B stored %d buffers', nFrames), numel(B.tag) == nFrames) && pass;

% Control: consecutive buffers must actually differ, or the comparisons below
% would pass on a stream of identical bytes and prove nothing.
pass = check('BF  consecutive buffers differ (test is sensitive)', ...
             buffers_all_distinct(A.bf)) && pass;
pass = check('PDI consecutive buffers differ (test is sensitive)', ...
             buffers_all_distinct(A.pdi)) && pass;

%% (A) run-to-run: every buffer byte-identical
pass = compare_streams('BF  A/B', A.bf,  B.bf)  && pass;
pass = compare_streams('PDI A/B', A.pdi, B.pdi) && pass;
pass = compare_streams('TAG A/B', A.tag, B.tag) && pass;

%% (B) stored vs in-memory: the file must match what process() returned
pass = compare_streams('BF  run A stored vs in-memory',  A.bf,  A.memBF)  && pass;
pass = compare_streams('PDI run A stored vs in-memory',  A.pdi, A.memPDI) && pass;
pass = compare_streams('BF  run B stored vs in-memory',  B.bf,  B.memBF)  && pass;
pass = compare_streams('PDI run B stored vs in-memory',  B.pdi, B.memPDI) && pass;

fprintf('\n==== %s ====\n', ternary(pass, 'ALL CHECKS PASSED', 'SOME CHECKS FAILED'));
if ~pass
    error('verify_storage_race:failures', ...
          'One or more stored buffers are wrong (see above).');
end

% Test output. Every run_once destroys before it returns, and a failed run
% errors out above and keeps its recordings.
echoframe_cleanup_dir(out_root);

%% ---------------------------------------------------------------- local functions ----
function r = run_once(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec, RFs, folder)
% Process every frame back to back with storage on, then read the raw buffers back.
% No pause anywhere: the point of the test is the overlap between frames.
clear mex;
nFrames = numel(RFs);
if ~exist(folder, 'dir'); mkdir(folder); end

StorageSpec.folderStoragePath   = folder;
StorageSpec.saveRF              = logical(false);
StorageSpec.saveBF              = logical(true);
StorageSpec.savePDI             = logical(true);
StorageSpec.saveRFTimeTag       = logical(true);
StorageSpec.preallocateFullFile = logical(isempty(getenv('EF_NO_PREALLOC')));
ExperimentSpec.numberOfPDIsExperiment = nFrames;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec); %#ok<ASGLU>

echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
              BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

r.memBF  = cell(1, nFrames);
r.memPDI = cell(1, nFrames);
for k = 1:nFrames
    [pdiOut, ~, bfOut] = echoframe_mex('process', RFs{k}, true);
    % Interleave the complex BF back to the on-disk layout (re,im,re,im,...)
    % so it can be compared against the file bytes directly.
    bfCol = bfOut(:);
    inter = zeros(2 * numel(bfCol), 1, 'single');
    inter(1:2:end) = real(bfCol);
    inter(2:2:end) = imag(bfCol);
    r.memBF{k}  = inter;
    r.memPDI{k} = single(pdiOut(:));
end
echoframe_mex('destroy');   % drains async writes, closes files, unlocks
clear mex;

r.bf  = read_all_buffers([BFStorageSpec.filepath        '.dat'], '*single', 2);
r.pdi = read_all_buffers([PDIStorageSpec.filepath       '.dat'], '*single', 1);
r.tag = read_all_buffers([RFTimeTagStorageSpec.filepath '.dat'], '*double', 1);
end

function buffers = read_all_buffers(path, precision, elemsPerUnit)
% Read every stored buffer as a raw column vector, skipping the per-buffer
% padding. elemsPerUnit is 2 for complex single (interleaved re/im), 1 otherwise.
fid = fopen(path, 'r');
assert(fid > 0, 'cannot open %s', path);
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
hdr = read_header(fid);

switch precision
    case '*single'; elemBytes = 4;
    case '*double'; elemBytes = 8;
    otherwise; error('unsupported precision %s', precision);
end
nUnits      = double(hdr.effectiveBufferSize) * elemsPerUnit;
payloadBytes = nUnits * elemBytes;
strideBytes  = payloadBytes + double(hdr.paddingBytes);

buffers = cell(1, double(hdr.buffersStored));
for i = 1:double(hdr.buffersStored)
    offset = double(hdr.headerSize) + (i - 1) * strideBytes;
    assert(fseek(fid, offset, 'bof') == 0, 'seek to buffer %d failed', i);
    buffers{i} = fread(fid, nUnits, precision);
    assert(numel(buffers{i}) == nUnits, ...
           'short read on buffer %d (%d of %d)', i, numel(buffers{i}), nUnits);
end
end

function ok = compare_streams(label, x, y)
% Compare two buffer lists and name the buffers that differ. The first and last
% are never touched by the race, so "2 3 4 5" of 6 is its signature.
n = min(numel(x), numel(y));
bad = [];
worst = 0;
for i = 1:n
    if ~isequal(x{i}, y{i})
        bad(end+1) = i; %#ok<AGROW>
        worst = max(worst, max(abs(double(x{i}) - double(y{i}))));
    end
end
if numel(x) ~= numel(y)
    ok = check(sprintf('%s: buffer counts differ (%d vs %d)', label, numel(x), numel(y)), false);
    return;
end
if isempty(bad)
    ok = check(sprintf('%s: all %d buffers identical', label, n), true);
else
    ok = check(sprintf('%s: %d of %d buffers DIFFER (buffers %s, max|diff|=%.4g)', ...
                       label, numel(bad), n, mat2str(bad), worst), false);
end
end

function ok = buffers_all_distinct(x)
% True when no two consecutive buffers match. Guards against a vacuous pass:
% identical frames would hide corruption of a middle buffer.
ok = true;
for i = 2:numel(x)
    if isequal(x{i}, x{i-1}); ok = false; return; end
end
end

function restore_rings(saved)
% Put the slot-ring knobs back as they were found.
setenv('EF_STORAGE_SLOT_RINGS',         saved.all);
setenv('EF_STORAGE_SLOT_RINGS_BF',      saved.bf);
setenv('EF_STORAGE_SLOT_RINGS_PDI',     saved.pdi);
setenv('EF_STORAGE_SLOT_RINGS_TIMETAG', saved.tag);
end

function v = envnum(name, default)
% Numeric env override, falling back to a default when unset or unparseable.
raw = getenv(name);
if isempty(raw)
    v = default;
    return;
end
v = str2double(raw);
if isnan(v)
    error('verify_storage_race:badEnv', '%s=%s is not numeric.', name, raw);
end
end

function ok = check(name, cond)
ok = logical(cond);
fprintf('  [%s] %s\n', ternary(ok, 'PASS', 'FAIL'), name);
end

function s = ternary(cond, a, b)
if cond; s = a; else; s = b; end
end
