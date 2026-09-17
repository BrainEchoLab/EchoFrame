function [fits, info] = check_gpu_memory_fit(ReceiveSpec, ReconSpec, PDISpec)
%CHECK_GPU_MEMORY_FIT  Estimate EchoFrame GPU memory usage against available VRAM.
% Called by benchmark_echoframe.m (both the timing sweeps and its 'plan' mode).
%
%  [FITS, INFO] = CHECK_GPU_MEMORY_FIT(ReceiveSpec, ReconSpec, PDISpec)
%  returns::
%
%    FITS  logical, true if the configuration is expected to fit on the GPU.
%    INFO  struct with fields:
%      .estimated_bytes   peak GPU usage estimate (with safety margin)
%      .available_bytes   free VRAM on the device
%      .total_bytes       total VRAM
%      .breakdown         per-buffer byte counts
%      .suggestions       tuning hints (empty cell array if it fits)
%
%  VRAM is queried via the Parallel Computing Toolbox (gpuDevice) with a
%  fallback to `nvidia-smi`. If neither is available the function errors.

SAFETY = 1.3; % 30% headroom for cuFFT workspace and transient allocations

% --- Dimensions used by the estimator ---
nFastTime = double(ReceiveSpec.nSamplesIQ);
nChannels = double(ReceiveSpec.nChannels);
nTX       = double(ReceiveSpec.nTransmissions);
nRepeats  = double(ReceiveSpec.nRepeats);
nSlowTime = nRepeats;

nz = double(ReconSpec.nz);
nx = double(ReconSpec.nx);

BF2 = 8; % float2 = 8 bytes
F4  = 4; % float  = 4 bytes
I4  = 4; % int32  = 4 bytes

% --- Per-buffer estimates (conservative upper bound) ---
bd.rfPadded      = nFastTime * nTX * nSlowTime * nChannels * BF2;
bd.rfFourier     = bd.rfPadded;
bd.bf            = nz * nx * nRepeats * BF2;
bd.delayIndices  = nFastTime * nChannels * nTX * I4;
bd.interpWeights = nFastTime * nChannels * nTX * BF2;

nEns = max(0, floor((nRepeats - double(PDISpec.ensembleSize)) / double(PDISpec.shiftSize)) + 1);
bd.pdi         = nz * nx * nEns * F4;
bd.covariance  = double(PDISpec.ensembleSize)^2 * F4;
bd.cufftExtra  = round(bd.rfPadded * 0.1); % cuFFT plan workspace (rough)

info.breakdown = bd;
estimate = sum(struct2array(bd));
info.estimated_bytes = estimate * SAFETY;

% --- Query GPU VRAM ---
[info.total_bytes, info.available_bytes] = query_gpu_memory();

fits = info.estimated_bytes <= info.available_bytes;

% --- Build suggestions ---
info.suggestions = {};
if ~fits
    fnames = fieldnames(bd);
    sizes  = cellfun(@(f) bd.(f), fnames);
    [~, idx] = max(sizes);
    dom = fnames{idx};
    budget = info.available_bytes / SAFETY;

    switch dom
        case {'rfPadded', 'rfFourier'}
            other = estimate - bd.rfPadded - bd.rfFourier;
            perTX = 2 * nFastTime * nSlowTime * nChannels * BF2;
            maxTX = max(0, floor((budget - other) / perTX));
            info.suggestions{end+1} = sprintf( ...
                'Padded RF buffers dominate (2 x %.2f GB). Reduce nTransmissions to <= %d (current = %d).', ...
                bd.rfPadded/1e9, maxTX, nTX);
        case 'bf'
            other = estimate - bd.bf;
            perRepeat = nz * nx * BF2;
            maxRepeats = max(0, floor((budget - other) / perRepeat));
            info.suggestions{end+1} = sprintf( ...
                'BF buffer dominates (%.2f GB). Reduce nRepeats to <= %d (current = %d).', ...
                bd.bf/1e9, maxRepeats, nRepeats);
        case 'pdi'
            info.suggestions{end+1} = sprintf( ...
                'PDI output dominates (%.2f GB). Reduce grid size (extraVoxelsX / extraVoxelsZ) or disable getPDI.', ...
                bd.pdi/1e9);
        otherwise
            info.suggestions{end+1} = sprintf( ...
                'Buffer "%s" dominates (%.2f GB). Reduce associated dimensions.', ...
                dom, bd.(dom)/1e9);
    end
end

end

function [total, free] = query_gpu_memory()
% Prefer nvidia-smi because it does not initialize a CUDA context.
% Calling gpuDevice() claims the PCT primary context and can invalidate
% cuBLAS / cuFFT handles that echoframe_mex creates afterwards.

try
    [status, out] = system('nvidia-smi --query-gpu=memory.total,memory.free --format=csv,noheader,nounits');
    if status == 0
        vals = sscanf(out, '%f, %f');
        if numel(vals) >= 2
            total = vals(1) * 1024^2; % MiB -> bytes
            free  = vals(2) * 1024^2;
            return;
        end
    end
catch
end

% Fallback: PCT. Note this initializes a CUDA context, which may conflict
% with MEX-owned handles. Only use if nvidia-smi is unavailable.
try
    g = gpuDevice();
    total = double(g.TotalMemory);
    free  = double(g.AvailableMemory);
    return;
catch
end

error('check_gpu_memory_fit:noGPUInfo', ...
      'Could not query GPU memory. Ensure nvidia-smi is on PATH, or install the Parallel Computing Toolbox.');
end
