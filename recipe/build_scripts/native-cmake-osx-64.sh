#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

# Current conda zig may not be able to build the latest zig
SYSROOT_ARCH="x86_64"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DZIG_SHARED_LLVM=ON" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-macos-none" \
  "-DZIG_TARGET_MCPU=baseline" \
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
sed -i "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
cmake_build_install "${cmake_build_dir}"
