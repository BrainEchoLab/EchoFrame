# EchoFrame Container Image

A reusable OCI image for the Ubuntu 22.04 / CUDA 12.8 EchoFrame build
environment.

It is intended for people running EchoFrame from a non-Ubuntu host who want a
repeatable Ubuntu container with the required CUDA, build, Qt, and MATLAB runtime
dependencies already installed.

## Why CUDA 12.8 and not 13.x

`CMakeLists.txt` picks `CMAKE_CUDA_ARCHITECTURES` from the toolkit major version,
and only the CUDA 12 branch includes `sm_61`:

| Toolkit | Architectures selected |
|---|---|
| CUDA 12.4+ | `61;75;86;89;90` |
| CUDA 13+ | `75;80;86;89;90;100;103;121` |

CUDA 13 dropped Pascal, so a 13.x image cannot produce code that runs on a
GTX 10-series card. Switch the `FROM` line to a `13.x-devel` tag if every target
GPU is Turing or newer.

cuDNN is deliberately absent: EchoFrame links `cudart`, `cublas`, `cufft` and
`cusolver` only, all of which ship in the plain `-devel` image.

## What the image preinstalls

- Base image: `nvidia/cuda:12.8.2-devel-ubuntu22.04`.
- Ubuntu build tools: `build-essential`, `cmake`, `ninja-build`, `git`, `curl`,
  and `pkg-config` (vcpkg needs it to fix up `.pc` files).
- Python build prerequisites: `python3`, `python3-dev`, `python3-pip`,
  `python3-venv`.
- Shell tools commonly expected by host dotfiles in distrobox sessions: `fd`,
  `fzf`, `just`, `lsd`, `sheldon`, `starship`, `zellij`, and `zoxide`.
  `fzf` is installed from upstream because Ubuntu 22.04's package is too old
  for `fzf --zsh`; the rest come from `cargo` because the packaged Rust is too
  old. `libssl-dev` is present for `sheldon`'s OpenSSL dependency.
- Qt/X11 runtime libraries, needed by GUI viewers (e.g. `napari`) running with
  `QT_QPA_PLATFORM=xcb` in the container.
- MATLAB runtime libraries that are commonly missing in minimal CUDA images,
  including `libxt6`, `libxft2`, `libnss3`, `libatk-bridge2.0-0`, `libasound2`,
  `libsndfile1`, and `libxtst6` for MATLAB's bundled AWT/Swing runtime.
- `vcpkg`, bootstrapped at `/opt/vcpkg`, with the CLI dependencies pre-built into
  a binary cache at `/opt/vcpkg-cache`.

This leaves only machine-specific pieces outside the image: your checked-out
repository, the GPU runtime, and your MATLAB installation.

### How dependencies are provisioned

EchoFrame uses vcpkg in **manifest mode**. `CMakeLists.txt` points the toolchain
at `echoframe/cpp/src/vcpkg.json` and installs into the build tree's
`vcpkg_installed/` at configure time — there is no manual `vcpkg install` step,
and packages placed in `$VCPKG_ROOT/installed` by a classic-mode install would be
ignored.

So the image does not pre-install packages into `$VCPKG_ROOT`. Instead it runs
one manifest-mode install against a copy of the repository's own `vcpkg.json`
and keeps the results in `VCPKG_DEFAULT_BINARY_CACHE=/opt/vcpkg-cache`. A later
`cmake -S echoframe/cpp/src` restores `hdf5` and `matio` from that cache rather
than rebuilding them, keyed on the exact package, feature and version set CMake
asks for.

**To change the native dependency set, edit `echoframe/cpp/src/vcpkg.json`** and
rebuild the image so the cache is re-warmed. Nothing in the Dockerfile lists
packages.

## Build the image

From the **repository root** — the context is the root, not `docker/`, because
the image copies the vcpkg manifest out of the source tree. A `.dockerignore`
keeps the context to just that one file.

```bash
docker build -t echoframe-dev:cuda12.8 -f docker/ubuntu22.04-cuda12.8.Dockerfile .
```

The `cargo install` layer builds seven Rust tools from source and dominates the
build time.

### Layer order

The layers are ordered cheapest-to-invalidate last. The `cargo install` layer and
the vcpkg install come first because they are pinned — by `FZF_VERSION` and by
`echoframe/cpp/src/vcpkg.json` — and change rarely. The GTK/Python **runtime**
apt layer sits after both, because that list is the one that grows as the MATLAB
and Python sides do; keeping it last means adding a package costs one apt layer
instead of seven recompiled Rust tools and a full `hdf5`/`matio` rebuild. Nothing
below it depends on it — the vcpkg install builds C/C++ dependencies only, and
the user-creation layer is deliberately last of all so a changed `EF_UID`/`EF_GID`
invalidates nothing expensive.

