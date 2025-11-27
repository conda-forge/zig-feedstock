#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="x86_64"
ZIG_ARCH="x86_64"

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_ARCH}-linux-gnu
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "linux-64"

# Create pthread_atfork stub for CMake fallback
create_pthread_atfork_stub "x86_64" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

if [[ -f "${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o" ]]; then
  echo "✓ pthread_atfork stub created successfully at: ${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o"
else
  echo "✗ WARNING: pthread_atfork stub was NOT created!"
fi
