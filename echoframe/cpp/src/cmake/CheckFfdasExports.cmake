# Post-link driver for the ffdas export check. Run as:
#
#   cmake -DFFDAS_LIBRARY=<path to libffdas> -P cmake/CheckFfdasExports.cmake
#
# Exits non-zero, with the reason on stderr, if the library exports anything
# outside its C API. The implementation is in Modules/ffdas_exports.cmake; it is
# a module rather than a plain script so CMakeLists.txt can call the same check on
# a prebuilt ffdas at configure time.
include("${CMAKE_CURRENT_LIST_DIR}/Modules/ffdas_exports.cmake")

if(NOT DEFINED FFDAS_LIBRARY)
    message(FATAL_ERROR "FFDAS_LIBRARY must be set to the ffdas library to check.")
endif()

efcheck_ffdas_exports("${FFDAS_LIBRARY}")
