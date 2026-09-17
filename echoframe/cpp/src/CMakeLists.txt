cmake_minimum_required(VERSION 3.21)

# ──────────────────────────────────────────────────────────────────────────────
# Dependency provisioning -- must run before project(), which is why the two
# options below are declared here rather than with the rest of them further down.
#
# Only the CLI needs third-party libraries (matio / HDF5 / zlib). The Python
# extension and the MEX layer link none of them, so a wheel build skips this
# block entirely: `pip install .` needs nothing but CUDA and a host compiler.
#
# Dependencies are declared in vcpkg.json (manifest mode) and installed by the
# toolchain at configure time -- no manual `vcpkg install` step, and no paths
# baked into the build files.
# ──────────────────────────────────────────────────────────────────────────────
option(EF_BUILD_CLI "Build the stand-alone command-line tool" ON)

if (EF_BUILD_CLI AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    if (NOT DEFINED ENV{VCPKG_ROOT})
        message(FATAL_ERROR
            "Building the CLI requires vcpkg.\n"
            "  Install it once (https://github.com/microsoft/vcpkg), set VCPKG_ROOT to\n"
            "  the checkout, and re-run. The dependencies themselves are installed\n"
            "  automatically from vcpkg.json -- no manual `vcpkg install` is needed.\n"
            "  To build without the CLI instead, configure with -DEF_BUILD_CLI=OFF.")
    endif()

    message(STATUS "vcpkg: using VCPKG_ROOT=$ENV{VCPKG_ROOT}")
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
        CACHE STRING "vcpkg toolchain file")

    # Static libraries against the dynamic CRT. The dynamic CRT (/MD) is required
    # -- echoframe_core is shared with the Python module, which must match CPython
    # -- while static libraries keep the CLI free of redistributable DLLs. Plain
    # x64-windows-static would force /MT and clash; see the MSVC block below.
    if (CMAKE_HOST_WIN32 AND NOT DEFINED VCPKG_TARGET_TRIPLET)
        set(VCPKG_TARGET_TRIPLET "x64-windows-static-md"
            CACHE STRING "vcpkg target triplet")
    endif()
endif()


if(DEFINED ENV{CUDA_PATH})
    set(CUDA_PATH_ENV "$ENV{CUDA_PATH}")
endif()

set(CMAKE_VS_GLOBALS
    "CudaToolkitCustomDir=${CUDA_PATH_ENV}"
    # Opt out of vcpkg's user-wide MSBuild integration (`vcpkg integrate install`,
    # which writes %LOCALAPPDATA%\vcpkg\vcpkg.user.props and is imported into every
    # MSBuild project on the machine). That integration injects every package
    # installed in *that* vcpkg -- OpenCV, protobuf, abseil, zlib, ... -- into our
    # link lines even though nothing here asks for them. Harmless today because the
    # linker drops unreferenced libraries, but it makes builds depend on machine
    # state, and a symbol we later reference could be satisfied silently from an
    # unrelated vcpkg. EchoFrame gets its dependencies through the toolchain file
    # and vcpkg.json instead. This is scoped to this project; the integration keeps
    # working for everything else.
    "VCPkgLocalAppDataDisabled=true"
)

project(EchoFrame VERSION 1.0 LANGUAGES CXX CUDA)

# Custom find modules (e.g. Findmatio.cmake, which handles vcpkg's debug/release
# same-filename matio and the pkg-config-only matio port). Must precede the CLI's
# find_package(matio MODULE ...) below.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Modules")


# --------------------------------------------------------------------------
# Global compile/architectures options
# --------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# Enable relocatable device code for proper device code linking
set(CMAKE_CUDA_SEPARABLE_COMPILATION ON)

# Only let pybind11 search for Python if PYBIND11_FINDPYTHON is not explicitly set to OFF
if(NOT DEFINED PYBIND11_FINDPYTHON)
    set(PYBIND11_FINDPYTHON ON)
endif()
# message(STATUS "BIN FOLDER = ${CMAKE_SOURCE_DIR}/bin")
# set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/bin")

