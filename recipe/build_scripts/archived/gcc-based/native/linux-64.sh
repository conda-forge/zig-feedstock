#!/usr/bin/env bash
# Native build for linux-64
# Binary RUNS on linux-64, TARGETS linux-64

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

SYSROOT_ARCH="x86_64"
ZIG_TARGET="x86_64-linux-gnu"

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_TARGET}
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
)

# Zig searches for libm.so/libc.so in incorrect paths
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library
create_gcc14_glibc28_compat_lib

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "linux-64"

# Create pthread_atfork stub for CMake fallback
create_pthread_atfork_stub "x86_64" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

if [[ -f "${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o" ]]; then
  echo "✓ pthread_atfork stub created successfully"
fi
