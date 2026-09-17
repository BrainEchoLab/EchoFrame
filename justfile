build_dir := "build"
source_dir := "echoframe/cpp/src"
dockerfile := "docker/ubuntu22.04-cuda12.8.Dockerfile"
image := "echoframe-dev:cuda12.8"
distrobox_name := "matlab"
jobs := if os() == "windows" { env_var_or_default("NUMBER_OF_PROCESSORS", "4") } else { `nproc` }
make_program := if os() == "windows" { "" } else { `command -v make` }
matlab_root := if os() == "windows" { env_var_or_default("Matlab_ROOT_DIR", "C:/Program Files/MATLAB/R2024a") } else { `printf '%s' "${Matlab_ROOT_DIR:-$HOME/MATLAB/R2024a}"` }
cuda_host_compiler := if os() == "windows" { "" } else { env_var_or_default("CMAKE_CUDA_HOST_COMPILER", "/usr/bin/g++") }
cuda_architectures := env_var_or_default("CMAKE_CUDA_ARCHITECTURES", "61;75;86;89;90")
vcpkg_root := env_var_or_default("VCPKG_ROOT", "C:/vcpkg")
vcpkg_triplet := "x64-windows-static"
test_img := env_var_or_default("HOME", "") / "ef_test.img"
test_mnt := "/tmp/ef_test_mnt"
test_img_size := "50G"

help:
    @just --list

# Configure and build.
all: configure build

# Configure the CMake build (Unix Makefiles on Linux/macOS, Visual Studio 2022 on Windows).
[unix]
configure:
    # Set CUDA archs up front; EchoFrame's CMakeLists sets them too late for
    # CMake's initial CUDA compiler checks.
    cmake -S {{source_dir}} -B {{build_dir}} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MAKE_PROGRAM={{make_program}} \
        -DCMAKE_CUDA_HOST_COMPILER={{cuda_host_compiler}} \
        -DCMAKE_CUDA_ARCHITECTURES="{{cuda_architectures}}" \
        -DEF_BUILD_CLI=ON \
        -DEF_BUILD_MEX=ON \
        -DEF_BUILD_PYTHON=ON \
        -DMatlab_ROOT_DIR="{{matlab_root}}"

[windows]
configure:
    # Explicit vcpkg toolchain/static triplet; override the vcpkg location
    # with $VCPKG_ROOT if it's not at C:/vcpkg.
    cmake -S {{source_dir}} -B {{build_dir}} -G "Visual Studio 17 2022" -A x64 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="{{vcpkg_root}}/scripts/buildsystems/vcpkg.cmake" \
        -DCMAKE_PREFIX_PATH="{{vcpkg_root}}/installed/{{vcpkg_triplet}}"

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
