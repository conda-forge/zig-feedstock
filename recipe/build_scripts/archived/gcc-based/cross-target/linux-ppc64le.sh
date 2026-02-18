#!/usr/bin/env bash
# Cross-target build for linux-ppc64le
# Binary RUNS on linux-ppc64le (cross-compiled from linux-64)
# Requires sysroot and QEMU for emulation

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
ZIG_TARGET="powerpc64le-linux-gnu"

# Disable stack protection for cross-compilation build tools
export CFLAGS="${CFLAGS} -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS} -fno-stack-protector"

qemu_prg=qemu-ppc64le-static

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${SYSROOT_PATH}/lib64
  -Dtarget=${ZIG_TARGET}
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
  0003-cross-CMakeLists.txt.patch
)

# Zig searches for libm.so/libc.so in incorrect paths
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library
create_gcc14_glibc28_compat_lib
setup_crosscompiling_emulator "${qemu_prg}"
create_qemu_llvm_config_wrapper "${SYSROOT_PATH}"
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
remove_qemu_llvm_config_wrapper

perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"

# Create Zig libc configuration file
create_zig_libc_file "${zig_build_dir}/libc_file" "${SYSROOT_PATH}" "${SYSROOT_ARCH}"

# Setup QEMU for the ZIG build
ln -sf "$(which qemu-ppc64le-static)" "${BUILD_PREFIX}/bin/qemu-ppc64le"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

# Create pthread_atfork stub
create_pthread_atfork_stub "powerpc64le" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

# Remove documentation tests that fail during cross-compilation
remove_failing_langref "${zig_build_dir}"

# Prepare fallback CMake
perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TARGET}"
export ZIG_CROSS_TARGET_MCPU="baseline"
