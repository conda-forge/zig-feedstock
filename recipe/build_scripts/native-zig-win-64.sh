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

SYSROOT_ARCH="x86_64"

_UCRT_LIBPATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"

# ${PREFIX}/Library/bin/mamba.exe create -yp conda_zig_env zig
# zig="${SRC_DIR}"/conda_zig_env/bin/zig
# export PATH="${SRC_DIR}/conda_zig_env/bin:${PATH}"
zig="${SRC_DIR}"/zig-bootstrap/zig.exe

EXTRA_CMAKE_ARGS+=( \
  "-DZIG_SHARED_LLVM=OFF" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-windows-msvc" \
  "-DZIG_TARGET_MCPU=baseline" \
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
powershell -Command "(Get-Content '${cmake_build_dir}/config.h') -replace 'zstd.dll.lib', 'zstd.lib' | Set-Content '${cmake_build_dir}/config.h'"

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=( \
  "-Dconfig_h=${cmake_build_dir}/config.h" \
  "-Denable-llvm" \
  "-Dstrip" \
  "-Duse-zig-libcxx=false" \
  "-Dtarget=${SYSROOT_ARCH}-windows-msvc" \
  )

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
