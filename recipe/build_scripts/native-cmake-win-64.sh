#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

SYSROOT_ARCH="x86_64"

_UCRT_LIBPATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_VERBOSE_MAKEFILE=ON" \
  "-DZIG_CMAKE_PREFIX_PATH=${_UCRT_LIBPATH};${LIBPATH}" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-windows-msvc" \
)
  # "-DZIG_SYSTEM_LIBCXX='c++'" \
  # "-DZIG_USE_LLVM_CONFIG=ON" \
  # "-DZIG_STATIC_LLVM=ON" \

configure_cmake "${cmake_build_dir}" "${PREFIX}"

pushd "${cmake_build_dir}"
  # This is very hack-ish, but it seemd impossible to tell stage3/zig to find the needed version, uuid, ole32, etc DLLs
  # It goes with a patch of build.zig to accept multiple paths
  powershell -Command "(Get-Content config.h) -replace 'ZIG_LLVM_LIB_PATH \"', 'ZIG_LLVM_LIB_PATH \"C:/Windows/System32;C:/Program Files (x86)/Windows Kits/10/Lib/10.0.22621.0/um/x64;\"' | Set-Content config.h"
  cat config.h
popd

cmake_build_install "${cmake_build_dir}"
