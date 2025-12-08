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

SYSROOT_ARCH="aarch64"
ZIG_ARCH="aarch64"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_USE_LLVM_CONFIG=*"

_UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
_MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/$(get_msvc_version)/lib/x64"

EXTRA_CMAKE_ARGS+=(
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_USE_LLVM_CONFIG=OFF
  -DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-macos-none
  -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

EXTRA_ZIG_ARGS+=(
  --maxrss 7500000000
  -Dtarget=${ZIG_ARCH}-macos-none
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
