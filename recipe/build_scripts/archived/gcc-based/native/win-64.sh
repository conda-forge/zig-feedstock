#!/usr/bin/env bash
# Native build for win-64
# Binary RUNS on win-64, TARGETS win-64

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-windows-gnu"

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_TARGET}
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "win-64"
