# SPDX-FileCopyrightText: 2026 LichtFeld Studio Authors
#
# SPDX-License-Identifier: GPL-3.0-or-later

include_guard(GLOBAL)

# Each CUDA toolkit accepts a fixed range of MSVC host compilers. The upper
# bound lives in <cuda>/include/crt/host_config.h as
#   #if _MSC_VER < 1910 || _MSC_VER >= NNNN
# (CUDA 12.8 rejects _MSC_VER >= 1950, i.e. the VS 2026 / MSVC 14.5x toolsets).
# When the active MSVC is newer, nvcc fails inside project() with an unclear
# compiler-identification error, and -allow-unsupported-compiler makes
# cudafe++ crash later. Detect the mismatch first and name the fix.
#
# The bound is read from the toolkit header rather than hardcoded, so a newer
# CUDA that accepts MSVC 14.5x passes without edits here. If the header cannot
# be read, the check assumes CUDA < 13.0 rejects _MSC_VER >= 1950 (CUDA 12.8
# was verified locally; newer limits are not).
#
# Set LFS_SKIP_CUDA_MSVC_CHECK=ON to bypass, or put -allow-unsupported-compiler
# in CMAKE_CUDA_FLAGS to downgrade the error to a warning.

set(LFS_SKIP_CUDA_MSVC_CHECK OFF CACHE BOOL "Skip the CUDA/MSVC host compiler compatibility check")

# Upper _MSC_VER bound (exclusive) for the toolkit that owns NVCC, or "" if unknown.
function(_lfs_cuda_msc_ver_limit nvcc out_var)
    set(_limit "")
    get_filename_component(_cuda_root "${nvcc}" DIRECTORY)
    get_filename_component(_cuda_root "${_cuda_root}" DIRECTORY)
    set(_host_config "${_cuda_root}/include/crt/host_config.h")
    if(EXISTS "${_host_config}")
        file(STRINGS "${_host_config}" _lines REGEX "_MSC_VER < [0-9]+ \\|\\| _MSC_VER >= [0-9]+")
        foreach(_line IN LISTS _lines)
            if(_line MATCHES "_MSC_VER >= ([0-9]+)")
                set(_limit "${CMAKE_MATCH_1}")
                break()
            endif()
        endforeach()
    endif()
    if(_limit STREQUAL "")
        # Fallback assumption: toolkits before 13.0 reject MSVC 14.5x.
        execute_process(COMMAND "${nvcc}" --version
            OUTPUT_VARIABLE _nvcc_out ERROR_QUIET RESULT_VARIABLE _rc)
        if(_rc EQUAL 0 AND _nvcc_out MATCHES "release ([0-9]+\\.[0-9]+)")
            if(CMAKE_MATCH_1 VERSION_LESS 13.0)
                set(_limit 1950)
            endif()
        endif()
    endif()
    set(${out_var} "${_limit}" PARENT_SCOPE)
endfunction()

function(_lfs_cuda_msvc_report msc_ver limit nvcc source)
    math(EXPR _minor "${msc_ver} - 1900")
    math(EXPR _limit_minor "${limit} - 1901")
    set(_msg
        "MSVC ${msc_ver} (toolset 14.${_minor}, from ${source}) is newer than the "
        "CUDA toolkit at '${nvcc}' accepts (it requires _MSC_VER < ${limit}, i.e. "
        "toolset 14.${_limit_minor} or older; VS 2026 ships 14.5x).\n"
        "Fix: build from a shell that selects an older installed toolset, e.g.\n"
        "  \"<VS>\\VC\\Auxiliary\\Build\\vcvars64.bat\" -vcvars_ver=14.44\n"
        "(install 'MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.44)' in the VS "
        "Installer if it is missing), and pin vcpkg to the same toolset with "
        "-DVCPKG_OVERLAY_TRIPLETS=<repo>/cmake/triplets/msvc-14.44 (absolute path; see "
        "docs/building_and_distribution.md). Use a fresh build directory "
        "(--fresh) after switching. Alternatively install a CUDA toolkit that "
        "supports this MSVC.\n"
        "Set -DLFS_SKIP_CUDA_MSVC_CHECK=ON to bypass this check.")
    string(JOIN "" _msg ${_msg})
    if(CMAKE_CUDA_FLAGS MATCHES "allow-unsupported-compiler" OR "$ENV{CUDAFLAGS}" MATCHES "allow-unsupported-compiler")
        message(WARNING "${_msg}\n-allow-unsupported-compiler is set; continuing, but cudafe++ is known to crash with this combination.")
    else()
        message(FATAL_ERROR "${_msg}")
    endif()
