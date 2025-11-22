#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="aarch64"
ZIG_ARCH="aarch64"

new_args=()
for arg in "${EXTRA_CMAKE_ARGS[@]}"; do
  case "$arg" in
    -DZIG_SYSTEM_LIBCXX=*) ;;
    -DZIG_USE_LLVM_CONFIG=*) ;;
    *) new_args+=("$arg") ;;
  esac
done
EXTRA_CMAKE_ARGS=("${new_args[@]}")

EXTRA_CMAKE_ARGS+=(
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_USE_LLVM_CONFIG=OFF
  -DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-macos-none
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_ARCH}-macos-none
  -Dcpu=baseline
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"

# This script only sets up EXTRA_ZIG_ARGS and EXTRA_CMAKE_ARGS
echo "macOS ARM64 configuration complete. EXTRA_ZIG_ARGS contains ${#EXTRA_ZIG_ARGS[@]} arguments."
