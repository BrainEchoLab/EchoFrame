function ok = echoframe_cleanup_dir(p)
%ECHOFRAME_CLEANUP_DIR  Remove a test output folder, best effort.
%
%  OK = ECHOFRAME_CLEANUP_DIR(P) deletes P and everything under it, retrying
%  briefly, and warns instead of erroring when it cannot. Returns whether the
%  folder is gone.
%
%  Call it after echoframe_mex('destroy'), which is what closes the storage
%  files. `clear mex` does not: echoframe_mex calls mexLock, so the module stays
%  resident with its handles open and the delete fails with the folder in use.
%
%  The retry covers a handle Windows has not released yet, and a scanner walking
%  a freshly written file.
%
%  Place the call after the last assertion and above any early return. These
%  harnesses error out on failure, so a failing run keeps its data to inspect.
%
%  See also ECHOFRAME_DATA_ROOT, CLEAN_EMPTY_FILES.

ok = true;
if nargin < 1 || isempty(p) || ~isfolder(p), return; end

msg = '';
for attempt = 1:5
    [ok, msg] = rmdir(p, 's');
    if ok, return; end
    pause(0.3);
end

ok = false;
warning('echoframe_cleanup_dir:failed', ...
        ['Could not remove %s (%s). Check that echoframe_mex(''destroy'') ran ' ...
         'first; it is test output and safe to delete by hand.'], p, strtrim(msg));
end
