#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

get_msvc_version() {
  # Find the latest MSVC version directory under VSINSTALLDIR/VC/Tools/MSVC
  latest_version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
  echo "${latest_version}"
}

# --- Main ---

_UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
_MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/$(get_msvc_version)/lib/x64"

EXTRA_CMAKE_ARGS+=(
  -DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}"
)

EXTRA_ZIG_ARGS+=(
  --maxrss 7500000000
)

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
