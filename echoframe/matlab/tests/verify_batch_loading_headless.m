% verify_batch_loading_headless - MEX-free unit test of the batch_loading class.
%
% batch_loading only reads a .dat and yields array slabs -- it never calls
% echoframe_mex -- so its correctness is checked here against KNOWN synthetic data
% by direct array comparison, no MEX and no GPU. read_header is the only EchoFrame
% dependency.
%
% For each window regime (overlapping, tiling, gapped, and a PRIME frame count)
% and each type (forBF, forRF), the budget is swept from one ensemble up to the
% whole recording. At every budget it asserts the yielded windows match an
% independent single-shot set, slabs are uniform, the split is exact
% (nBatches*framesPerBatch == totalFrames), and the mode/sizing are right (largest
% divisor that fits, or one whole-load slab). A final section checks budget
% utilisation: whole-fit and batches at 3/4, 2/4, 1/4 of the budget.
%
% Prereq: ECHOFRAME_PATH (for read_header + batch_loading on the path).
% No MEX, no GPU, no elevated privileges. Errors out (non-zero exit) on any FAIL.

%% Paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));

% The MEX + storage gateways under test. addpath prepends, so this takes
% priority over any other copy on the path (binaries/, ...).
ef_release = echoframe_mex_dir();
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release
check_echoframe_path(ECHOFRAME_PATH);

tmp = tempname; mkdir(tmp);
fail = 0;

%% Syntax check on the class under test
fprintf('=== checkcode ===\n');
msgs = checkcode(which('batch_loading'), '-struct');
errs = msgs(arrayfun(@(m) contains(lower(m.message),'parse') || contains(lower(m.message),'error'), msgs));
fprintf('  batch_loading.m: %d msg, %d error-ish\n', numel(msgs), numel(errs));
for e = 1:numel(errs), fprintf('    L%d: %s\n', errs(e).line, errs(e).message); fail = fail+1; end

%% Synthetic files (T = 24 slow-time units)
M = 3; nRepeats_buf = 4; nBuffers = 6; padding = 16;
T = nBuffers*nRepeats_buf;
knownBF = complex(zeros(M, T, 'single'));
for c = 1:T, knownBF(:,c) = complex(single(c*10+(1:M)'), single(-(c*10+(1:M)'))); end
bfpath = fullfile(tmp,'bf_acq.dat');
write_dat(bfpath, nBuffers, M*nRepeats_buf, padding, @(fid,b) writeBF(fid, knownBF, b, nRepeats_buf));

rowsPerRepeat = 2; nChannels = 3;
knownRF = zeros(rowsPerRepeat*T, nChannels, 'int16');
for r = 1:T
    rows = (r-1)*rowsPerRepeat + (1:rowsPerRepeat);
    for ch = 1:nChannels, knownRF(rows,ch) = int16(r*100 + (1:rowsPerRepeat)'*10 + ch); end
end
rfpath = fullfile(tmp,'rf_acq.dat');
write_dat(rfpath, nBuffers, rowsPerRepeat*nRepeats_buf*nChannels, padding, ...
          @(fid,b) writeRF(fid, knownRF, b, nRepeats_buf, rowsPerRepeat));

% Regimes: ens, shift, note. totalFrames = floor((24-ens)/shift)+1.
regimes = {
    2  2  'tiling   (T=12 frames, many divisors)'
    4  4  'tiling   (T=6 frames)'
    6  2  'overlap  (T=10 frames)'
    4  2  'overlap  (T=11 frames, PRIME -> must degrade to fpb=1)'
    2  5  'gapped   (T=5 frames)'
    3  7  'gapped   (T=4 frames)'
};

fprintf('=== forBF (budget sweep) ===\n');
for r = 1:size(regimes,1)
    [ens, shift] = regimes{r,1:2};
    [nCfg, nBad] = sweepBF(bfpath, M, T, ens, shift, knownBF);
    fprintf('  %-54s %2d budgets, %d fail\n', regimes{r,3}, nCfg, nBad); fail = fail + nBad;
end
fprintf('=== forRF (budget sweep) ===\n');
for r = 1:size(regimes,1)
    [ens, shift] = regimes{r,1:2};
    [nCfg, nBad] = sweepRF(rfpath, rowsPerRepeat, nChannels, nRepeats_buf, T, ens, shift, knownRF);
    fprintf('  %-54s %2d budgets, %d fail\n', regimes{r,3}, nCfg, nBad); fail = fail + nBad;
end

%% Budget utilisation: whole-fit + batches at 3/4, 2/4, 1/4 of the budget (BF, 1x)
% Each case sets the budget (in units) so the loader's chosen slab is a known
% fraction of it -- proving the slab fits WITHIN the budget (1x, never 2x) and
% the divisor sizing lands on the intended frames-per-batch. The T=24 file above
% covers whole-fit and the 3/4 (multi-frame) case; a second T=28 file gives a
% PRIME frame count (7) for the quarter cases. Fraction, mode and losslessness
% are all asserted together.
knownBF28 = complex(zeros(M, 28, 'single'));
for c = 1:28, knownBF28(:,c) = complex(single(c*10+(1:M)'), single(-(c*10+(1:M)'))); end
bfpath28 = fullfile(tmp,'bf28.dat');
write_dat(bfpath28, 7, M*nRepeats_buf, padding, @(fid,b) writeBF(fid, knownBF28, b, nRepeats_buf));

