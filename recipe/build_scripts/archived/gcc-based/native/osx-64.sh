#!/usr/bin/env bash
# Native build for osx-64
# Binary RUNS on osx-64, TARGETS osx-64

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-macos-none"

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
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"

# Link additional libraries
perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
