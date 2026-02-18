#!/usr/bin/env bash
# Cross-target build for osx-arm64
# Binary RUNS on osx-arm64 (cross-compiled from osx-64)
# macOS cross-compilation uses universal SDK, no QEMU needed

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="aarch64-macos-none"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SYSTEM_LIBCXX=*" "-DZIG_USE_LLVM_CONFIG=*"

EXTRA_CMAKE_ARGS+=(
  -DZIG_SYSTEM_LIBCXX=c++
  -DZIG_USE_LLVM_CONFIG=OFF
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
  -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_TARGET}
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
