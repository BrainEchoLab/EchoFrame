% verify_core_headless - MEX-free, GPU-free checks of the core MATLAB library.
%
% Covers the parts of echoframe/matlab/core that need neither echoframe_mex nor a
% GPU, so it can run anywhere (including CI):
%
%   1. read_header          - version 0 (5-field) and version 1 (6-field) headers
%   2. read_stored_RF       - buffer round-trip against known bytes
%   3. echoframe_validate_structs - derives nElements, casts types, rejects gaps
%   4. initialize_image_reconstruction - documented nz/nx sizing and table shapes
%   5. stored_frame_size    - cropped vs full stored frame geometry
%   6. calculate_*_apodization - length, centring, and the <=0.2 zeroing rule
%   7. real recording cross-check - parse a file the C++ storage layer wrote
%   8. init_storage path separators - no literal backslash; filepaths are char
%   9. sweep coverage       - every tests/verify_*.m is in run_all_matlab's table
%
% Companion to verify_batch_loading_headless (which covers batch_loading). The
% verify_batch_* and verify_crop_storage harnesses need a GPU and an elevated
% session; this one does not.
%
% Prereq: ECHOFRAME_PATH.
% Usage:  run it. Errors out on the first mismatch; prints ALL PASSED at the end.

clear; close all;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

tmp = fullfile(tempdir, 'echoframe_core_headless');
if isfolder(tmp), rmdir(tmp, 's'); end
mkdir(tmp);
cleanup = onCleanup(@() rmdir(tmp, 's'));

%% ---------------------------------------------------------------- 1. read_header
fprintf('=== read_header ===\n');

PAD   = 64;
NBUF  = 3;
EFF   = 128;              % logical values per buffer

for hs = [48 512 4096]
    v1 = fullfile(tmp, sprintf('v1_%d.dat', hs));
    fid = fopen(v1, 'w', 'ieee-le');
    fwrite(fid, uint64([1; hs; NBUF; EFF; PAD; 2]), 'uint64');
    fwrite(fid, zeros(hs - 6*8, 1, 'uint8'), 'uint8');      % zero-fill to headerSize
    fwrite(fid, zeros(NBUF * (EFF*4 + PAD), 1, 'uint8'), 'uint8');
    fclose(fid);

    fid = fopen(v1); H1 = read_header(fid); pos1 = ftell(fid); fclose(fid);
    assert(H1.version == 1,                'v1: version');
    assert(H1.headerSize == hs,            'v1: headerSize');
    assert(H1.buffersStored == NBUF,       'v1: buffersStored');
    assert(H1.effectiveBufferSize == EFF,  'v1: effectiveBufferSize');
    assert(H1.paddingBytes == PAD,         'v1: paddingBytes');
    assert(H1.dataType == 2,               'v1: dataType');
    assert(pos1 == hs, ...
           sprintf('v1: read_header must leave the file at byte %d (the first data buffer)', hs));
end
fprintf('  version 1 (6 fields) parsed at headerSize 48/512/4096  OK\n');

for hs = [40 512 4096]
    v0 = fullfile(tmp, sprintf('v0_%d.dat', hs));
    fid = fopen(v0, 'w', 'ieee-le');
    fwrite(fid, uint64([0; hs; NBUF; EFF; PAD]), 'uint64');
    fwrite(fid, zeros(hs - 5*8, 1, 'uint8'), 'uint8');
    fwrite(fid, zeros(NBUF * (EFF*4 + PAD), 1, 'uint8'), 'uint8');
    fclose(fid);

    fid = fopen(v0); H0 = read_header(fid); pos0 = ftell(fid); fclose(fid);
    assert(H0.version == 0,       'v0: version');
    assert(H0.headerSize == hs,   'v0: headerSize');
    assert(isnan(H0.dataType),    'v0: dataType must be NaN when the field is absent');
    assert(pos0 == hs, ...
           sprintf('v0: read_header must leave the file at byte %d', hs));
end
fprintf('  version 0 (5 fields) parsed at headerSize 40/512/4096, dataType NaN  OK\n');

%% ------------------------------------------------------------- 2. read_stored_RF
fprintf('\n=== read_stored_RF ===\n');

