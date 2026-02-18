#!/usr/bin/env bash
# Cross-compiler build for win-arm64
# Binary RUNS on linux-64, TARGETS win-arm64
# NO SYSROOT NEEDED - zig bundles cross-compilation support

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="aarch64-windows-gnu"
ZIG_MCPU="baseline"

echo "=== Cross-compiler: linux-64 -> win-arm64 ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  No sysroot required - zig handles cross-compilation internally"

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_TARGET}
  -Dcpu=${ZIG_MCPU}
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
)

# Standard native-like build (runs on linux-64)
modify_libc_libm_for_zig "${BUILD_PREFIX}"
create_gcc14_glibc28_compat_lib
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "linux-64"
create_pthread_atfork_stub "x86_64" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