endfunction()

# Pre-project() check: MSVC_VERSION and the CUDA compiler are not known yet,
# so locate them the way CMake will (cache, environment, PATH).
function(lfs_check_cuda_msvc_compat_preproject)
    if(NOT CMAKE_HOST_WIN32 OR LFS_SKIP_CUDA_MSVC_CHECK)
        return()
    endif()

    # NVCC: explicit cache value, CUDACXX, PATH, then CUDA_PATH.
    set(_nvcc "")
    if(CMAKE_CUDA_COMPILER)
        set(_nvcc "${CMAKE_CUDA_COMPILER}")
    elseif(DEFINED ENV{CUDACXX} AND NOT "$ENV{CUDACXX}" STREQUAL "")
        set(_nvcc "$ENV{CUDACXX}")
    else()
        find_program(_nvcc_found NAMES nvcc NO_CACHE)
        if(_nvcc_found)
            set(_nvcc "${_nvcc_found}")
        elseif(DEFINED ENV{CUDA_PATH} AND EXISTS "$ENV{CUDA_PATH}/bin/nvcc.exe")
            set(_nvcc "$ENV{CUDA_PATH}/bin/nvcc.exe")
        endif()
    endif()
    if(_nvcc STREQUAL "" OR NOT EXISTS "${_nvcc}")
        return()
    endif()
    file(TO_CMAKE_PATH "${_nvcc}" _nvcc)

    # MSVC: explicit host/CXX compiler path, vcvars' VCToolsVersion, then cl on PATH.
    set(_msvc_source "")
    set(_toolset "")
    foreach(_candidate IN ITEMS "${CMAKE_CUDA_HOST_COMPILER}" "${CMAKE_CXX_COMPILER}")
        file(TO_CMAKE_PATH "${_candidate}" _candidate)
        if(_candidate MATCHES "/MSVC/(14\\.[0-9]+)")
            set(_toolset "${CMAKE_MATCH_1}")
            set(_msvc_source "${_candidate}")
            break()
        endif()
    endforeach()
    if(_toolset STREQUAL "" AND "$ENV{VCToolsVersion}" MATCHES "^(14\\.[0-9]+)")
        set(_toolset "${CMAKE_MATCH_1}")
        set(_msvc_source "VCToolsVersion=$ENV{VCToolsVersion}")
    endif()
    if(_toolset STREQUAL "")
        find_program(_cl_found NAMES cl NO_CACHE)
        file(TO_CMAKE_PATH "${_cl_found}" _cl_found)
        if(_cl_found MATCHES "/MSVC/(14\\.[0-9]+)")
            set(_toolset "${CMAKE_MATCH_1}")
            set(_msvc_source "${_cl_found}")
        endif()
    endif()
    if(_toolset STREQUAL "")
        return()
    endif()
    # Toolset 14.NN maps to _MSC_VER 19NN (14.44 -> 1944, 14.50 -> 1950).
    string(REGEX REPLACE "^14\\." "" _minor "${_toolset}")
    math(EXPR _msc_ver "1900 + ${_minor}")

    _lfs_cuda_msc_ver_limit("${_nvcc}" _limit)
    if(NOT _limit STREQUAL "" AND _msc_ver GREATER_EQUAL _limit)
        _lfs_cuda_msvc_report(${_msc_ver} ${_limit} "${_nvcc}" "${_msvc_source}")
    endif()
endfunction()

# Post-project() backstop with the real MSVC_VERSION and CUDA compiler. Catches
# setups the pre-project probe could not see (e.g. a toolchain file).
function(lfs_check_cuda_msvc_compat)
    if(NOT MSVC OR LFS_SKIP_CUDA_MSVC_CHECK OR NOT CMAKE_CUDA_COMPILER)
        return()
    endif()
    _lfs_cuda_msc_ver_limit("${CMAKE_CUDA_COMPILER}" _limit)
    if(NOT _limit STREQUAL "" AND MSVC_VERSION GREATER_EQUAL _limit)
        _lfs_cuda_msvc_report(${MSVC_VERSION} ${_limit} "${CMAKE_CUDA_COMPILER}" "MSVC_VERSION")
    endif()
endfunction()
