% ==============================================================================
% Title:       Setup Offline Beamforming
% Author:      Pieter Kruizinga ans Stefanos Florescu
% Date:
% Version:     0.3
%
% Purpose:     This script will set up the paths for EchoFrame as
%              environment variables
%
% ==============================================================================
%
clear; close all;

% Folder that holds *this* script
thisDir  = fileparts(mfilename('fullpath'));

% Four levels up (echoframe/matlab/core/setup): EchoFrame repo root
repoRoot = fileparts(fileparts(fileparts(fileparts(thisDir))));  % ← one fileparts() per level

% Make it visible in this MATLAB session
setenv('ECHOFRAME_PATH', repoRoot);

% Persist for future Windows sessions (optional)
[status, cmdout] = system(sprintf('setx ECHOFRAME_PATH "%s"', repoRoot));
if status ~= 0
    warning('setx failed:\n%s', cmdout);
end

fprintf('ECHOFRAME_PATH = %s\n', getenv('ECHOFRAME_PATH'));

% If you also want MATLAB to see all sub-folders right now:
addpath(genpath(repoRoot));

% The MEX + storage gateways under test. addpath prepends, so this takes
% priority over any other copy on the path (binaries/, ...).
ef_release = echoframe_mex_dir(repoRoot);
if ~isempty(ef_release)
    addpath(ef_release);
end
clear ef_release

