# build_scripts/

Developer helper scripts. None of these are needed to *use* EchoFrame — they build
it, set up its dependencies, or check that a build works.

| Script | What it does |
|---|---|
| `build_echoframe.bat` | Automated Windows build. Walks the CUDA / MATLAB / Visual Studio combinations and reports what succeeded. The clearest reference for how a working Windows build is configured. Builds into `build_<CONFIG>/` at the repository root; set `EF_BUILD_ROOT` to put the build trees somewhere else. |
| `build_echoframe.sh` | Single-configuration Linux build — the counterpart of the `.bat`, minus the matrix: one configure, one build. Flags: `--build-dir`, `--build-type`, `--matlab-root`, `--no-mex`, `--no-python`, `--no-cli`, `--clean`, `-j N`. Checks for the GSL submodule and `VCPKG_ROOT` up front, and picks `CMAKE_CUDA_ARCHITECTURES` from the detected toolkit the same way `CMakeLists.txt` does. |
| `pack_build.ps1` | Packages a `Release/` output directory as `binaries/build_<CONFIG>/build.zip`, with the `build/Release/<file>` layout the README documents. Called by `build_echoframe.bat`; can be run on its own to repackage without rebuilding. |
| `setup_vcpkg.ps1` | Clones and bootstraps vcpkg, then installs the ports EchoFrame needs. Defaults to `C:\vcpkg`; override with `-VcpkgRoot`. |
| `verify_builds.ps1` | Build verification harness. Copies the tree to a short path to dodge Windows `MAX_PATH`, then runs the MEX, CLI and Python builds. Non-zero exit on failure. Flags: `-SkipMex`, `-SkipCli`, `-Keep`, `-Python`, `-WorkDir`. |

Run them from the repository root:

```powershell
.\build_scripts\build_echoframe.bat
.\build_scripts\setup_vcpkg.ps1
pwsh -File build_scripts/verify_builds.ps1
```

On Linux:

```bash
build_scripts/build_echoframe.sh              # everything
build_scripts/build_echoframe.sh --no-mex     # no MATLAB installed
```

Each resolves the repository root from its own location, so they also work when
invoked from inside this folder.

## Windows `MAX_PATH`

The Visual Studio generator nests intermediate files deeply -- roughly 120
characters below the build directory -- against a 260-character limit. That is
why `build_echoframe.bat` builds into `build_<CONFIG>/` at the repository root
rather than under `echoframe/cpp/src/`, and why it warns when the build path is
long enough to be a risk.

If it still overruns, build somewhere shorter:

```powershell
set EF_BUILD_ROOT=C:\efb
.\build_scripts\build_echoframe.bat
```

The packaged `binaries\build_<CONFIG>\build.zip` is written to the repository
either way. Enabling long paths (`LongPathsEnabled` under
`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`, needs a reboot) or using the
Ninja generator also works -- see the main README.

## Why `justfile` is not in here

`just` finds its `justfile` by searching *upward* from the working directory, and
every recipe uses paths relative to the repository root (`echoframe/cpp/src`,
`docker/…`). Moved into this folder, `just build` from the repository root would
stop working. It stays at the root deliberately.
