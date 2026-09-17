% verify_padding_removal - Record, strip the padding, and show the data survived.
%
% Storage pads every buffer out to a whole number of sectors.
% remove_padding_bytes rewrites a recording without that padding, taking the
% element type from the header's dataType. This records all four streams, runs
% that tool on each, compares the de-padded copy against the original, and
% plots B-mode, PDI and the time tags from both.
%
% Every stream must report IDENTICAL. Only the time-tag stream has non-zero
% padding at this configuration.
%
% Prereq: ECHOFRAME_PATH env var; echoframe_mex built; a CUDA GPU; an ELEVATED
%         MATLAB (storage acquires SeManageVolumePrivilege).
% Usage:  run it.

clear; close all; clear mex;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);

NFRAMES = 4;
OUT     = fullfile(tempdir, 'ef_padding_removal');
if isfolder(OUT); rmdir(OUT, 's'); end
mkdir(OUT);

%% Acquire: the real pipeline, writing every stream
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = batch_demo_data.specs();
[RF, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
    simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
[ProbeSpec, ReceiveSpec, ReconSpec] = ...
    initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);
ReconSpec.getBF  = true;
ReconSpec.getPDI = true;

StorageSpec = struct('folderStoragePath', OUT, 'saveRF', true, 'saveBF', true, ...
                     'savePDI', true, 'saveRFTimeTag', true, ...
                     'preallocateFullFile', false);
ExperimentSpec.numberOfPDIsExperiment = NFRAMES;

[BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
    init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                 ExperimentSpec, TransmitSpec, ProbeSpec);
[ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
    echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);
echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, BFStorageSpec, ...
              PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);

% simulate_logo_rf leaves the tag samples as image data, so stamp them the way
% the hardware does. See stamp_time_tags below for the format.
nS      = double(ReceiveSpec.nSamples);
nTX     = double(ReceiveSpec.nTransmissions);
nRep    = double(ReceiveSpec.nRepeats);
PRF_HZ  = 8000;                       % acquisitions per second
dtAcq   = 1 / PRF_HZ;
framePeriod = nTX * nRep * dtAcq;

fprintf('\nAcquiring %d frames...\n', NFRAMES);
for k = 1:NFRAMES
    RFk = RF + int16(k);                                  % each frame distinct
    RFk = stamp_time_tags(RFk, nS, nTX, nRep, (k-1) * framePeriod, dtAcq);
    echoframe_mex('process', RFk, true);
end
echoframe_mex('destroy');
clear mex

rec = evalin('base', 'StorageSpec');
rec = rec.experimentStoragePath;
fprintf('recording: %s\n', rec);

%% Strip the padding with the shipped tool, one stream at a time
% The tool is used verbatim, with only its three path variables filled in. It
% opens with `clear`, which runs in this workspace, so state is saved first.
streams = {'rf_acq', 'bf_acq', 'pdi_acq', 'rfTimeTag_acq'};
toolSrc = fullfile(ECHOFRAME_PATH, 'echoframe', 'matlab', 'core', 'reading', ...
                   'remove_padding_bytes.m');
tool    = fileread(toolSrc);

