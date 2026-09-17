function check_echoframe_path(ECHOFRAME_PATH)
%CHECK_ECHOFRAME_PATH  Verify ECHOFRAME_PATH is set and points at a real folder.
% Called by the example and clinic acquisition/processing scripts, early in setup.
%
%  CHECK_ECHOFRAME_PATH() errors if the ECHOFRAME_PATH environment variable is
%  unset, or if it is set but does not name an existing folder. It returns
%  nothing and does nothing when the path is valid.
%
%  The ECHOFRAME_PATH argument is ignored. The function reads the environment
%  variable itself; callers pass the value only for readability.
%
%  See also SETUP_ECHOFRAME_PATHS, which sets the variable.

ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
if isempty(ECHOFRAME_PATH)
    error(['ECHOFRAME_PATH is not set. Please run the setup script and add your EchoFrame path to it. ', ...
        'For example: run(''<repo>/echoframe/matlab/core/setup/setup_echoframe_paths.m'').']);
elseif ~isfolder(ECHOFRAME_PATH)
    error(['ECHOFRAME_PATH (', ECHOFRAME_PATH, ') is set but not a valid folder. ', ...
        'Please run the setup script and ensure the path is correct. ', ...
        'For example: run(''<repo>/echoframe/matlab/core/setup/setup_echoframe_paths.m'').']);
end

end