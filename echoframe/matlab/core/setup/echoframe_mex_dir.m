function mexDir = echoframe_mex_dir(repoRoot)
%ECHOFRAME_MEX_DIR Directory holding the echoframe_mex build to use.
%
%   D = ECHOFRAME_MEX_DIR() resolves against ECHOFRAME_PATH.
%   D = ECHOFRAME_MEX_DIR(ROOT) resolves against ROOT. Returns '' if no build
%   is found; callers addpath the result when it is non-empty.
%
%   EF_MEX_DIR (or MEX_DIR) pins a build and skips the search. Otherwise every
%   cpp/src/build*/Release is considered and the most recently built one wins,
%   because the build directory name carries the CUDA and MATLAB versions and
%   an older one left behind still holds a loadable binary.

if nargin < 1 || isempty(repoRoot)
    repoRoot = getenv('ECHOFRAME_PATH');
end

for pinned = {getenv('EF_MEX_DIR'), getenv('MEX_DIR')}
    if ~isempty(pinned{1}) && isfolder(pinned{1})
        mexDir = pinned{1};
        return;
    end
end

mexName = ['echoframe_mex.' mexext];
% Current layout first, then the pre-restructure core/ one.
roots = { fullfile(repoRoot, 'echoframe', 'cpp', 'src'), ...
          fullfile(repoRoot, 'core', 'cpp', 'src') };

cand = {};
when = [];
for r = 1:numel(roots)
    if ~isfolder(roots{r}), continue; end
    builds = dir(fullfile(roots{r}, 'build*'));
    for b = 1:numel(builds)
        if ~builds(b).isdir, continue; end
        % Release/ on Windows multi-config generators, the build root on Linux.
        for sub = {'Release', ''}
            d = fullfile(roots{r}, builds(b).name, sub{1});
            f = dir(fullfile(d, mexName));
            if ~isempty(f)
                cand{end+1} = d;               %#ok<AGROW>
                when(end+1) = f(1).datenum;    %#ok<AGROW>
            end
        end
    end
end

if isempty(cand)
    mexDir = '';
    return;
end

[~, newest] = max(when);
mexDir = cand{newest};
if numel(cand) > 1
    fprintf('echoframe_mex: %s (newest of %d builds)\n', mexDir, numel(cand));
end
end