stripAll = fullfile(OUT, 'strip_all.m');
fidAll   = fopen(stripAll, 'w');
for s = 1:numel(streams)
    body = tool;
    body = regexprep(body, '^load_path\s*=\s*'''';', ...
                     ['load_path        = ''' strrep(rec, '\', '\\') ''';'], ...
                     'lineanchors', 'once');
    body = regexprep(body, '^originalFilename\s*=\s*'''';', ...
                     ['originalFilename = ''' streams{s} ''';'], ...
                     'lineanchors', 'once');
    body = regexprep(body, '^cleanFilename\s*=\s*'''';', ...
                     ['cleanFilename    = ''' streams{s} '_clean'';'], ...
                     'lineanchors', 'once');
    runner = fullfile(OUT, ['strip_' streams{s} '.m']);
    fid = fopen(runner, 'w'); fwrite(fid, body); fclose(fid);
    % Literal paths: no variable survives the first run.
    fprintf(fidAll, 'fprintf(''\\n---- %s ----\\n'');\n', streams{s});
    fprintf(fidAll, 'run(''%s'');\n', runner);
end
fclose(fidAll);

save(fullfile(OUT, 'state.mat'), 'rec', 'streams', 'ReconSpec', 'ReceiveSpec', ...
     'NFRAMES', 'OUT');

fprintf('\n==================== stripping padding ====================\n');
run(stripAll);

% Restore what the tool cleared.
load(fullfile(tempdir, 'ef_padding_removal', 'state.mat'));

%% Compare every stream, original against cleaned
fprintf('\n==================== comparing ====================\n');
failures = 0;
data = struct();
for s = 1:numel(streams)
    name  = streams{s};
    orig  = fullfile(rec, [name '.dat']);
    clean = fullfile(rec, [name '_clean.dat']);

    [dO, hO] = local_read(orig);
    [dC, hC] = local_read(clean);
    data.(name) = dC;

    same = numel(dO) == numel(dC) && isequal(dO, dC);
    if same; verdict = 'IDENTICAL'; else; verdict = 'DIFFERS'; end
    fprintf(['%-14s dataType %d | padding %4d -> %d | %d buffers | ' ...
             '%d elements | %s\n'], ...
            name, hO.dataType, hO.paddingBytes, hC.paddingBytes, ...
            hO.buffersStored, numel(dO), verdict);
    if ~same
        failures = failures + 1;
        fprintf(2, '   original %d elements, cleaned %d\n', numel(dO), numel(dC));
    end
    if hC.paddingBytes ~= 0
        failures = failures + 1;
        fprintf(2, '   cleaned file still declares padding\n');
    end
end

% Stamped as a steady ramp, so every step should rise.
tags = data.rfTimeTag_acq;
back = sum(diff(tags) <= 0);
if back > 0
    failures = failures + 1;
    fprintf(2, '%-14s %d of %d steps do not rise\n', 'time tags', back, numel(tags)-1);
else
    fprintf('%-14s rise monotonically, %.4f s to %.4f s (%d values)\n', ...
            'time tags', tags(1), tags(end), numel(tags));
end

%% Show it: the same frame out of each file, side by side
[nz, nx] = stored_frame_size(ReconSpec, ReconSpec.cropBF);
nRep     = double(ReceiveSpec.nRepeats);

bfO = local_read(fullfile(rec, 'bf_acq.dat'));
bfC = data.bf_acq;
frameO = reshape(bfO(1:nz*nx*nRep), nz, nx, nRep);
frameC = reshape(bfC(1:nz*nx*nRep), nz, nx, nRep);

figure('Name', 'Padding removal', 'NumberTitle', 'off', 'Color', 'w');

subplot(2,3,1);
imagesc(20*log10(abs(mean(frameO, 3)) / max(abs(mean(frameO, 3)), [], 'all')));
axis image; colormap(gca, gray); clim([-50 0]); title('B-mode, original');

subplot(2,3,2);
imagesc(20*log10(abs(mean(frameC, 3)) / max(abs(mean(frameC, 3)), [], 'all')));
axis image; colormap(gca, gray); clim([-50 0]); title('B-mode, de-padded');

subplot(2,3,3);
imagesc(abs(mean(frameO, 3) - mean(frameC, 3)));
axis image; colorbar; title('difference (expect all zero)');

pdiC = data.pdi_acq;
nEns = numel(pdiC) / (nz * nx) / NFRAMES;
subplot(2,3,4);
imagesc(10*log10(reshape(pdiC(1:nz*nx), nz, nx) / max(pdiC(1:nz*nx))));
axis image; colormap(gca, hot); title('PDI, de-padded');

% A straight ramp, with the de-padded copy on top of it.
[tagO, tagH] = local_read(fullfile(rec, 'rfTimeTag_acq.dat'));
subplot(2,3,[5 6]);
% Markers rather than a dashed line, which reads as gaps in the data.
step = max(1, round(numel(tagO) / 40));
plot(tagO, '-', 'LineWidth', 2, 'Color', [0 0.45 0.74]); hold on;
plot(1:step:numel(data.rfTimeTag_acq), data.rfTimeTag_acq(1:step:end), 'o', ...
     'MarkerSize', 5, 'LineWidth', 1.2, 'Color', [0.85 0.33 0.1]);
grid on; xlabel('tag'); ylabel('decoded value [s]');
legend('original (line)', 'de-padded (markers)', 'Location', 'best');
title(sprintf('time tags: %d values, %d padding bytes/buffer stripped', ...
              numel(tagO), tagH.paddingBytes));

% Saved as well as shown: -batch closes its figures on exit. Beside OUT, not
% inside it, because the cleanup below removes OUT.
figPath = fullfile(tempdir, 'ef_padding_removal.png');
exportgraphics(gcf, figPath, 'Resolution', 150);

%% Verdict
fprintf('\n');
fprintf('>>> figure: %s\n', figPath);
if failures == 0
    fprintf('>>> PASSED: every stream survived padding removal unchanged\n');
else
    fprintf(2, '>>> FAILED: %d problem(s)\n', failures);
end

% Test output, kept when a check failed. This harness reports failures rather
% than erroring, so the condition is explicit.
if failures == 0
    echoframe_cleanup_dir(OUT);
    fprintf('>>> recording removed from %s\n', OUT);
else
    fprintf('>>> recording left at %s\n', rec);
end

function rf = stamp_time_tags(rf, nS, nTX, nRep, t0, dtAcq)
%STAMP_TIME_TAGS  Write hardware-format time tags into a simulated RF buffer.
%   Each (repeat, transmit) acquisition carries its own tag in its first two
%   samples: a tick count at 40 kHz, low half then high half, each stored as a
%   uint16 reinterpreted as int16. computeTimeTags decodes it as
%   (W1 + 65536*W2) / 4e4, adding 65536 to a negative half first.
acq   = nRep * nTX;
kk    = repelem((0:nRep-1)', nTX);
tt    = repmat((0:nTX-1)', nRep, 1);
base  = kk * nS * nTX + tt * nS;          % first sample of each acquisition

ticks = round((t0 + (0:acq-1)' * dtAcq) * 4e4);
hi    = floor(ticks / 65536);
lo    = ticks - hi * 65536;

% uint16 value -> the int16 with the same bit pattern.
asInt16 = @(v) int16(mod(v + 32768, 65536) - 32768);
rf(base + 1) = asInt16(lo);
rf(base + 2) = asInt16(hi);
end

function [data, H] = local_read(path)
%LOCAL_READ  Read every buffer, skipping any padding, using the header's type.
fid = fopen(path);
assert(fid > 0, 'cannot open %s', path);
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
H = read_header(fid);
switch H.dataType
    case 1, prec = 'int16';  epv = 1;
    case 2, prec = 'single'; epv = 1;
    case 3, prec = 'single'; epv = 2;
    case 4, prec = 'double'; epv = 1;
    case 5, prec = 'double'; epv = 2;
    otherwise, error('verify_padding_removal:dataType', ...
                     'unsupported dataType %d in %s', H.dataType, path);
end
n = double(H.effectiveBufferSize) * epv;
fseek(fid, double(H.headerSize), 'bof');
data = zeros(n * double(H.buffersStored), 1, prec);
for i = 1:double(H.buffersStored)
    data((i-1)*n + (1:n)) = fread(fid, n, ['*' prec]);
    fseek(fid, double(H.paddingBytes), 'cof');
end
if epv == 2
    data = complex(data(1:2:end), data(2:2:end));
end
end
