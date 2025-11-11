#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${zig_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

SYSROOT_ARCH="aarch64"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"
ZIG_ARCH="aarch64"

zig="${BUILD_PREFIX}"/bin/zig

# This is safe-keep for when non-backward compatible updates are introduced
# zig="${SRC_DIR}/zig-bootstrap/zig"

EXTRA_CMAKE_ARGS+=(
  "-DZIG_SHARED_LLVM=ON"
  "-DZIG_USE_LLVM_CONFIG=OFF"
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu"
  "-DZIG_TARGET_MCPU=baseline"
  "-DZIG_SYSTEM_LIBCXX=stdc++"
  "-DZIG_SINGLE_THREADED=ON"
)

# For some reason using the defined CMAKE_ARGS makes the build fail
USE_CMAKE_ARGS=0

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

cat > "${zig_build_dir}"/libc_file << EOF
include_dir=${SYSROOT_PATH}/usr/include
sys_include_dir=${SYSROOT_PATH}/usr/include
crt_dir=${SYSROOT_PATH}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=(
  "--libc ${zig_build_dir}/libc_file"
  "-fqemu"
  "--libc-runtimes ${SYSROOT_PATH}/lib64"
  "-Dconfig_h=${cmake_build_dir}/config.h"
  "-Denable-llvm"
  "-Duse-zig-libcxx=false"
  "-Dsingle-threaded=true"
  "-Dtarget=${ZIG_ARCH}-linux-gnu"
  "-Dcpu=baseline"
)
  # "-Dstrip"
  # "-Ddynamic-linker=${TARGET_INTERPRETER}"

ln -sf "$(which qemu-aarch64-static)" "${BUILD_PREFIX}/bin/qemu-aarch64"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

remove_failing_langref "${zig_build_dir}"
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
