#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="aarch64"
ZIG_ARCH="aarch64"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SYSTEM_LIBCXX=*" "-DZIG_USE_LLVM_CONFIG=*"

EXTRA_CMAKE_ARGS+=(
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_USE_LLVM_CONFIG=OFF
  -DZIG_TARGET_TRIPLE=${ZIG_ARCH}-macos-none
  -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_ARCH}-macos-none
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
