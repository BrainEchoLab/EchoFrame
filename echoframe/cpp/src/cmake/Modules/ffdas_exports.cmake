# Confine a fallback ffdas build to its own C API.
#
# ffdas links the C++ runtime statically so it cannot clash with the runtime its
# host already has, but a static runtime in a shared library is still exported by
# default, and the loader then binds the whole process to that second copy of the
# standard library. The two disagree about std::locale::id, so a std::use_facet<>
# lookup misses, throws std::bad_cast, and the stream it was called on goes into
# an error state where every later write is silently discarded -- the Python
# banners stop partway through the first GPU-info row. cmake/ffdas_exports.map
# has the full account.
#
# Applied from the parent project rather than ffdas' own CMakeLists.txt so the
# submodule stays untouched. A prebuilt ffdas found through find_package() is
# outside this module's reach; efreport_ffdas_exports() covers that case.

# efconfine_ffdas_exports(<target>)
#
# Restrict <target>'s dynamic symbol table to the ffdas_* C API.
function(efconfine_ffdas_exports target)
    # Apple's linker spells this -exported_symbols_list and takes a different file
    # format, and MSVC exports nothing but __declspec(dllexport) symbols from a
    # static-CRT library. Neither has a runtime to confine.
    if(CMAKE_HOST_WIN32)
        return()
    endif()
    if(CMAKE_HOST_APPLE)
        message(WARNING
            "No --version-script support on Apple linkers, so ffdas will export "
            "its statically linked C++ runtime and the host's std::cout may stop "
            "working partway through a banner. Add an exported-symbols list to the "
            "ffdas build to fix it.")
        return()
    endif()

    set(map "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ffdas_exports.map")
    if(NOT EXISTS "${map}")
        message(FATAL_ERROR
            "ffdas version script not found at ${map}; without it the ffdas "
            "build exports a private copy of the C++ runtime and silently "
            "truncates the Python banner output.")
    endif()

    # --version-script, unlike -Bsymbolic, leaves the undefined CUDA runtime
    # entry points alone, so ffdas still resolves them against libcudart.
    # set_property rather than target_link_options: <target> was created in the
    # ffdas subdirectory, not this one. LINK_DEPENDS is what makes an edit to the
    # map re-link the library, and through it re-run the check below.
    set_property(TARGET ${target} APPEND PROPERTY
        LINK_OPTIONS "-Wl,--version-script=${map}")
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${map}")
    message(STATUS "ffdas exports: restricted to the ffdas_* C API")

    # Verify what the linker actually did, not what the flag asked for: a linker
    # that ignores --version-script leaves the runtime exported and the banners
    # broken, and this is the only place that says so. A stamped custom target
    # rather than add_custom_command(TARGET ... POST_BUILD), which CMake refuses
    # for a target from another directory. Depending on the library file as well
    # as the target is what makes the stamp go stale when ffdas relinks;
    # add_dependencies() only orders the two, it does not invalidate anything.
    set(stamp "${CMAKE_CURRENT_BINARY_DIR}/ffdas_exports_checked.stamp")
    add_custom_command(
        OUTPUT "${stamp}"
        COMMAND ${CMAKE_COMMAND}
                -DFFDAS_LIBRARY=$<TARGET_FILE:${target}>
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckFfdasExports.cmake"
        COMMAND ${CMAKE_COMMAND} -E touch "${stamp}"
        DEPENDS $<TARGET_FILE:${target}>
        COMMENT "Checking that ffdas exports only its C API"
        VERBATIM)
    add_custom_target(ef_ffdas_exports_check ALL DEPENDS "${stamp}")
    add_dependencies(ef_ffdas_exports_check ${target})
endfunction()

# efreport_ffdas_exports(<imported-target>)
#
# Check the library an imported ffdas target points at. An install(EXPORT) target
# only carries the per-configuration IMPORTED_LOCATION_<CONFIG>, so fall back to
# those when LOCATION comes back empty.
function(efreport_ffdas_exports target)
    get_target_property(location ${target} LOCATION)
    if(NOT location)
        foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES
                             ITEMS Release Debug RelWithDebInfo MinSizeRel)
            get_target_property(location ${target} IMPORTED_LOCATION_${config})
            if(location)
                break()
            endif()
        endforeach()
    endif()

    if(NOT location)
        message(WARNING
            "Could not locate the ffdas library behind ${target}, so its exports "
            "went unchecked. If it exports C++ symbols the host's std::cout will "
            "silently stop working partway through a banner.")
        return()
    endif()
    efcheck_ffdas_exports("${location}")
endfunction()

# efcheck_ffdas_exports(<path-to-libffdas>)
#
# Fail if <path> exports anything outside the ffdas_* C API. Defined symbols only
# -- `local: *` in a version script cannot affect the undefined imports. A
# prebuilt ffdas that trips this needs its own CMakeLists.txt to add
# cmake/ffdas_exports.map; EchoFrame cannot link it away after the fact.
function(efcheck_ffdas_exports library)
    if(CMAKE_HOST_WIN32 OR NOT EXISTS "${library}")
        return()
    endif()
    find_program(EF_NM NAMES nm llvm-nm)
    if(NOT EF_NM)
        message(WARNING
            "nm not found, so the exported symbols of ${library} went unchecked. "
            "If it exports C++ symbols the host's std::cout will silently stop "
            "working partway through a banner.")
        return()
    endif()

    execute_process(
        COMMAND "${EF_NM}" --dynamic --defined-only --format=posix "${library}"
        OUTPUT_VARIABLE symbols
        RESULT_VARIABLE status)
    if(NOT status EQUAL 0)
        message(WARNING "Could not read the dynamic symbols of ${library}.")
        return()
    endif()

    # Each line is "<name> <type> <value> <size>". Absolute (A) entries are
    # linker-defined, not code: the version node the version script itself
    # creates. Everything else has to be part of the C API.
    string(REPLACE "\n" ";" lines "${symbols}")
    set(leaked "")
    foreach(line IN LISTS lines)
        if(line MATCHES "^([^ \t]+) ([A-Za-z]) ")
            set(name "${CMAKE_MATCH_1}")
            set(kind "${CMAKE_MATCH_2}")
        else()
            continue()
        endif()
        if(kind STREQUAL "A")
            continue()
        endif()
        string(REGEX REPLACE "@.*$" "" name "${name}")
        if(NOT name MATCHES "^ffdas_")
            list(APPEND leaked "${name}")
        endif()
    endforeach()

    if(leaked)
        list(LENGTH leaked count)
        list(GET leaked 0 first)
        message(FATAL_ERROR
            "${library} exports ${count} symbol(s) outside the ffdas_* C API "
            "(${first} and others). It carries a private copy of the C++ runtime, "
            "which the loader will interpose on the whole process. Fix the ffdas "
            "build to link with cmake/ffdas_exports.map; see the comment there for "
            "the failure this causes.")
    endif()
    message(STATUS "ffdas exports: only the ffdas_* C API (${library})")
endfunction()
