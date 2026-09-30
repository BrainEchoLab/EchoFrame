build_dir := "build"
source_dir := "echoframe/cpp/src"
dockerfile := "docker/ubuntu22.04-cuda12.8.Dockerfile"
image := "echoframe-dev:cuda12.8"
distrobox_name := "matlab"
jobs := if os() == "windows" { env_var_or_default("NUMBER_OF_PROCESSORS", "4") } else { `nproc` }
make_program := if os() == "windows" { "" } else { `command -v make` }
matlab_root := if os() == "windows" { env_var_or_default("Matlab_ROOT_DIR", "C:/Program Files/MATLAB/R2024a") } else { `printf '%s' "${Matlab_ROOT_DIR:-$HOME/MATLAB/R2024a}"` }
cuda_host_compiler := if os() == "windows" { "" } else { env_var_or_default("CMAKE_CUDA_HOST_COMPILER", "/usr/bin/g++") }
default_cuda_architectures := if os() == "windows" { "" } else { `if nvcc --version 2>/dev/null | grep -Eq 'release 1[3-9]\.'; then printf '75;80;86;89;90;100;103;120;121'; elif nvcc --version 2>/dev/null | grep -Eq 'release 12\.[89]'; then printf '61;75;86;89;90;120'; else printf '61;75;86;89;90'; fi` }
cuda_architectures := env_var_or_default("CMAKE_CUDA_ARCHITECTURES", default_cuda_architectures)
# Component toggles, named after the CMake options they forward. The CLI is
# opt-in because it pulls Matio, HDF5 and ZLIB through vcpkg, which not every
# build host has.
build_cli := env_var_or_default("EF_BUILD_CLI", "OFF")
build_mex := env_var_or_default("EF_BUILD_MEX", "ON")
build_python := env_var_or_default("EF_BUILD_PYTHON", "ON")
vcpkg_root := env_var_or_default("VCPKG_ROOT", "C:/vcpkg")
vcpkg_triplet := "x64-windows-static"
test_img := env_var_or_default("HOME", "") / "ef_test.img"
test_mnt := "/tmp/ef_test_mnt"
test_img_size := "50G"

help:
    @just --list

# Configure and build.
all: configure build

# Configure the build (delegates to build_echoframe.sh on Linux/macOS).
[unix]
configure:
    #!/usr/bin/env bash
    set -euo pipefail
    flags=(--configure-only --build-dir "{{build_dir}}")
    [ "{{build_mex}}" = "ON" ] || flags+=(--no-mex)
    [ "{{build_python}}" = "ON" ] || flags+=(--no-python)
    [ "{{build_cli}}" = "OFF" ] || flags+=(--cli)
    "{{justfile_directory()}}/build_scripts/build_echoframe.sh" "${flags[@]}"

[windows]
configure:
    # Explicit vcpkg toolchain/static triplet; override the vcpkg location
    # with $VCPKG_ROOT if it's not at C:/vcpkg.
    cmake -S {{source_dir}} -B {{build_dir}} -G "Visual Studio 17 2022" -A x64 \
        -DCMAKE_BUILD_TYPE=Release \
        -DEF_BUILD_CLI={{build_cli}} \
        -DEF_BUILD_MEX={{build_mex}} \
        -DEF_BUILD_PYTHON={{build_python}} \
        -DCMAKE_TOOLCHAIN_FILE="{{vcpkg_root}}/scripts/buildsystems/vcpkg.cmake" \
        -DCMAKE_PREFIX_PATH="{{vcpkg_root}}/installed/{{vcpkg_triplet}}" \
        -DMatlab_ROOT_DIR="{{matlab_root}}"

# List the build artefacts, with sizes.
[unix]
report:
    #!/usr/bin/env bash
    set -euo pipefail
    found=0
    while IFS= read -r artefact; do
        printf '%s  (%s)\n' "$(basename "$artefact")" "$(du -h "$artefact" | cut -f1)"
        found=1
    done < <(find "{{build_dir}}" -maxdepth 2 \
        \( -name 'echoframe_mex.mexa64' -o -name 'storage.mexa64' \
           -o -name 'echoframe*.so' -o -name 'echoframe*.pyd' \
           -o -name 'echoframe_cli' \) -type f 2>/dev/null)
    [ "$found" = "1" ] || echo "(no artefacts matched -- check the build log)"

# Build all targets.
[unix]
build:
    cmake --build {{build_dir}} -j {{jobs}}

[windows]
build:
    cmake --build {{build_dir}} --config Release -- /m:{{jobs}}

# Build a single target (e.g. `just build-target echoframe_cli`).
[unix]
build-target target:
    cmake --build {{build_dir}} -j {{jobs}} --target {{target}}

[windows]
build-target target:
    cmake --build {{build_dir}} --config Release --target {{target}} -- /m:{{jobs}}

# Remove the build directory.
[unix]
clean:
    rm -rf {{build_dir}}

# Remove the build directory.
[windows]
clean:
    if exist {{build_dir}} rmdir /s /q {{build_dir}}

# Create a 50G loop-mounted ext4 filesystem at /tmp/ef_test_mnt for testing the O_DIRECT storage path.
[linux]
test-mount:
    #!/usr/bin/env bash
    set -euo pipefail
    # A compressed/tmpfs disk silently ignores O_DIRECT alignment -- see
    # LinuxFileIO.h -- so this gives a real ext4 mount to test against.
    if mountpoint -q {{test_mnt}}; then
        echo "{{test_mnt}} is already mounted"
        exit 0
    fi
    truncate -s {{test_img_size}} {{test_img}}
    mkfs.ext4 -q {{test_img}}
    mkdir -p {{test_mnt}}
    sudo mount -o loop {{test_img}} {{test_mnt}}
    sudo chown "$(id -u):$(id -g)" {{test_mnt}}
    echo "Mounted {{test_img}} at {{test_mnt}}"

# Unmount and remove the test filesystem created by test-mount.
[linux]
test-unmount:
    #!/usr/bin/env bash
    set -euo pipefail
    if mountpoint -q {{test_mnt}}; then
        sudo umount {{test_mnt}}
    fi
    rm -f {{test_img}}

# Build the CUDA 12.8 dev image. Context is the repo root, not docker/: the
# image copies echoframe/cpp/src/vcpkg.json out of the source tree.
docker-build:
    docker build -t {{image}} -f {{dockerfile}} .

# Recreate the distrobox from the dev image.
distrobox-recreate:
    distrobox rm --force {{distrobox_name}} || true
    DBX_NON_INTERACTIVE=1 distrobox create \
        --yes \
        --no-entry \
        --name {{distrobox_name}} \
        --image {{image}} \
        --nvidia