fprintf('=== budget utilisation (BF, 1x) ===\n');
%        path      M  T  ens shift budgetU fpb whole  frac      known      label
util = { bfpath    M 24  8   8    24    3   true  1        knownBF   'whole-fit (fills budget)'
         bfpath    M 24  3   3     8    2   false 3/4      knownBF   'batch = 3/4 of budget'
         bfpath28  M 28  4   4     8    1   false 2/4      knownBF28 'batch = 2/4 of budget'
         bfpath28  M 28  4   4    16    1   false 1/4      knownBF28 'batch = 1/4 of budget' };
for r = 1:size(util,1)
    nBad = utilCaseBF(util{r,1}, util{r,2}, util{r,3}, util{r,4}, util{r,5}, ...
                      util{r,6}, util{r,7}, util{r,8}, util{r,9}, util{r,10}, util{r,11});
    fail = fail + nBad;
end

rmdir(tmp,'s');
if fail > 0
    error('verify_batch_loading_headless:fail', '%d check(s) failed.', fail);
end
fprintf('\n==================== ALL PASSED ====================\n');

%% ---- sweep drivers ----
% budgetUnits swept from ens (one ensemble) to T+shift (past the whole-fit point).
function [nCfg, nBad] = sweepBF(path, M, T, ens, shift, knownBF)
    unitBytes = M*8; nCfg = 0; nBad = 0;
    for budgetUnits = ens : T+shift
        budget = budgetUnits * unitBytes / 1024^3;
        fid = fopen(path); H = read_header(fid);
        L = batch_loading.forBF(fid, H, M, ens, shift, budget);
        frames = {}; nSlab = 0; sizeOK = true;
        while L.hasNext()
            slab = L.next(); nSlab = nSlab + 1;
            sizeOK = sizeOK && (size(slab,2) == L.slabLen);
            nWin = floor((size(slab,2)-ens)/shift) + 1;      % floor: whole slab may have a trailing tail
            for j = 1:nWin, frames{end+1} = slab(:, (j-1)*shift + (1:ens)); end %#ok<AGROW>
        end
        fclose(fid);
        ok = invariantsOK(L, T, ens, shift, budgetUnits, nSlab, sizeOK) && ...
             windowsOK(frames, @(f) knownBF(:, (f-1)*shift + (1:ens)), T, ens, shift);
        nCfg = nCfg + 1; nBad = nBad + ~ok;
        if ~ok, fprintf('      FAIL budgetUnits=%d fpb=%d nB=%d whole=%d\n', ...
                        budgetUnits, L.framesPerBatch, L.nBatches, L.wholeLoad); end
    end
end

function [nCfg, nBad] = sweepRF(path, rpr, nCh, nRep, T, ens, shift, knownRF)
    unitBytes = rpr*nCh*2; nCfg = 0; nBad = 0;
    for budgetUnits = ens : T+shift
        budget = budgetUnits * unitBytes / 1024^3;
        fid = fopen(path); H = read_header(fid);
        L = batch_loading.forRF(fid, H, rpr, nCh, nRep, ens, shift, budget);
        frames = {}; nSlab = 0; sizeOK = true;
        while L.hasNext()
            slab = L.next(); nSlab = nSlab + 1;
            sizeOK = sizeOK && (size(slab,1) == L.slabLen*rpr);
            nWin = floor((size(slab,1)/rpr - ens)/shift) + 1;
            for j = 1:nWin, frames{end+1} = slab((j-1)*shift*rpr + (1:ens*rpr), :); end %#ok<AGROW>
        end
        fclose(fid);
        ok = invariantsOK(L, T, ens, shift, budgetUnits, nSlab, sizeOK) && ...
             windowsOK(frames, @(f) knownRF((f-1)*shift*rpr + (1:ens*rpr), :), T, ens, shift);
        nCfg = nCfg + 1; nBad = nBad + ~ok;
        if ~ok, fprintf('      FAIL budgetUnits=%d fpb=%d nB=%d whole=%d\n', ...
                        budgetUnits, L.framesPerBatch, L.nBatches, L.wholeLoad); end
    end
