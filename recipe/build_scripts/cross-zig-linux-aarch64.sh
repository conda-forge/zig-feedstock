#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

# Disable stack protection for cross-compilation build tools
# The intermediate build tools (zig-wasm2c, zig1) don't need stack protection
# and glibc 2.28 aarch64 has issues with __stack_chk_guard symbol
export CFLAGS="${CFLAGS} -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS} -fno-stack-protector"

EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${CONDA_BUILD_SYSROOT}/lib64
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# perl -pi -e 's/#define ZIG_LLVM_LINK_MODE "static"/#define ZIG_LLVM_LINK_MODE "shared"/g' "${cmake_build_dir}/config.h"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
cat "${cmake_build_dir}/config.h"

# Create Zig libc configuration file
create_zig_libc_file "${zig_build_dir}/libc_file"

# Create pthread_atfork stub for glibc 2.28 (missing on aarch64)
create_pthread_atfork_stub "aarch64" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

# Remove documentation tests that fail during cross-compilation
remove_failing_langref "${zig_build_dir}"