## Testing the image from WSL (Windows hosts)

One-time setup: in Docker Desktop, **Settings → Resources → WSL Integration**,
enable your distro and Apply & Restart. Without it `docker` is on `PATH` inside
WSL but fails with *"could not be found in this WSL 2 distro"*.

Check the GPU is visible from the distro first — this needs only a recent NVIDIA
driver on the Windows side, no CUDA install inside WSL:

```bash
nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader
```

Build the image, from the repository root:

```bash
docker build -t echoframe-dev:cuda12.8 -f docker/ubuntu22.04-cuda12.8.Dockerfile .
```

Then a configure-and-build smoke test. `EF_BUILD_MEX=OFF` because MATLAB is not
in the image; `--user ef` keeps build output owned by uid 1000 rather than root:

```bash
docker run --rm --gpus all \
    -v "$PWD:/work" -w /work --user ef \
    echoframe-dev:cuda12.8 \
    bash -c 'git config --global --add safe.directory /work && \
             cmake -S echoframe/cpp/src -B /tmp/build -G Ninja \
                   -DCMAKE_BUILD_TYPE=Release \
                   -DEF_BUILD_MEX=OFF -DEF_BUILD_PYTHON=ON -DEF_BUILD_CLI=ON && \
             cmake --build /tmp/build -j"$(nproc)"'
```

`-G Ninja` is explicit because `ninja-build` is in the image and is faster than
make here.

Watch the configure output for `using the CUDA 12 architecture list`, which is
the branch that selects `61;75;86;89;90`. The line carries the full toolkit
version, e.g. `CUDA Toolkit 12.8.93 - using the CUDA 12 architecture list`.

Two WSL-specific caveats:

- **Build on the Linux filesystem, not `/mnt/c`.** Compiling across the 9p mount
  is several times slower. Clone the repo into `~` inside the distro for real
  work, and treat `/mnt/c` as fine only for a one-off check.
- The build tree is written to `/tmp/build` **inside the container** above, so it
  does not collide with the Windows-side `build/` directories in a shared
  checkout. Drop `-B /tmp/build` only if you want the artefacts kept.

## Create a container from the image

If you use `distrobox`:

```bash
distrobox create \
    --name matlab \
    --image echoframe-dev:cuda12.8 \
    --additional-flags "--gpus all --device nvidia.com/gpu=all"
```

Any other container workflow can use the same image tag.

## Enter and build EchoFrame

The GSL submodule is **required** — a fresh clone without it fails to configure:

```bash
git submodule update --init --recursive
```

Then, inside the container:

```bash
distrobox enter matlab

cmake -S "$HOME/EchoFrame/echoframe/cpp/src" -B "$HOME/EchoFrame/echoframe/cpp/src/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DEF_BUILD_MEX=ON \
    -DEF_BUILD_PYTHON=ON \
    -DMatlab_ROOT_DIR="$HOME/MATLAB/R2024a"

cmake --build "$HOME/EchoFrame/echoframe/cpp/src/build" -j"$(nproc)"
```

`CMAKE_CUDA_ARCHITECTURES` is chosen from the toolkit version. `CMakeLists.txt`
sets it after `project()`, so a value passed on the command line is replaced —
edit the list there to narrow it.

Without MATLAB in the container, set `-DEF_BUILD_MEX=OFF`. `EF_BUILD_CLI` is `ON`
by default and is what requires `VCPKG_ROOT`; turn it off to build with no vcpkg
dependency at all.

## Notes

- The image sets `VCPKG_ROOT=/opt/vcpkg`, `VCPKG_DEFAULT_TRIPLET=x64-linux`,
  `VCPKG_DEFAULT_BINARY_CACHE=/opt/vcpkg-cache`, `CARGO_HOME=/usr/local/cargo`,
  and `RUSTUP_HOME=/usr/local/rustup`, and puts `cargo` plus the shell tools on
  `PATH`.
- If your host MATLAB ships an older `libstdc++.so.6` than the one the MEX was
  built against, loading it fails with `version 'GLIBCXX_3.4.29' not found`.
  MATLAB loads its bundled copy first; point that symlink at the system library:

  ```bash
  ln -sf /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
      "$HOME/MATLAB/R2024a/sys/os/glnxa64/libstdc++.so.6"
  ```
- The image includes the common `xcb` plugin runtime dependencies that Qt wheels
  in Python environments need, for hosts that force `QT_QPA_PLATFORM=xcb`.