find_package(CUDAToolkit REQUIRED)
message(STATUS "CUDA Toolkit found at: ${CUDAToolkit_ROOT}")
message(STATUS "CUDA Toolkit version: ${CUDAToolkit_VERSION}")

if(EXISTS "${CUDAToolkit_ROOT}/targets/x86_64-linux/lib")
    set(EF_CUDA_LINK_DIR "${CUDAToolkit_ROOT}/targets/x86_64-linux/lib")
elseif(EXISTS "${CUDAToolkit_ROOT}/lib64")
    set(EF_CUDA_LINK_DIR "${CUDAToolkit_ROOT}/lib64")
endif()

if(DEFINED EF_CUDA_LINK_DIR)
    link_directories(${EF_CUDA_LINK_DIR})
endif()

if(CUDAToolkit_VERSION VERSION_GREATER_EQUAL 13)
    message(STATUS "CUDA Toolkit ${CUDAToolkit_VERSION} - using the CUDA 13 architecture list")
    add_compile_definitions(GGML_CUDA_USE_GRAPHS) # try to enable cuda graphs on cu13 build
    set(CMAKE_CUDA_ARCHITECTURES "75;80;86;89;90;100;103;121") # lowest CUDA 13 standard
elseif(CUDAToolkit_VERSION VERSION_GREATER_EQUAL 12.4)
    message(STATUS "CUDA Toolkit ${CUDAToolkit_VERSION} - using the CUDA 12 architecture list")
    add_compile_definitions(GGML_CUDA_USE_GRAPHS) # try to enable cuda graphs on cu12 build
    set(CMAKE_CUDA_ARCHITECTURES "61;75;86;89;90") # lowest CUDA 12 standard + lowest for integer intrinsics
endif()

# Optional MATLAB / MEX layer
option(EF_BUILD_MEX "Build the MATLAB MEX interface" ON)
# EF_BUILD_CLI is declared at the top of this file -- it gates vcpkg provisioning,
# which has to happen before project().
option(EF_BUILD_PYTHON "Build the Python extension module" ON)

option(ENABLE_CUDA_TIMING "Enable CUDA kernel timing instrumentation" OFF)
# --------------------------------------------------------------------------
# Common include directories
# --------------------------------------------------------------------------
set(EF_INCLUDES
    ${CMAKE_SOURCE_DIR}/efcore
    ${CMAKE_SOURCE_DIR}/beamformer
    ${CMAKE_SOURCE_DIR}/beamformer/fourier_imaging
    ${CMAKE_SOURCE_DIR}/pdi
    ${CMAKE_SOURCE_DIR}/utils
)

# Add external library includes - try both wheel layout and source layout
if(EXISTS "${CMAKE_SOURCE_DIR}/../libs/Storage/src")
    list(APPEND EF_INCLUDES ${CMAKE_SOURCE_DIR}/../libs/Storage/src)
elseif(EXISTS "${CMAKE_SOURCE_DIR}/libs/Storage/src")
    list(APPEND EF_INCLUDES ${CMAKE_SOURCE_DIR}/libs/Storage/src)
endif()

if(EXISTS "${CMAKE_SOURCE_DIR}/../libs/GSL/include")
    list(APPEND EF_INCLUDES ${CMAKE_SOURCE_DIR}/../libs/GSL/include)
elseif(EXISTS "${CMAKE_SOURCE_DIR}/libs/GSL/include")
    list(APPEND EF_INCLUDES ${CMAKE_SOURCE_DIR}/libs/GSL/include)
endif()

# --------------------------------------------------------------------------
# Core library sources
# --------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# add the new host-only file
set(EF_CORE_CUDA_SOURCES
    efcore/echoframe_core.cu
    efcore/echoframe_ci_interface.cpp
    pdi/pdi_class.cu
    pdi/pdi_kernels.cu
    beamformer/beamformer_kernels.cu
    beamformer/fourier_imaging/fourier_imaging_kernels.cu
)

# Tell CMake that .cpp files in EF_CORE_CUDA_SOURCES that launch kernels must be
# compiled as CUDA (CMake defaults to CXX for .cpp extensions).
foreach(src IN LISTS EF_CORE_CUDA_SOURCES)
    if(src MATCHES "\\.cpp$")
        set_source_files_properties(${src} PROPERTIES LANGUAGE CUDA)
    endif()
