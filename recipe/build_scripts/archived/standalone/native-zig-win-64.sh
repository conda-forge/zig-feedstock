#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

get_msvc_version() {
  # Find the latest MSVC version directory under VSINSTALLDIR/VC/Tools/MSVC
  latest_version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
  echo "${latest_version}"
}

# --- Main ---

SYSROOT_ARCH=""
ZIG_ARCH="x86_64"

_UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
_MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/$(get_msvc_version)/lib/x64"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SHARED_LLVM=*"
EXTRA_CMAKE_ARGS+=(
  -DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}"
  -DZIG_TARGET_TRIPLE=${ZIG_ARCH}-windows-msvc
)

EXTRA_ZIG_ARGS+=(
  --maxrss 7500000000
  -Dtarget=${ZIG_ARCH}-windows-msvc
)

CMAKE_PATCHES+=(
  0001-win-deprecations-zig_llvm.cpp.patch
  0001-win-deprecations-zig_llvm-ar.cpp.patch
)

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
