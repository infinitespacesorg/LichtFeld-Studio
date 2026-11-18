# Same recipe as cmake/triplets/release-only/x64-windows.cmake, with the MSVC
# toolset pinned to 14.44 (VS 2022 v143). Opt-in only: use it when the CUDA
# toolkit rejects the newest installed MSVC (CUDA 12.8 rejects VS 2026's 14.5x),
# together with a shell from vcvars64.bat -vcvars_ver=14.44, so vcpkg's
# dependencies and the application use the same toolset.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_PLATFORM_TOOLSET v143)
set(VCPKG_PLATFORM_TOOLSET_VERSION 14.44)
