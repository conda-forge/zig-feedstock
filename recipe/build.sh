#!/usr/bin/env bash

set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

builder=zig
force_cmake=0

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

export cmake_source_dir="${SRC_DIR}/zig-source"
export cmake_build_dir="${SRC_DIR}/build-release"
export cmake_install_dir="${SRC_DIR}/cmake-built-install"
export zig_build_dir="${SRC_DIR}/conda-zig-source"

# Set zig: This may need to be changed when the previous conda zig fails to compile a new version
export zig="${BUILD_PREFIX}"/bin/zig

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# Declare global arrays with common flags
EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_SHARED_LLVM=ON
  -DZIG_USE_LLVM_CONFIG=ON
  -DZIG_SYSTEM_LIBCXX=stdc++
)

EXTRA_ZIG_ARGS=(
  -Dconfig_h=${cmake_build_dir}/config.h
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-zig-libcxx=false
)

CMAKE_PATCHES=()

case "${target_platform}" in
  linux-64|osx-64|win-64)
    source "${RECIPE_DIR}"/build_scripts/native-"${builder}-${target_platform}".sh
    ;;
  osx-arm64|linux-ppc64le|linux-aarch64)
    source "${RECIPE_DIR}"/build_scripts/cross-"${builder}-${target_platform}".sh
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac

if [[ "${force_cmake:-0}" != "1" ]] && build_zig_with_zig "${zig_build_dir}" "${zig}" "${PREFIX}"; then
  echo "SUCCESS: zig build completed successfully"
elif [[ "${target_platform}" == "osx-arm64" ]]; then
  echo "***"
  echo "* ERROR: We cannot build with CMake without an emulator - Temporarily skip ARM64 and rebuild with the new ZIG x86_64"
  echo "***"
  exit 1
elif [[ "${target_platform}" == "linux-ppc64le" ]]; then
  echo "***"
  echo "* ERROR: zig build fails to complete with CMake (>6hrs) - Temporarily skip PPC64LE and rebuild with the new ZIG x86_64"
  echo "***"
  exit 1
else
  echo "Applying CMake patches..."
  apply_cmake_patches "${cmake_source_dir}"

  if cmake_build_install "${cmake_build_dir}"; then
    echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed"
    exit 1
  fi
fi