end

% One budget-utilisation case: assert the chosen slab is expFrac of the budget,
% the mode/frames-per-batch are as intended, and the windows are still lossless.
function nBad = utilCaseBF(path, M, T, ens, shift, budgetUnits, expFpb, expWhole, expFrac, knownBF, label)
    unitBytes = M*8;
    budget = budgetUnits * unitBytes / 1024^3;
    fid = fopen(path); H = read_header(fid);
    L = batch_loading.forBF(fid, H, M, ens, shift, budget);
    frames = {}; nSlab = 0; sizeOK = true;
    while L.hasNext()
        slab = L.next(); nSlab = nSlab + 1;
        sizeOK = sizeOK && (size(slab,2) == L.slabLen);
        nWin = floor((size(slab,2)-ens)/shift) + 1;
        for j = 1:nWin, frames{end+1} = slab(:, (j-1)*shift + (1:ens)); end %#ok<AGROW>
    end
    fclose(fid);
    frac = L.slabLen / budgetUnits;
    ok = invariantsOK(L, T, ens, shift, budgetUnits, nSlab, sizeOK) && ...
         windowsOK(frames, @(f) knownBF(:, (f-1)*shift + (1:ens)), T, ens, shift) && ...
         (L.framesPerBatch == expFpb) && (L.wholeLoad == expWhole) && ...
         (abs(frac - expFrac) < 1e-9);
    nBad = double(~ok);
    verdict = 'OK'; if ~ok, verdict = 'FAIL'; end
    fprintf('  %-26s fpb=%d nB=%d whole=%d slab=%2d/%2d = %.3f (want %.3f)  %s\n', ...
            label, L.framesPerBatch, L.nBatches, L.wholeLoad, L.slabLen, budgetUnits, ...
            frac, expFrac, verdict);
end

%% ---- checks (independent of batch_loading's internals) ----
function ok = invariantsOK(L, T, ens, shift, budgetUnits, nSlab, sizeOK)
    totalFrames = floor((T-ens)/shift) + 1;
    ok = (L.totalFrames == totalFrames) && (nSlab == L.nBatches) && sizeOK;
    ok = ok && (L.nBatches == totalFrames / L.framesPerBatch);     % exact split

    if T <= budgetUnits
        % Whole recording fits the budget -> one preallocated slab of all T units.
        ok = ok && L.wholeLoad;
        ok = ok && (L.framesPerBatch == totalFrames) && (L.nBatches == 1) && (L.slabLen == T);
    else
        % Batched: largest divisor of totalFrames whose slab fits the budget.
        ok = ok && ~L.wholeLoad;
        maxUnits  = max(1, budgetUnits);                           % batch_loading uses budget/unitBytes (1x)
        maxFrames = floor((maxUnits-ens)/shift) + 1;
        ok = ok && (mod(totalFrames, L.framesPerBatch) == 0);      % divides
        ok = ok && (L.framesPerBatch <= maxFrames);                % fits budget
        ok = ok && (L.slabLen == (L.framesPerBatch-1)*shift + ens);
        for d = L.framesPerBatch+1 : maxFrames                     % maximality
            if mod(totalFrames, d) == 0, ok = false; break; end
        end
    end
end
function ok = windowsOK(frames, knownWin, T, ens, shift)
    totalFrames = floor((T-ens)/shift) + 1;
    ok = numel(frames) == totalFrames;
    for f = 1:min(totalFrames, numel(frames))
        ok = ok && isequal(frames{f}, knownWin(f));
    end
end

%% ---- synthetic file writers ----
function write_dat(path, nBuffers, bufferElems, padding, writeBufFcn)
    headerSize = 64; fid = fopen(path,'w');
    fwrite(fid, uint64([0 headerSize nBuffers bufferElems padding]'), 'uint64');
    fwrite(fid, zeros(headerSize-5*8,1,'uint8'), 'uint8');
    for b = 1:nBuffers, writeBufFcn(fid,b); fwrite(fid, zeros(padding,1,'uint8'),'uint8'); end
    fclose(fid);
end
function writeBF(fid, knownBF, b, nRep)
    cols = knownBF(:, (b-1)*nRep + (1:nRep)); v = cols(:);
    inter = zeros(2*numel(v),1,'single'); inter(1:2:end)=real(v); inter(2:2:end)=imag(v);
    fwrite(fid, inter, 'single');
end
function writeRF(fid, knownRF, b, nRep, rpr)
    rows = (b-1)*nRep*rpr + (1:nRep*rpr); fwrite(fid, knownRF(rows,:), 'int16');
end
