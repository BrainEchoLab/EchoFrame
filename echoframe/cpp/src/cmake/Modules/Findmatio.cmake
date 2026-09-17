# Findmatio.cmake -- locate the matio MAT-file I/O library.
#
# Defines the imported target matio::matio with per-configuration locations.
#
# Why this is not a single find_library: under vcpkg the debug and release
# libraries have the SAME filename (libmatio.lib) and differ only by directory
# (<triplet>/lib vs <triplet>/debug/lib). The vcpkg toolchain puts BOTH on
# CMAKE_PREFIX_PATH, and with a multi-config generator (Visual Studio)
# CMAKE_BUILD_TYPE is empty, which makes vcpkg.cmake order the debug prefix
# FIRST. A single find_library therefore silently resolves to the debug library
# and links it into Release builds. Search each configuration explicitly instead.

find_path(matio_INCLUDE_DIR NAMES matio.h PATH_SUFFIXES include
  NO_SYSTEM_ENVIRONMENT_PATH)

# Headers are shared between configurations in the vcpkg layout, so the include
# directory's parent is the installation root for both.
if (matio_INCLUDE_DIR)
  get_filename_component(_matio_root "${matio_INCLUDE_DIR}" DIRECTORY)

  find_library(matio_LIBRARY_RELEASE
    NAMES libmatio matio matio_static
    PATHS "${_matio_root}/lib" "${_matio_root}/lib64"
    NO_DEFAULT_PATH)

  find_library(matio_LIBRARY_DEBUG
    NAMES libmatio matio matio_static libmatiod matiod
    PATHS "${_matio_root}/debug/lib" "${_matio_root}/debug/lib64"
    NO_DEFAULT_PATH)

  unset(_matio_root)
endif()

# Fallback for non-vcpkg layouts (system install, manual build tree).
if (NOT matio_LIBRARY_RELEASE AND NOT matio_LIBRARY_DEBUG)
  find_library(matio_LIBRARY_RELEASE
    NAMES libmatio matio matio_static
    PATH_SUFFIXES lib lib64
    NO_SYSTEM_ENVIRONMENT_PATH)
endif()

# Sets matio_LIBRARY / matio_LIBRARIES from the RELEASE and DEBUG variables.
include(SelectLibraryConfigurations)
select_library_configurations(matio)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(matio
  REQUIRED_VARS matio_INCLUDE_DIR matio_LIBRARY)

if (matio_FOUND AND NOT TARGET matio::matio)
  add_library(matio::matio UNKNOWN IMPORTED)
  set_target_properties(matio::matio PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${matio_INCLUDE_DIR}")

  if (matio_LIBRARY_RELEASE)
    set_property(TARGET matio::matio APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
    set_target_properties(matio::matio PROPERTIES
      IMPORTED_LOCATION_RELEASE "${matio_LIBRARY_RELEASE}")
  endif()

  if (matio_LIBRARY_DEBUG)
    set_property(TARGET matio::matio APPEND PROPERTY IMPORTED_CONFIGURATIONS DEBUG)
    set_target_properties(matio::matio PROPERTIES
      IMPORTED_LOCATION_DEBUG "${matio_LIBRARY_DEBUG}")
  endif()

  # RelWithDebInfo / MinSizeRel are not in IMPORTED_CONFIGURATIONS; without this
  # mapping CMake falls back to whichever config it finds first (often DEBUG).
  set_target_properties(matio::matio PROPERTIES
    MAP_IMPORTED_CONFIG_RELWITHDEBINFO Release
    MAP_IMPORTED_CONFIG_MINSIZEREL     Release)

  # Fallback location for consumers that ignore per-config properties.
  set_target_properties(matio::matio PROPERTIES
    IMPORTED_LOCATION "${matio_LIBRARY}")
endif()
