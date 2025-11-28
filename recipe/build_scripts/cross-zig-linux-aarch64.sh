#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="aarch64"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
ZIG_ARCH="aarch64"

# Disable stack protection for cross-compilation build tools
# The intermediate build tools (zig-wasm2c, zig1) don't need stack protection
# and glibc 2.28 aarch64 has issues with __stack_chk_guard symbol
export CFLAGS="${CFLAGS} -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS} -fno-stack-protector"

qemu_prg=qemu-aarch64-static

# Update global arrays
EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE="${ZIG_ARCH}"-linux-gnu
)

EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${SYSROOT_PATH}/lib64
  -Dtarget=${ZIG_ARCH}-linux-gnu
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
  0003-cross-CMakeLists.txt.patch
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib
setup_crosscompiling_emulator "${qemu_prg}"
create_qemu_llvm_config_wrapper "${SYSROOT_PATH}"
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
remove_qemu_llvm_config_wrapper

# perl -pi -e 's/#define ZIG_LLVM_LINK_MODE "static"/#define ZIG_LLVM_LINK_MODE "shared"/g' "${cmake_build_dir}/config.h"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
cat "${cmake_build_dir}/config.h"

# Create Zig libc configuration file
create_zig_libc_file "${zig_build_dir}/libc_file" "${SYSROOT_PATH}" "${SYSROOT_ARCH}"

# Setup QEMU for the ZIG build (It is likely not used, but when in doubt ...)
ln -sf "$(which qemu-aarch64-static)" "${BUILD_PREFIX}/bin/qemu-aarch64"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

# Create pthread_atfork stub for glibc 2.28 (missing on aarch64)
create_pthread_atfork_stub "aarch64" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

# Remove documentation tests that fail during cross-compilation
remove_failing_langref "${zig_build_dir}"

# Prepare fallback CMake
# This will break the reconfigure: perl -pi -e 's/COMMAND ${LLVM_CONFIG_EXE}/COMMAND $ENV{CROSSCOMPILING_EMULATOR} ${LLVM_CONFIG_EXE}/' "${cmake_source_dir}"/cmake/Findllvm.cmake
perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="baseline"