nSamples = 16; nTx = 3; nRepeats = 4; nChannels = 8;
rowsPerBuf = nSamples * nTx * nRepeats;
effRF      = rowsPerBuf * nChannels;      % int16 elements per buffer

RS.nSamples = int32(nSamples);   RS.nTransmissions = int32(nTx);
RS.nRepeats = int32(nRepeats);   RS.nChannels      = int32(nChannels);

rfPath = fullfile(tmp, 'rf_acq.dat');
fid = fopen(rfPath, 'w', 'ieee-le');
fwrite(fid, uint64([1; 48; NBUF; effRF; PAD; 1]), 'uint64');
expected = cell(NBUF, 1);
for b = 1:NBUF
    v = int16(mod((1:effRF)' + b*17, 3001) - 1500);   % deterministic, distinct per buffer
    expected{b} = reshape(v, rowsPerBuf, nChannels);
    fwrite(fid, v, 'int16');
    fwrite(fid, zeros(PAD, 1, 'uint8'), 'uint8');
end
fclose(fid);

for b = 0:NBUF-1
    RF = read_stored_RF(rfPath, RS, b);
    assert(isa(RF, 'int16'), 'read_stored_RF: class');
    assert(isequal(size(RF), [rowsPerBuf nChannels]), 'read_stored_RF: size');
    assert(isequal(RF, expected{b+1}), sprintf('read_stored_RF: buffer %d content', b));
end
fprintf('  %d buffers round-tripped byte-for-byte  OK\n', NBUF);

%% ------------------------------------------------ 3/4. spec pipeline (no MEX)
fprintf('\n=== echoframe_validate_structs + initialize_image_reconstruction ===\n');

[P, T, R, Rec, PDI] = local_specs();

[P, R, Rec] = initialize_image_reconstruction(P, T, R, Rec);

% nz = nSamplesIQ + extraVoxelsZ, nx = nChannels + extraVoxelsX, each rounded
% up to even. Expected values are literals, not recomputed from the same inputs.
assert(double(Rec.nz) == 256, ...
       'nz must be 256 for nSamplesIQ=256, extraVoxelsZ=0 (got %d)', double(Rec.nz));
assert(double(Rec.nx) == 256, ...
       'nx must be 256 for nChannels=128, extraVoxelsX=128 (got %d)', double(Rec.nx));

% An odd input must not produce an odd grid.
Rodd = R; Rodd.nSamplesIQ = int32(255);
Recodd = Rec; Recodd.extraVoxelsZ = int32(0); Recodd.extraVoxelsX = int32(1);
[~, ~, Recodd] = initialize_image_reconstruction(P, T, Rodd, Recodd);
assert(mod(double(Recodd.nz), 2) == 0 && double(Recodd.nz) == 256, ...
       'nz must round 255 up to 256 (got %d)', double(Recodd.nz));
assert(mod(double(Recodd.nx), 2) == 0 && double(Recodd.nx) == 130, ...
       'nx must round 128+1 up to 130 (got %d)', double(Recodd.nx));
fprintf('  nz=%d nx=%d, and odd inputs round up to even (255->256, 129->130)  OK\n', ...
        Rec.nz, Rec.nx);

for f = {'delayIndices','interpolationWeights','frequencyAxis','planewaveDelays','tgcVector'}
    assert(isfield(Rec, f{1}) && ~isempty(Rec.(f{1})), ...
           sprintf('initialize_image_reconstruction did not build %s', f{1}));
end
fprintf('  reconstruction tables built: delayIndices, interpolationWeights, frequencyAxis, planewaveDelays, tgcVector  OK\n');

[P, T, R, Rec, PDI] = echoframe_validate_structs(P, T, R, Rec, PDI);
assert(R.nElements == P.nElements, 'validate_structs must derive ReceiveSpec.nElements');
assert(isa(R.nSamples, 'int32'),   'validate_structs must cast nSamples to int32');
assert(isa(PDI.threshold, 'single'), 'validate_structs must cast PDISpec.threshold to single');
fprintf('  nElements derived, types cast (int32/single)  OK\n');

% A missing required field must be rejected, not silently accepted.
[P2, T2, R2, Rec2, PDI2] = local_specs();
[P2, R2, Rec2] = initialize_image_reconstruction(P2, T2, R2, Rec2);
R2 = rmfield(R2, 'samplingMode');
threw = false;
try
    echoframe_validate_structs(P2, T2, R2, Rec2, PDI2);
catch
    threw = true;
end
assert(threw, 'validate_structs accepted a ReceiveSpec missing samplingMode');
fprintf('  missing required field rejected  OK\n');

%% ------------------------------------------------------- 5. cropped frames
fprintf('\n=== stored_frame_size (cropped storage geometry) ===\n');

RC.nz = int32(400); RC.nx = int32(256);        % the grid the demo specs produce
RC.croppingROI = int32([57; 344; 17; 240]);    % 288 x 224, asymmetric on purpose

% uncropped: the full reconstruction grid
[fz, fx, wasCropped] = stored_frame_size(RC, false);
assert(fz == 400 && fx == 256, 'uncropped frame must be nz x nx');
assert(~wasCropped, 'uncropped must report isCropped false');

% cropped: inclusive ROI bounds
[cz, cx, wasCropped] = stored_frame_size(RC, true);
assert(cz == 344 - 57 + 1, 'cropped nz must be zBottom-zTop+1');
assert(cx == 240 - 17 + 1, 'cropped nx must be xRight-xLeft+1');
assert(wasCropped, 'cropped must report isCropped true');
assert(cz ~= cx, 'this ROI is asymmetric; a row/column swap must not pass');
fprintf('  full %dx%d, cropped %dx%d from ROI [%d %d %d %d]  OK\n', ...
        fz, fx, cz, cx, RC.croppingROI);

% Calls init_storage rather than restating its arithmetic.
nRepeats_s = 40;
expectedElems = cz * cx * nRepeats_s;

SS.folderStoragePath   = fullfile(tmp, 'sizing');
SS.saveRF              = logical(false);
SS.saveBF              = logical(false);   % nothing is written; only the specs matter
SS.savePDI             = logical(false);
SS.saveRFTimeTag       = logical(false);
SS.preallocateFullFile = logical(true);
ES.numberOfPDIsExperiment = 1;

[Rs, Recs, PDIs] = deal(struct());
Recs.nz = RC.nz;  Recs.nx = RC.nx;
Recs.croppingROI = RC.croppingROI;
Recs.cropBF      = logical(true);
Recs.bfDataType  = 'complex single';
Rs.nRepeats = int32(nRepeats_s);
Rs.nTransmissions = int32(3);
Rs.nSamples = int32(512);
Rs.nChannels = int32(128);
PDIs.ensembleSize = int32(nRepeats_s);
PDIs.shiftSize    = int32(nRepeats_s);
PDIs.cropPDI      = logical(true);

[BFS, PDIS] = init_storage('init', SS, Rs, Recs, PDIs, ES, struct(), struct());
assert(double(BFS.bufferSize) == expectedElems, ...
       'init_storage sized the cropped BF buffer at %d, stored_frame_size implies %d', ...
       double(BFS.bufferSize), expectedElems);

% PDI crops the same ROI but counts ensembles, not repeats.
nEns_s = max(0, floor((nRepeats_s - nRepeats_s) / nRepeats_s) + 1);
assert(double(PDIS.bufferSize) == cz * cx * nEns_s, ...
       'init_storage sized the cropped PDI buffer at %d, expected %d', ...
       double(PDIS.bufferSize), cz * cx * nEns_s);
fprintf('  init_storage sizes cropped BF=%d and PDI=%d elements, matching stored_frame_size  OK\n', ...
        double(BFS.bufferSize), double(PDIS.bufferSize));

% a cropped stack round-trips through read_header at the cropped size
crPath = fullfile(tmp, 'bf_cropped.dat');
fid = fopen(crPath, 'w', 'ieee-le');
fwrite(fid, uint64([1; 48; 2; expectedElems; PAD; 3]), 'uint64');
% Header only: read_header does not read past it.
fclose(fid);
fid = fopen(crPath); Hc = read_header(fid); fclose(fid);
assert(double(Hc.effectiveBufferSize) == expectedElems, ...
       'cropped stored buffer size must match cNz*cNx*nRepeats');
fprintf('  cropped recording header reports %d elements/buffer  OK\n', Hc.effectiveBufferSize);

% bad inputs must be rejected, not silently mis-sized
threw = false;
try
    RB = RC; RB.croppingROI = int32([344; 57; 17; 240]); % inverted z bounds
    stored_frame_size(RB, true);
catch
    threw = true;
end
assert(threw, 'stored_frame_size accepted an inverted ROI');

threw = false;
try
    stored_frame_size(RC);                               % crop flag omitted
catch
    threw = true;
end
assert(threw, 'stored_frame_size accepted a missing crop flag');
fprintf('  inverted ROI and missing crop flag both rejected  OK\n');

%% ------------------------------------------------------------ 6. apodization
fprintf('\n=== calculate_*_apodization ===\n');

nEl = 128;
for pct = [100 90 80]
    rx = calculate_receive_apodization(nEl, pct);
    tx = calculate_transmit_apodization(nEl, pct);
    for pair = {{'receive', rx}, {'transmit', tx}}
        name = pair{1}{1}; a = pair{1}{2};
        assert(numel(a) == nEl, sprintf('%s apodization length at %d%%', name, pct));
        assert(all(a >= 0), sprintf('%s apodization negative weight at %d%%', name, pct));
        assert(~any(a > 0 & a <= 0.2), ...
               sprintf('%s apodization left a weight <=0.2 unzeroed at %d%%', name, pct));
        onIdx = find(a > 0);
        if ~isempty(onIdx)
            centre = (onIdx(1) + onIdx(end)) / 2;
            assert(abs(centre - (nEl+1)/2) <= 1, ...
                   sprintf('%s aperture not centred at %d%%', name, pct));

            % The aperture must track the percentage, or the test would pass
            % even if the width never changed.
            offWanted = round(nEl * (100 - pct) / 100);
            offWanted = offWanted + rem(offWanted, 2);
            onWanted  = nEl - offWanted;
            span      = onIdx(end) - onIdx(1) + 1;
            assert(span <= onWanted, ...
                   sprintf(['%s aperture at %d%% spans %d elements, wider than the ' ...
                            '%d requested'], name, pct, span, onWanted));
            assert(span >= onWanted - 12, ...
                   sprintf(['%s aperture at %d%% spans only %d elements, far short ' ...
                            'of the %d requested'], name, pct, span, onWanted));
            if pct < 100
                assert(all(a(1:offWanted/2) == 0), ...
                       sprintf('%s did not switch off the outer elements at %d%%', name, pct));
            end
        end
    end
end
fprintf('  length, non-negativity, <=0.2 zeroing, centring and aperture width hold at 100/90/80%%  OK\n');

%% -------------------------------------------- 7. against a real recording
% Everything above reads files this test wrote itself, so parse one the C++
% storage layer actually produced, when available.
fprintf('\n=== real recording cross-check ===\n');
realDat = local_find_recording();
if isempty(realDat)
    fprintf('  (skipped: no recording found -- set EF_REAL_RECORDING or run a storage test first)\n');
else
    info = dir(realDat);
    fid  = fopen(realDat);
    Hr   = read_header(fid);
    posr = ftell(fid);
    fclose(fid);

    assert(ismember(double(Hr.version), [0 1]), 'real header: unknown version');
    assert(double(Hr.headerSize) >= 40, 'real header: headerSize smaller than the fields');
    assert(mod(double(Hr.headerSize), 8) == 0, 'real header: headerSize not a whole number of uint64');
    assert(posr == double(Hr.headerSize), 'read_header did not land on the first data buffer');
    assert(double(Hr.buffersStored) > 0, 'real header: no buffers recorded');

    % Stored buffers occupy header + buffers*(elements*8B + padding). The file
    % may be longer: preallocateFullFile sizes it up front and nothing shrinks
    % it on close, so allow slack, but only a whole number of buffers.
    bytesPerElem = 8;
    bufferStride = double(Hr.effectiveBufferSize) * bytesPerElem + double(Hr.paddingBytes);
    predicted    = double(Hr.headerSize) + double(Hr.buffersStored) * bufferStride;
    assert(info.bytes >= predicted, ...
           ['real recording is SHORT: header %d + %d buffers x ' ...
            '(%d elements x %d B + %d padding) = %d, file is only %d bytes'], ...
           double(Hr.headerSize), double(Hr.buffersStored), ...
           double(Hr.effectiveBufferSize), bytesPerElem, ...
           double(Hr.paddingBytes), predicted, info.bytes);

    slackBytes = info.bytes - predicted;
    assert(mod(slackBytes, bufferStride) == 0, ...
           ['real recording layout does not close: %d bytes past the %d stored ' ...
            'buffer(s) is not a whole number of %d-byte buffers'], ...
           slackBytes, double(Hr.buffersStored), bufferStride);

    fprintf('  %s\n', realDat);
    fprintf(['  version %d, headerSize %d, %d buffer(s), %d elements/buffer, ' ...
             'padding %d -- layout closes at %d bytes  OK\n'], ...
            double(Hr.version), double(Hr.headerSize), double(Hr.buffersStored), ...
            double(Hr.effectiveBufferSize), double(Hr.paddingBytes), predicted);
    if slackBytes > 0
        fprintf('  (+%d preallocated buffer(s) of unwritten tail, %d bytes -- preallocateFullFile)\n', ...
                slackBytes / bufferStride, slackBytes);
    end
end

%% ------------------------------------------- 8. init_storage path separators
% Every separator must come from fullfile: a literal '\' is part of the folder
% NAME on Linux, not a separator.
fprintf('\n=== init_storage path separators ===\n');

sepRoot = fullfile(tmp, 'sep_check');
[Ps, Ts, Rs, Recs, PDIs] = local_specs();
[Ps, Rs, Recs] = initialize_image_reconstruction(Ps, Ts, Rs, Recs);

SpecSep.folderStoragePath   = sepRoot;
SpecSep.saveRF              = logical(false);
SpecSep.saveBF              = logical(true);
SpecSep.savePDI             = logical(false);
SpecSep.saveRFTimeTag       = logical(false);
SpecSep.preallocateFullFile = logical(false);
ExpSep.numberOfPDIsExperiment = 2;

[BFsep, ~, ~, ~] = init_storage('init', SpecSep, Rs, Recs, PDIs, ExpSep, Ts, Ps);
SpecSep = evalin('base', 'StorageSpec');
recDir  = SpecSep.experimentStoragePath;

% The recording folder is a child of folderStoragePath.
assert(ischar(recDir), 'experimentStoragePath must be char, not string');
if ~ispc
    % Only meaningful where '\' is not the separator; the leaf assertions below
    % cover Windows.
    assert(~any(recDir == '\'), ...
           'experimentStoragePath contains a literal backslash: %s', recDir);
end
assert(strncmp(recDir, sepRoot, numel(sepRoot)), ...
       'recording folder is not under folderStoragePath: %s', recDir);

leaf = recDir(numel(sepRoot)+1:end);
assert(~isempty(leaf) && leaf(1) == filesep, ...
       'recording folder is not separated from its parent by filesep: %s', recDir);
assert(~any(leaf(2:end) == filesep), ...
       'recording folder name contains a separator: %s', leaf);
assert(startsWith(leaf(2:end), 'recording_'), ...
       'recording folder is not named recording_<date>: %s', leaf);

% The filepaths must sit inside that folder and be char: mxArrayToString
% returns NULL for a MATLAB string.
assert(ischar(BFsep.filepath), 'filepath must be char, not string');
if ~ispc
    assert(~any(BFsep.filepath == '\'), ...
           'BF filepath contains a literal backslash: %s', BFsep.filepath);
end
% Portable equivalent: fileparts resolves the real separator either way.
assert(strcmp(fileparts(BFsep.filepath), recDir), ...
       'BF filepath is not directly inside the recording folder: %s', BFsep.filepath);

fprintf('  %s\n', recDir);
fprintf('  separators all come from fullfile, no literal backslash  OK\n');

%% ------------------------------------------- 9. every harness is in the sweep
% A harness nothing drives is a harness nobody runs, and a harness can be added
% here without being registered, which nothing else would catch. Every
% tests/verify_*.m must be named in run_all_matlab's task table. This one is
% exempt -- it is the file doing the checking, and it is in the table.
fprintf('\n=== every verify_* harness is registered in run_all_matlab ===\n');

testsDir  = fullfile(ECHOFRAME_PATH, 'echoframe', 'matlab', 'tests');
driver    = fullfile(ECHOFRAME_PATH, 'echoframe', 'matlab', 'run_all_matlab.m');
assert(isfile(driver), 'run_all_matlab.m not found at %s', driver);
driverSrc = fileread(driver);

harnesses = dir(fullfile(testsDir, 'verify_*.m'));
assert(~isempty(harnesses), 'no verify_*.m found in %s', testsDir);

missing = {};
for h = 1:numel(harnesses)
    [~, stem] = fileparts(harnesses(h).name);
    % The table names each task by stem; a bare stem match is enough and does
    % not care whether the path is written with / or \.
    if isempty(strfind(driverSrc, stem)) %#ok<STREMP> % R2016b-compatible
        missing{end+1} = harnesses(h).name; %#ok<SAGROW>
    end
end

if ~isempty(missing)
    error('verify_core_headless:harnessNotInSweep', ...
          ['These harnesses exist but run_all_matlab does not drive them:\n    %s\n' ...
           'Add them to the task table, or delete them.'], strjoin(missing, '\n    '));
end
fprintf('  %d harnesses, all registered  OK\n', numel(harnesses));

fprintf('\n==================== ALL PASSED ====================\n');


%% ---------------------------------------------------------------- local helpers
function p = local_find_recording()
%LOCAL_FIND_RECORDING  Newest bf_acq.dat written by the storage layer, or ''.
%  Looks at EF_REAL_RECORDING first (a .dat path or a folder), then any
%  recording_* folder under tempdir. Returns '' so the caller can skip.
p = '';

env = getenv('EF_REAL_RECORDING');
if ~isempty(env)
    if isfile(env), p = env; return; end
    if isfolder(env)
        hit = dir(fullfile(env, '**', 'bf_acq.dat'));
        if ~isempty(hit), p = fullfile(hit(1).folder, hit(1).name); return; end
    end
end

hits = dir(fullfile(tempdir, '**', 'bf_acq.dat'));
if isempty(hits), return; end
[~, newest] = max([hits.datenum]);
p = fullfile(hits(newest).folder, hits(newest).name);
end

function [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = local_specs()
%LOCAL_SPECS  A minimal, self-contained spec set - no simulation, no MEX.
ProbeSpec.pitch       = 300e-6;
ProbeSpec.Fc          = 5e6;
ProbeSpec.nElements   = int32(128);
ProbeSpec.elementPosition = single([(0:127)'*300e-6, zeros(128, 4)]);

TransmitSpec.c0          = 1540;
TransmitSpec.type        = 'planewave';
TransmitSpec.steer       = single([-10 0 10]);
TransmitSpec.apodization = ones(128, 1);
TransmitSpec.transmitDelays = zeros(128, 1, 3);

ReceiveSpec.nSamples             = int32(512);
ReceiveSpec.nSamplesIQ           = int32(256);
ReceiveSpec.nTransmissions       = int32(3);
ReceiveSpec.nRepeats             = int32(40);
ReceiveSpec.nChannels            = int32(128);
ReceiveSpec.channel2ElementMap   = int32(0:127);
ReceiveSpec.Fs                   = single(20e6);
ReceiveSpec.samplingMode         = 'BS100BW';
% Depth extents: not validated, but initialize_image_reconstruction reads them
% to build ReconSpec.zAxis.
ReceiveSpec.startDepthMm         = 0;
ReceiveSpec.actualEndDepthMm     = 40;
ReceiveSpec.samplesPerWavelength = int32(2);   % BS100BW: Nz = nSamples*round(4/spw)
                                              % and freq_mapping spans Nz/4, which must
                                              % cover nSamplesIQ -> nSamplesIQ = nSamples/2

ReconSpec.bfDataType        = 'complex single';
ReconSpec.filterFrequencies = logical(false);
ReconSpec.getBF             = logical(true);
ReconSpec.getPDI            = logical(true);
ReconSpec.extraVoxelsZ      = int32(0);
ReconSpec.extraVoxelsX      = int32(128);
ReconSpec.c0                = single(1540);
ReconSpec.cropBF            = logical(false);
ReconSpec.croppingROI       = int32([0; 128; 0; 128]);

PDISpec.ensembleSize = int32(40);
PDISpec.threshold    = single(0.4);
PDISpec.shiftSize    = int32(40);
PDISpec.cropPDI      = logical(false);
PDISpec.svdMethod    = 'Covariance';
end
