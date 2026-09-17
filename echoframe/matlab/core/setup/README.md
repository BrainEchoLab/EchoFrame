# core/setup/

`ECHOFRAME_PATH` handling. Everything else in EchoFrame assumes this has been done.

- **`setup_echoframe_paths.m`** — run once per session, before anything else. Derives
  the repository root from its own location, sets `ECHOFRAME_PATH` for the session,
  persists it for future sessions with `setx`, and runs
  `addpath(genpath(repoRoot))`.
- **`check_echoframe_path.m`** — errors if `ECHOFRAME_PATH` is unset or does not name
  an existing folder. Called early by the example and clinic scripts. It reads the
  environment variable itself; the argument callers pass is ignored and exists only
  for readability.
- **`echoframe_mex_dir.m`** — resolves which `cpp/src/build*/Release` holds the
  `echoframe_mex` build to use, returning `''` when there is none. `EF_MEX_DIR` (or
  `MEX_DIR`) pins one; otherwise the most recently built directory wins, since the
  name carries the CUDA and MATLAB versions and an older one still holds a loadable
  binary.
- **`ef_log.m`** — prints a line only when `EF_LOG_LEVEL` allows it, so a script can
  offer `verbose` and `trace` detail without a switch of its own. `EF_LOG()` with no
  arguments returns the current level. The levels and the parsing match the C++ side
  (`write_stats.h`), so one variable governs both halves of the log; see the
  environment table in [`../storage/README.md`](../storage/README.md).

Because the path is added with `genpath`, MATLAB resolves EchoFrame functions **by
basename, not by folder**. Moving a `.m` file within the repository breaks nothing —
but two files anywhere in the tree sharing a name will shadow each other.

> `setup_echoframe_paths.m` is a script and begins with `clear`, so it wipes the
> caller's workspace. It also writes your persistent user environment via `setx`.
