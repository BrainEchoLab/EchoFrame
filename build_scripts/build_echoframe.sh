#!/usr/bin/env bash
# build_echoframe.sh - Single-configuration Linux build of EchoFrame.
#
# The Linux counterpart of build_echoframe.bat, minus the matrix: one configure,
# one build.
#
# Usage:
#   build_scripts/build_echoframe.sh [options]
#
#   --build-dir DIR     build tree (default: build)
#   --build-type TYPE   Release | Debug | RelWithDebInfo (default: Release)
#   --matlab-root DIR   MATLAB install (default: $Matlab_ROOT_DIR, else
#                       $HOME/MATLAB/R2024a)
#   --no-mex            skip the MATLAB MEX layer
#   --no-python         skip the Python extension module
#   --no-cli            skip the CLI (this is what needs vcpkg)
#   --clean             delete the build tree first
#   -j N                parallel jobs (default: nproc)
#   -h, --help          this message
#
# Everything it needs beyond a CUDA toolkit comes preinstalled in the container
# image (see docker/README.md).

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/echoframe/cpp/src"

BUILD_DIR="${REPO_ROOT}/build"
BUILD_TYPE="Release"
MATLAB_ROOT="${Matlab_ROOT_DIR:-${HOME}/MATLAB/R2024a}"
BUILD_MEX="ON"
BUILD_PYTHON="ON"
BUILD_CLI="ON"
CLEAN=0
JOBS="$(nproc)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# Absolute path for a directory that need not exist yet: resolve the parent,
# keep the leaf. `${dir%/}` avoids "//build" when the parent is the root.
abs_path() {
    local dir leaf
    dir="$(cd -- "$(dirname -- "$1")" && pwd)" || return 1
    leaf="$(basename -- "$1")"
    printf '%s/%s\n' "${dir%/}" "${leaf}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir)   BUILD_DIR="$(abs_path "$2")" || die "no such directory: $(dirname -- "$2")"; shift 2 ;;
        --build-type)  BUILD_TYPE="$2"; shift 2 ;;
        --matlab-root) MATLAB_ROOT="$2"; shift 2 ;;
        --no-mex)      BUILD_MEX="OFF"; shift ;;
        --no-python)   BUILD_PYTHON="OFF"; shift ;;
        --no-cli)      BUILD_CLI="OFF"; shift ;;
        --clean)       CLEAN=1; shift ;;
        -j)            JOBS="$2"; shift 2 ;;
        -h|--help)     sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

# --- preflight ------------------------------------------------------------
echo "EchoFrame Linux build"
note "repo        : ${REPO_ROOT}"
note "build dir   : ${BUILD_DIR}"
note "build type  : ${BUILD_TYPE}"
note "targets     : MEX=${BUILD_MEX} PYTHON=${BUILD_PYTHON} CLI=${BUILD_CLI}"

command -v cmake >/dev/null || die "cmake not found"
command -v nvcc  >/dev/null || die "nvcc not found; is the CUDA toolkit on PATH?"

# The GSL submodule is a gitlink: a plain clone leaves it empty and the build
# fails on a missing header rather than anything that names the cause.
if [ ! -e "${REPO_ROOT}/echoframe/cpp/libs/GSL/include/gsl/gsl" ]; then
    die "GSL submodule is empty. Run: git submodule update --init --recursive"
fi

if [ "${BUILD_CLI}" = "ON" ] && [ -z "${VCPKG_ROOT:-}" ]; then
    die "EF_BUILD_CLI is ON but VCPKG_ROOT is unset. Set it, or pass --no-cli.
       Dependencies come from echoframe/cpp/src/vcpkg.json in manifest mode;
       no manual 'vcpkg install' is needed."
fi

if [ "${BUILD_MEX}" = "ON" ] && [ ! -d "${MATLAB_ROOT}" ]; then
    die "MATLAB not found at ${MATLAB_ROOT}. Pass --matlab-root DIR, set
       Matlab_ROOT_DIR, or pass --no-mex."
fi

# CMakeLists.txt sets CMAKE_CUDA_ARCHITECTURES, but only after the initial
# compiler check; mirror it here so that check targets the right architectures.
CUDA_VER="$(nvcc --version | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
CUDA_MAJOR="${CUDA_VER%%.*}"
if [ -z "${CMAKE_CUDA_ARCHITECTURES:-}" ]; then
    if [ "${CUDA_MAJOR}" -ge 13 ]; then
        CMAKE_CUDA_ARCHITECTURES="75;80;86;89;90;100;103;121"
    else
        CMAKE_CUDA_ARCHITECTURES="61;75;86;89;90"
    fi
fi
note "cuda        : ${CUDA_VER} -> sm ${CMAKE_CUDA_ARCHITECTURES}"
echo

if [ "${CLEAN}" = "1" ] && [ -d "${BUILD_DIR}" ]; then
    echo "removing ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi

# --- configure ------------------------------------------------------------
CONFIGURE_ARGS=(
    -S "${SOURCE_DIR}"
    -B "${BUILD_DIR}"
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
    -DCMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}"
    -DEF_BUILD_MEX="${BUILD_MEX}"
    -DEF_BUILD_PYTHON="${BUILD_PYTHON}"
    -DEF_BUILD_CLI="${BUILD_CLI}"
)
[ "${BUILD_MEX}" = "ON" ] && CONFIGURE_ARGS+=(-DMatlab_ROOT_DIR="${MATLAB_ROOT}")
[ -x /usr/bin/g++ ] && CONFIGURE_ARGS+=(-DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++)
command -v ninja >/dev/null && CONFIGURE_ARGS+=(-G Ninja)

cmake "${CONFIGURE_ARGS[@]}"
cmake --build "${BUILD_DIR}" -j "${JOBS}"

# --- report ---------------------------------------------------------------
echo
echo "build finished. Artefacts in ${BUILD_DIR}:"
found=0
for pattern in 'echoframe_mex.mexa64' 'storage.mexa64' 'echoframe*.so' 'echoframe_cli'; do
    while IFS= read -r artefact; do
        note "$(basename "${artefact}")  ($(du -h "${artefact}" | cut -f1))"
        found=1
    done < <(find "${BUILD_DIR}" -maxdepth 2 -name "${pattern}" -type f 2>/dev/null)
done
[ "${found}" = "1" ] || note "(none matched the expected names -- check the build log above)"
