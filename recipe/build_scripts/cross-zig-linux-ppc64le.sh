#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${cmake_install_dir}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

SYSROOT_ARCH="powerpc64le"
ZIG_ARCH="powerpc64"

zig=zig

# This is safe-keep for when non-backward compatible updates are introduced
# zig="${SRC_DIR}/zig-bootstrap/zig"

EXTRA_CMAKE_ARGS+=(
  "-DZIG_SHARED_LLVM=OFF"
  "-DZIG_USE_LLVM_CONFIG=ON"
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu"
  "-DZIG_TARGET_MCPU=baseline"
  "-DZIG_SYSTEM_LIBCXX=stdc++"
  "-DZIG_SINGLE_THREADED=ON"
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF
#sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${BUILD_PREFIX}/bin@g" "${cmake_build_dir}/config.h"

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=(
  "-Dconfig_h=${cmake_build_dir}/config.h"
  "-Denable-llvm"
  "-Dstrip"
  "-Duse-zig-libcxx=false"
  "-Dtarget=${ZIG_ARCH}-linux-gnu"
)

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
