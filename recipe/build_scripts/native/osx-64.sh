#!/usr/bin/env bash
# Native build for osx-64 using zig as C/C++ compiler
# Binary RUNS on osx-64, TARGETS osx-64
#
# Note: macOS builds have special requirements for libc++ handling

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-macos-none"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Native build: osx-64 using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"

# Setup zig as C/C++ compiler
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SYSTEM_LIBCXX=*" "-DZIG_USE_LLVM_CONFIG=*"

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Darwin
    -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
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
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "${BOOTSTRAP_ZIG}"

# Link additional libraries (macOS-specific libc++ handling)
perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
