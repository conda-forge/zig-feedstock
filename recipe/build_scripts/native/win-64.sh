#!/usr/bin/env bash
# Native build for win-64 using zig as C/C++ compiler
# Binary RUNS on win-64, TARGETS win-64

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-windows-gnu"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Native build: win-64 using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"

# Setup zig as C/C++ compiler
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_SYSTEM_PROCESSOR=AMD64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
)

# Build zigcpp library
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "${BOOTSTRAP_ZIG}" "win-64"
