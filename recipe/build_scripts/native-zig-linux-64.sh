#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

# Set up logging FIRST to capture all output
mkdir -p "${SRC_DIR}/build-logs"
LOG_FILE="${SRC_DIR}/build-logs/x86_64-build-$(date +%Y%m%d-%H%M%S).log"
echo "Capturing all build output to ${LOG_FILE}" | tee "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

export CMAKE_GENERATOR=Ninja
export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
  
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"
mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${zig_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}"

SYSROOT_ARCH="x86_64"
ZIG_ARCH="x86_64"

EXTRA_CMAKE_ARGS+=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_SHARED_LLVM=ON
  -DZIG_USE_LLVM_CONFIG=ON
  -DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu
  -DZIG_TARGET_MCPU=native
  -DZIG_SYSTEM_LIBCXX=stdc++
  -DZIG_SINGLE_THREADED=OFF
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "linux-64"

EXTRA_ZIG_ARGS+=(
  -Dconfig_h=${cmake_build_dir}/config.h
  -Dcpu=native
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-zig-libcxx=false
  -Dsingle-threaded=false
  -Dtarget=${ZIG_ARCH}-linux-gnu
)

build_zig_with_zig "${zig_build_dir}" "${BUILD_PREFIX}/bin/zig" "${PREFIX}"
