classdef batch_loading < handle
% batch_loading - Stream a stored EchoFrame .dat in memory-bounded, lossless batches.
%
% A long recording may not fit in host memory all at once. This iterator reads
% it a batch at a time, cutting on the PDI window grid and carrying the trailing
% (ensembleSize - shiftSize) slow-time samples between batches, so every window a
% single-shot load would form is formed in exactly one batch. The frame set is
% therefore identical to loading the whole recording at once -- no frames are
% lost at batch boundaries.
%
% Two modes, chosen from MEMORY_BUDGET_GB:
%   * Whole load -- if the whole recording fits the budget, it is read into one
%     preallocated array and returned as a single slab (one process call, ~1x
%     memory). This is what a large budget gives you.
%   * Batched    -- otherwise, frames-per-batch is the largest divisor of the
%     total frame count whose slab fits the budget. The slab is preallocated and
%     filled buffer-by-buffer, so a batch occupies up to the whole budget (~1x)
%     rather than half of it; every batch is the same length, the caller inits
%     once, and PDI saving appends equal-sized buffers. Degrades to 1 frame/batch
%     only when the total frame count is prime and does not fit whole.
%
% One "slow-time unit" is a column of the BF stack (M complex singles) or a
% repeat of the RF stack (rowsPerRepeat x nChannels int16). Both stream through
% the same engine; only the read and the storage axis differ. Construct with the
% forBF / forRF factories:
%
%   loader = batch_loading.forBF(fileID, HeaderSpec, M, ens, shift, budgetGB);
%   ReceiveSpec.nRepeats = int32(loader.slabLen);   % constant across batches
%   ... validate + init the MEX once ...
%   while loader.hasNext()
%       slab = loader.next();                       % [M, slabLen] complex single
%       PDI  = echoframe_mex('process_pdi_only', slab, saveFlag);
%   end
%
% Prereq: fileID open and positioned anywhere (the constructor seeks to the
% first buffer); HeaderSpec from read_header.

    properties (SetAccess = private)
        totalFrames        % PDI frames a single-shot load would produce
        framesPerBatch     % frames per process call (uniform)
        nBatches           % totalFrames / framesPerBatch (exact)
        slabLen            % slow-time units in every (uniform) slab
        wholeLoad          % true when the whole recording is read in one slab
    end

    properties (Access = private)
        fid                % open file handle
        padding            % per-buffer trailing padding bytes to skip
        ens
        shift
        dim                % storage axis of a unit: 2 = BF columns, 1 = RF rows
        span               % array indices per unit along dim (1 for BF, rowsPerRepeat for RF)
        readBuf            % @(fid) -> one buffer's block (unitsPerBuffer units)
        allocFull          % @(nUnits) -> preallocated empty slab of nUnits units
        unitsPerBuffer     % slow-time units in one stored buffer
        totalUnits         % total slow-time units in the whole recording
        pend               % units read from disk but not yet consumed
        carry              % overlap units handed to the next slab
        framesDone
    end

    methods
        function obj = batch_loading(fid, HeaderSpec, budgetGB, ens, shift, ...
                                     unitsPerBuffer, unitBytes, dim, span, readBuf, emptyStore, allocFull)
            % Generic constructor -- prefer the forBF / forRF factories below.
            nBuffers = double(HeaderSpec.buffersStored);
            T        = nBuffers * unitsPerBuffer;                  % total slow-time units

            if ens > T
                error('batch_loading:ensembleTooLarge', ...
                      'ensembleSize (%d) exceeds the whole recording''s slow-time (%d).', ens, T);
            end
            obj.totalFrames = max(0, floor((T - ens) / shift) + 1);

            if T * unitBytes <= budgetGB * 1024^3
                % Whole recording fits -> one preallocated load, no 2x transient.
                obj.wholeLoad      = true;
                obj.framesPerBatch = obj.totalFrames;
                obj.slabLen        = T;
            else
                % Batched. The slab is preallocated and filled buffer-by-buffer,
                % so the working set is one slab plus a single read buffer (~1x the
                % budget, not 2x). Same rule BF/RF.
                obj.wholeLoad = false;
                maxUnits = max(1, floor(budgetGB * 1024^3 / unitBytes));
                if ens > maxUnits
                    error('batch_loading:budgetTooSmall', ...
                          ['One ensemble (%d slow-time units x %.1f MB) exceeds the budget (%.1f GB). ', ...
                           'Raise the budget or lower ensembleSize.'], ...
                          ens, unitBytes/1024^2, budgetGB);
                end
                maxFrames = max(1, floor((maxUnits - ens) / shift) + 1);
                % Largest divisor of totalFrames that fits the budget -> uniform batches.
                obj.framesPerBatch = 1;
                for d = min(maxFrames, obj.totalFrames):-1:1
                    if mod(obj.totalFrames, d) == 0
                        obj.framesPerBatch = d;
                        break;
                    end
                end
                obj.slabLen = (obj.framesPerBatch - 1) * shift + ens;
            end
            obj.nBatches = obj.totalFrames / obj.framesPerBatch;

            obj.fid            = fid;
            obj.padding        = HeaderSpec.paddingBytes;
            obj.ens            = ens;
            obj.shift          = shift;
            obj.dim            = dim;
            obj.span           = span;
            obj.readBuf        = readBuf;
            obj.allocFull      = allocFull;
            obj.unitsPerBuffer = unitsPerBuffer;
            obj.totalUnits     = T;
            obj.pend           = emptyStore;
            obj.carry          = emptyStore;
            obj.framesDone     = 0;

            fseek(fid, HeaderSpec.headerSize, 'bof');   % position at the first buffer
        end

        function tf = hasNext(obj)
            tf = obj.framesDone < obj.totalFrames;
        end

        function [slab, slabLen] = next(obj)
            % Return the next window-grid slab, ready for the MEX. slabLen is the
            % number of slow-time units in it (== obj.slabLen for uniform batches).
            if obj.wholeLoad
                % Read the whole recording straight into one preallocated array:
                % no carry, no concatenation, ~1x memory.
                slab = obj.allocFull(obj.totalUnits);
                filled = 0;
                while filled < obj.totalUnits
                    idx = filled*obj.span + (1 : obj.unitsPerBuffer*obj.span);
                    if obj.dim == 1
                        slab(idx, :) = obj.readOne();
                    else
                        slab(:, idx) = obj.readOne();
                    end
                    filled = filled + obj.unitsPerBuffer;
                end
                obj.framesDone = obj.totalFrames;
                slabLen = obj.totalUnits;
                return;
            end

            framesThis = min(obj.framesPerBatch, obj.totalFrames - obj.framesDone);
            slabLen    = (framesThis - 1) * obj.shift + obj.ens;

            % Preallocate the slab and fill it in place: the carried overlap goes at
            % the front, the remaining units are read from the buffer stream one
            % buffer at a time. Nothing is concatenated, so the working set is one
            % slab plus a single read buffer (~1x the budget), never two slabs.
            slab   = obj.allocFull(slabLen);
            filled = obj.nUnits(obj.carry);
            if filled > 0
                cidx = 1 : filled * obj.span;                    % overlap from the previous slab
                if obj.dim == 1, slab(cidx, :) = obj.carry; else, slab(:, cidx) = obj.carry; end
            end
            while filled < slabLen
                if obj.nUnits(obj.pend) == 0
                    obj.pend = obj.readOne();                     % one whole buffer
                end
                take = min(obj.nUnits(obj.pend), slabLen - filled);
                src  = obj.sliceUnits(obj.pend, 1, take);
                sidx = filled * obj.span + (1 : take * obj.span);
                if obj.dim == 1, slab(sidx, :) = src; else, slab(:, sidx) = src; end
                obj.pend = obj.sliceUnits(obj.pend, take + 1, obj.nUnits(obj.pend));
                filled   = filled + take;
            end

            % Carry the overlap for the next slab: the units from the next window
            % start (framesThis*shift into this slab) onward. Empty when windows do
            % not overlap; drop the gap when they are gapped (shift > ensembleSize).
            consumed = framesThis * obj.shift;
            if obj.framesDone + framesThis < obj.totalFrames
                if consumed <= slabLen
                    obj.carry = obj.sliceUnits(slab, consumed + 1, slabLen);
                else
                    obj.carry = obj.emptyLike();
                    gap = consumed - slabLen;               % units no window covers
                    while obj.nUnits(obj.pend) < gap
                        obj.pend = cat(obj.dim, obj.pend, obj.readOne());
                    end
                    obj.pend = obj.sliceUnits(obj.pend, gap + 1, obj.nUnits(obj.pend));
                end
            end

            obj.framesDone = obj.framesDone + framesThis;
        end
    end

    methods (Access = private)
        function n = nUnits(obj, block)
            n = size(block, obj.dim) / obj.span;
        end

        function out = sliceUnits(obj, block, u0, u1)
            % Units u0..u1 (1-based) along the storage axis.
            idx = (u0 - 1) * obj.span + 1 : u1 * obj.span;
            if obj.dim == 1
                out = block(idx, :);
            else
                out = block(:, idx);
            end
        end

        function e = emptyLike(obj)
            e = obj.sliceUnits(obj.carry, 1, 0);   % 0 units, same class/orientation
        end

        function block = readOne(obj)
            block = obj.readBuf(obj.fid);
            if fseek(obj.fid, obj.padding, 'cof') ~= 0
                error('batch_loading:seek', 'fseek failed skipping buffer padding.');
            end
        end
    end

    methods (Static)
        function obj = forBF(fid, HeaderSpec, M, ens, shift, budgetGB)
            % BF stack: unit = one column of M complex singles; slab is [M, slabLen].
            bufferSize     = double(HeaderSpec.effectiveBufferSize);   % complex elems / buffer
            unitsPerBuffer = bufferSize / M;                           % = nRepeats per buffer
            readBuf    = @(fid) batch_loading.readBFBuffer(fid, M, unitsPerBuffer);
            emptyStore = complex(zeros(M, 0, 'single'));
            % Allocate the complex slab in a single shot ('like' a complex single):
            % complex(zeros(...)) would build a real array then copy it to complex,
            % transiently holding both (~1.5x the slab).
            allocFull  = @(n) zeros(M, n, 'like', complex(single(0)));
            obj = batch_loading(fid, HeaderSpec, budgetGB, ens, shift, ...
                                unitsPerBuffer, M * 8, 2, 1, readBuf, emptyStore, allocFull);
        end

        function obj = forRF(fid, HeaderSpec, rowsPerRepeat, nChannels, unitsPerBuffer, ens, shift, budgetGB)
            % RF stack: unit = one repeat (rowsPerRepeat x nChannels int16);
            % slab is [slabLen*rowsPerRepeat, nChannels].
            rowsPerBuffer = rowsPerRepeat * unitsPerBuffer;
            readBuf    = @(fid) batch_loading.readRFBuffer(fid, rowsPerBuffer, nChannels);
            emptyStore = zeros(0, nChannels, 'int16');
            allocFull  = @(n) zeros(n * rowsPerRepeat, nChannels, 'int16');
            obj = batch_loading(fid, HeaderSpec, budgetGB, ens, shift, ...
                                unitsPerBuffer, rowsPerRepeat * nChannels * 2, 1, rowsPerRepeat, readBuf, emptyStore, allocFull);
        end
    end

    methods (Static, Access = private)
        function block = readBFBuffer(fid, M, unitsPerBuffer)
            raw = fread(fid, 2 * M * unitsPerBuffer, '*single');
            if numel(raw) < 2 * M * unitsPerBuffer
                error('batch_loading:eof', 'Unexpected end of BF file while reading a buffer.');
            end
            block = reshape(raw(1:2:end) + 1i * raw(2:2:end), M, unitsPerBuffer);
        end

        function block = readRFBuffer(fid, rowsPerBuffer, nChannels)
            block = fread(fid, [rowsPerBuffer, nChannels], '*int16');
            if size(block, 1) < rowsPerBuffer
                error('batch_loading:eof', 'Unexpected end of RF file while reading a buffer.');
            end
        end
    end
end