endforeach()

# --------------------------------------------------------------------------
# Core static library target
# --------------------------------------------------------------------------
add_library(echoframe_core STATIC
    ${EF_CORE_CUDA_SOURCES}
    ${EF_HOST_ONLY_SOURCES}
)
target_include_directories(echoframe_core
    PRIVATE
        ${EF_INCLUDES}
)

target_link_libraries(echoframe_core
    PRIVATE
        CUDA::cudart     
)
target_compile_definitions(echoframe_core
    PRIVATE
    NOMINMAX
    _WINSOCKAPI_=1
)

if (ENABLE_CUDA_TIMING)
  # will #define ENABLE_CUDA_TIMING=1 for BOTH host and device compiles
  target_compile_definitions(echoframe_core
    PRIVATE
      ENABLE_CUDA_TIMING=1
  )
endif()

set_target_properties(echoframe_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
set_target_properties(echoframe_core PROPERTIES
  CUDA_STANDARD        17
  CUDA_STANDARD_REQUIRED ON
  CUDA_RESOLVE_DEVICE_SYMBOLS ON
)
# ──────────────────────────────────────────────────────────────────────────────
# Stand-alone CLI (echoframe_cli)  ← NEW
# ──────────────────────────────────────────────────────────────────────────────
message(STATUS "EF_BUILD_CLI = ${EF_BUILD_CLI}")
if (EF_BUILD_CLI)

    # 2. Source files that live in echoframe/cpp/src/echoframe_cli/
    # cli.cpp transitively includes BF_formatter.h which contains CUDA kernel
    # launch syntax (<<<>>>), so all CLI sources must be compiled with nvcc.
    # glibc_compat.c provides stubs for __isoc23_* symbols missing on glibc < 2.38.
    set(EF_CLI_SOURCES
        echoframe_cli/cli.cpp
        echoframe_cli/load_specs_from_mat.cpp
        echoframe_cli/read_rf.cpp)
    set_source_files_properties(${EF_CLI_SOURCES} PROPERTIES LANGUAGE CUDA)
    add_executable(echoframe_cli ${EF_CLI_SOURCES})

    # 3.  Include paths that the helpers need
    target_include_directories(echoframe_cli PRIVATE
        ${EF_INCLUDES}
        ${CMAKE_CURRENT_SOURCE_DIR}/echoframe_cli
        ${MATIO_INCLUDE_DIRS})

    # ── external libraries that matio / core depend on ──────────────────────
    set(HDF5_USE_STATIC_LIBRARIES ON)
    find_package(matio MODULE REQUIRED)
    find_package(ZLIB  REQUIRED)
    find_package(hdf5  CONFIG REQUIRED COMPONENTS C)


    # resolve to the actual names in the current triplet
    if (NOT TARGET hdf5::hdf5)
        if (TARGET hdf5::hdf5-static)
            add_library(hdf5::hdf5      ALIAS hdf5::hdf5-static)
        elseif (TARGET hdf5::hdf5-shared)
            add_library(hdf5::hdf5      ALIAS hdf5::hdf5-shared)
        else()
            message(FATAL_ERROR "HDF-5 found, but no imported targets exported")
        endif()
    endif()

    # Aliased separately: HDF5 2.x exports no HL target, and nothing here
    # links HL, so its absence is not an error.
    if (NOT TARGET hdf5::hdf5_hl)
        if (TARGET hdf5::hdf5_hl-static)
            add_library(hdf5::hdf5_hl   ALIAS hdf5::hdf5_hl-static)
        elseif (TARGET hdf5::hdf5_hl-shared)
            add_library(hdf5::hdf5_hl   ALIAS hdf5::hdf5_hl-shared)
        endif()
    endif()

    target_link_libraries(echoframe_cli
        PRIVATE
            echoframe_core
            CUDA::cudart  CUDA::cublas  CUDA::cufft  CUDA::cusolver
            matio::matio
            hdf5::hdf5
            # hdf5::hdf5_hl
            ZLIB::ZLIB
    )

    target_compile_definitions(echoframe_cli PRIVATE _WINSOCKAPI_=1)

    set_target_properties(echoframe_cli PROPERTIES
        CUDA_RESOLVE_DEVICE_SYMBOLS ON
    )

    # 5.  (Optional) install so users get a ready-to-run binary
    install(TARGETS echoframe_cli RUNTIME DESTINATION bin)
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Optional MATLAB / MEX target
# ──────────────────────────────────────────────────────────────────────────────
if (EF_BUILD_MEX)
    # Search quietly so a missing MATLAB does *not* fail configuration
    if(DEFINED MATLAB_VERSION)
        find_package(Matlab ${MATLAB_VERSION} EXACT REQUIRED
                     COMPONENTS MX_LIBRARY MAT_LIBRARY MEX_COMPILER)
    else()
        find_package(Matlab REQUIRED
                     COMPONENTS MX_LIBRARY MAT_LIBRARY MEX_COMPILER)
    endif()

    if (Matlab_FOUND)
        message(STATUS "MATLAB found at ${Matlab_ROOT_DIR} – building MEX layer")
        message(STATUS "MATLAB version ${Matlab_VERSION}")

        # Add MATLAB include paths only for targets that need them
        list(APPEND EF_INCLUDES ${Matlab_INCLUDE_DIRS})

        set(EF_MEX_SOURCES
            mex/echoframe_mex.cu
            mex/mex_resources_conversions.cpp)

        matlab_add_mex(
            NAME         echoframe_mex
            SRC          ${EF_MEX_SOURCES}
            LINK_TO      echoframe_core 
                        CUDA::cudart cufft cusparse cublas cusolver 
            OUTPUT_NAME  echoframe_mex
            R2018a)

        target_include_directories(echoframe_mex PRIVATE ${EF_INCLUDES})
        if(DEFINED EF_CUDA_LINK_DIR)
            target_link_directories(echoframe_mex PRIVATE ${EF_CUDA_LINK_DIR})
        endif()
        target_compile_definitions(echoframe_mex PRIVATE _WINSOCKAPI_=1)
        set_target_properties(echoframe_mex PROPERTIES
            CUDA_RESOLVE_DEVICE_SYMBOLS ON
            # matlab_add_mex() links via CXX (for its MEX-specific link flags/
            # version script), not nvcc, so unlike echoframe_cli/echoframe
            # (which CMake links via nvcc, auto-adding the CUDA toolkit's
            # lib64 as a -L path) this target never gets that implicit
            # search path and can fail to find -lcudart_static even when the
            # archive exists. Link the shared runtime instead, which is
            # reliably on the default library search path.
            CUDA_RUNTIME_LIBRARY Shared
        )

        set(STORAGE_MEX_SOURCES
            ${CMAKE_SOURCE_DIR}/../libs/Storage/src/mex/storage.cpp
            ${CMAKE_SOURCE_DIR}/../libs/Storage/src/utils/mathelper.cpp)

        matlab_add_mex(
            NAME         storage
            SRC          ${STORAGE_MEX_SOURCES}
            OUTPUT_NAME  storage
            R2018a)

        target_include_directories(storage PRIVATE
            ${CMAKE_SOURCE_DIR}/../libs/Storage/src
            ${Matlab_INCLUDE_DIRS})
    else()
        message(STATUS "MATLAB not found – skipping MEX target "
                       "(re-configure with -DEF_BUILD_MEX=OFF to silence this)")
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Optional Python wrapper ------------------------------------------------------
# ──────────────────────────────────────────────────────────────────────────────
if (EF_BUILD_PYTHON)

    # vcpkg's python3 port installs share/python/vcpkg-cmake-wrapper.cmake, which
    # intercepts find_package(Python) and hard-points the include dir and import
    # library at vcpkg's own CPython (3.12, in the triplet tree). When scikit-build-core
    # drives the build it has already pinned Python_INCLUDE_DIR / Python_LIBRARY to the
    # interpreter the wheel is being built for (3.11 for a cp311 tag), so the wrapper's
    # 3.12 headers disagree with the 3.11 interpreter and FindPython reports every
    # component missing — "Could NOT find Python ... (found version 3.12.9)".
    #
    # The wrapper populates FindPython's internal cache entries with find_path/find_library,
    # both of which are no-ops when the entry is already set. Seeding them with the values
    # scikit-build-core supplied keeps the wrapper from stomping on the correct interpreter.
    if (DEFINED Python_INCLUDE_DIR AND DEFINED Python_LIBRARY)
        set(_Python_INCLUDE_DIR      "${Python_INCLUDE_DIR}" CACHE PATH     "" FORCE)
        set(_Python_LIBRARY_RELEASE  "${Python_LIBRARY}"     CACHE FILEPATH "" FORCE)
    endif()

    # Development.Module, not Development: we build an extension module, not an embedded
    # interpreter, so the Development.Embed half is not needed.
    find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)

    message(STATUS "Found Python: ${Python_EXECUTABLE}")
    message(STATUS "Python version: ${Python_VERSION}")
    message(STATUS "Python include dir: ${Python_INCLUDE_DIRS}")
    message(STATUS "Python library: ${Python_LIBRARY}")
    message(STATUS "Python libraries: ${Python_LIBRARIES}")
    if (TARGET Python::Module)
        message(STATUS "CMake target Python::Module is available")
    else()
        message(STATUS "CMake target Python::Module is NOT available")
    endif()

    # ── 1.  Locate or fetch pybind11  ────────────────────────────────────────
    find_package(pybind11 2.12 QUIET CONFIG)

    if (NOT pybind11_FOUND)
        include(FetchContent)
        FetchContent_Declare(
            pybind11
            GIT_REPOSITORY https://github.com/pybind/pybind11.git
            GIT_TAG        v2.12.0       # 2.12 or newer
        )
        FetchContent_MakeAvailable(pybind11)
    endif()

    set(PY_WRAPPER
        python/echoframe_py_wrapper.cpp
        python/echoframe_py_conversions.cpp)

    set_source_files_properties(${PY_WRAPPER} PROPERTIES LANGUAGE CUDA)

    # --- build the extension ------------------------------------------------
    add_library(echoframe MODULE ${PY_WRAPPER})   # NOTE leading underscore
    target_include_directories(echoframe PRIVATE ${EF_INCLUDES})
    target_link_libraries(echoframe
        PRIVATE
            pybind11::module
            Python::Module      # Module, not Python: extension, not embedded interpreter
            echoframe_core
            CUDA::cudart
            CUDA::cublas
            CUDA::cusolver
            CUDA::cufft)   # handles cublasLt / cusolverMg / nvJitLink

    set_target_properties(echoframe PROPERTIES
        OUTPUT_NAME  echoframe
        PREFIX       "${PYTHON_MODULE_PREFIX}"
        SUFFIX       "${PYTHON_MODULE_EXTENSION}"
        CUDA_RESOLVE_DEVICE_SYMBOLS ON)


    # --- install everything into echoframe/ --------------------------------
    install(TARGETS echoframe LIBRARY DESTINATION echoframe)
    install(FILES   python/__init__.py  DESTINATION echoframe)
endif()

# --------------------------------------------------------------------------
# Compile-options tuning (host vs device)------------------------------------
if (MSVC)
    target_compile_options(echoframe_core PRIVATE
        # C++ flags: use Debug's /MDd and Release's /MD appropriately
        $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Debug>>:/W4 /EHsc /MDd>
        $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:Release>>:/W4 /EHsc /O2 /MD>
        # CUDA flags: pass the correct CRT to the host compiler via -Xcompiler.
        # Unquoted -- quoting only survives the Visual Studio generator.
        $<$<AND:$<COMPILE_LANGUAGE:CUDA>,$<CONFIG:Debug>>:--use_fast_math -Xcompiler=/W4,/EHsc,/MDd>
        $<$<AND:$<COMPILE_LANGUAGE:CUDA>,$<CONFIG:Release>>:--use_fast_math -Xcompiler=/W4,/EHsc,/O2,/MD>
    )
else()  # GCC / Clang
    target_compile_options(echoframe_core PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall -O2 -fPIC>
        $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math -Xcompiler=-Wall,-O2,-fPIC>
    )
endif()
