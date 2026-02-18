#!/usr/bin/env bash
# Cross-target build for osx-arm64 using zig as C/C++ compiler
# Binary RUNS on osx-arm64 (cross-compiled from osx-64)
# macOS cross-compilation uses universal SDK, no QEMU needed

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="aarch64-macos-none"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Cross-target: osx-64 -> osx-arm64 using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"

# Setup zig as C/C++ compiler
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SYSTEM_LIBCXX=*" "-DZIG_USE_LLVM_CONFIG=*"

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Darwin
    -DCMAKE_SYSTEM_PROCESSOR=arm64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DCMAKE_CROSSCOMPILING=ON
    -DZIG_SYSTEM_LIBCXX=c++
    -DZIG_USE_LLVM_CONFIG=OFF
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
)

# Build zigcpp library
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" "${BOOTSTRAP_ZIG}"

# Link additional libraries (macOS-specific)
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
