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

_UCRT_LIBPATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"

export FIRST_PATH="${LIBPATH%%;*}"
where version.dll
EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_VERBOSE_MAKEFILE=ON" \
  "-DZIG_CMAKE_PREFIX_PATH=${_UCRT_LIBPATH//\\//};${LIBPATH//\\//}" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-windows-msvc" \
)
  # "-DZIG_SYSTEM_LIBCXX='c++'" \
  # "-DZIG_USE_LLVM_CONFIG=ON" \
  # "-DZIG_STATIC_LLVM=ON" \

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"

# sed -i '' "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
pushd "${cmake_build_dir}"
  cat config.h || true
  cat config.zig || true
popd

cmake_build_install "${cmake_build_dir}"
