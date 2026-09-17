cmake_minimum_required(VERSION 3.21)
project(EchoFrameStorage CXX)

# Storage: asynchronous, overlapped writes of acquisition buffers to disk.
#
# The library is header-only. Everything under src/storage is templates on the
# stored element type -- Handler.t.hpp and the two platform backends
# (Windows/WindowsFileIO.t.hpp, Linux/LinuxFileIO.t.hpp) -- so nothing here
# compiles to an object of its own. src/utils/mathelper.cpp and src/mex/storage.cpp
# are the only .cpp files, and neither belongs to the library proper: the first is
# a helper and the second is the MATLAB gateway.
#
# THE ECHOFRAME BUILD DOES NOT PROCESS THIS FILE. echoframe/cpp/src/CMakeLists.txt
# consumes Storage by putting src/ on its include path and compiling
# src/mex/storage.cpp and src/utils/mathelper.cpp into its own targets; it never
# calls add_subdirectory() here. So editing this file changes nothing about the
# MEX, the CLI or the Python module.
#
# What it is for is building the storage self-checks on their own, without
# MATLAB, CUDA or a GPU:
#
#   cmake -S . -B build
#   cmake --build build --config Release
#   ctest --test-dir build -C Release
#
# write_count_check writes a real file, so on Windows it needs
# SeManageVolumePrivilege -- run it from an elevated shell or it will fail in
# Handler::init. See README.md for the storage design and the debug knobs.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Header-only: consumers just need src/ on the include path.
add_library(echoframe_storage INTERFACE)
target_include_directories(echoframe_storage
        INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/src)

# The Handler runs its writes on worker threads. Windows gets them from the
# system libraries the toolchain already links; elsewhere ask for pthreads.
if (NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(echoframe_storage INTERFACE Threads::Threads)
endif ()

#-------------------- self-checks --------------------#
# write_stats_check  the debug knobs are re-read rather than cached, and the
#                    source digest notices an overwritten buffer. Needs nothing.
# write_count_check  exactly one write completion is counted per stored buffer,
#                    with and without the deferred-write knob. Drives a real
#                    Handler through a real file, which is where the counting
#                    lives, so this one needs elevation on Windows.
#
# Both exit non-zero on failure.
include(CTest)

foreach (check write_stats_check write_count_check)
    add_executable(${check} tests/${check}.cpp)
    target_link_libraries(${check} PRIVATE echoframe_storage)
    add_test(NAME ${check} COMMAND ${check})
endforeach ()
