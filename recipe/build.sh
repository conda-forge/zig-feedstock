#!/usr/bin/env bash

set -euxo pipefail
IFS=$'\n\t'

# CRITICAL: Ensure we're using conda bash 5.2+, not system bash
# The shebang uses /bin/bash, but conda-build will invoke this with the
# build environment's bash through its own execution wrapper.
if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "ERROR: This script requires bash 5.2 or later (found ${BASH_VERSION})"
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# === Stub mode for quick recipe iteration ===
# Set ZIG_STUB_MODE=1 to skip full compilation and install placeholder binaries
if [[ "${ZIG_STUB_MODE:-0}" == "1" ]]; then
    echo "=== STUB MODE ENABLED ==="
    echo "Installing stub binaries instead of full compilation"
    echo "  TARGET_TRIPLET=${TARGET_TRIPLET}"
    echo "  TG_=${TG_:-not set}"
    echo "  ZIG_TARGET=${ZIG_TARGET:-not set}"
    python "${RECIPE_DIR}/scripts/install_zig_stub.py"
    # Rename to triplet-prefixed (same as real build post-install)
    mv "${PREFIX}/bin/zig" "${PREFIX}/bin/${TARGET_TRIPLET}-zig"
    echo "  Renamed: zig -> ${TARGET_TRIPLET}-zig"
    echo "=== STUB MODE COMPLETE ==="
    exit 0
fi

# === Package output detection ===
# rattler-build sets PKG_NAME for the current output being built
# PKG_VARIANT is set by recipe.yaml script env for impl packages
case "${PKG_NAME:-}" in
    zig_impl_*)
        echo "Building implementation package: ${PKG_NAME}"
        echo "  PKG_VARIANT=${PKG_VARIANT:-not set}"
        ;;
    *)
        echo "WARNING: Unknown package name: ${PKG_NAME}"
        exit 1
        ;;
esac

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

# Install bootstrap zig via mamba for:
# - build_number 8 (initial bootstrap)
# - needs_zig_llvmdev targets (no zig_impl dependency to avoid cycle)
NEEDS_MAMBA_BOOTSTRAP=0
if [[ "${PKG_VERSION}" == "0.15.2" ]] && [[ "${BUILD_NUMBER}" == "8" ]]; then
  NEEDS_MAMBA_BOOTSTRAP=1
fi
# Check if using zig-llvmdev (ZIG_BUILD_MODE=zig-native + no zig in BUILD_PREFIX)
if [[ "${ZIG_BUILD_MODE:-zig-native}" == "zig-native" ]] && [[ ! -x "${BUILD_PREFIX}/bin/zig" ]]; then
  NEEDS_MAMBA_BOOTSTRAP=1
fi

if [[ "${NEEDS_MAMBA_BOOTSTRAP}" == "1" ]]; then
  install_bootstrap_zig "0.15.2" "*_7"
  export zig="${BOOTSTRAP_ZIG:-${BUILD_PREFIX}/bin/zig}"
fi

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# Declare global arrays with common flags
EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_SHARED_LLVM=ON
  -DZIG_SYSTEM_LIBCXX=stdc++
  -DZIG_TARGET_MCPU=baseline
  -DZIG_USE_LLVM_CONFIG=ON
)

# Critical, CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-zig-libcxx=false
)

CMAKE_PATCHES=()

# === Build Mode Detection ===
# Determines which type of build script to use based on platform configuration
#
# Three build modes:
#   native:         TG_ == target_platform == build_platform
#                   Binary runs on same platform it's built on
#
#   cross-target:   TG_ == target_platform, but build_platform differs
#                   Binary RUNS on TG_ (cross-compiled, needs sysroot/QEMU)
#
#   cross-compiler: TG_ != target_platform, build_platform == target_platform
#                   Binary RUNS on target_platform, TARGETS TG_ (no sysroot needed!)

if [[ "${TG_}" != "${target_platform}" && "${build_platform}" == "${target_platform}" ]]; then
    build_mode="cross-compiler"
elif [[ "${TG_}" == "${target_platform}" && "${build_platform}" != "${target_platform}" ]]; then
    build_mode="cross-target"
else
    build_mode="native"
fi

# === Build Compiler Selection ===
# ZIG_BUILD_MODE controls whether to use zig cc or GCC as the C/C++ compiler
#
#   zig-native (default): Use zig as C/C++ compiler (eliminates GCC workarounds)
#   bootstrap:            Use GCC as C/C++ compiler (fallback, archived scripts)
#
ZIG_BUILD_MODE="${ZIG_BUILD_MODE:-zig-native}"

echo "=== Build Configuration ==="
echo "  build_mode:      ${build_mode}"
echo "  ZIG_BUILD_MODE:  ${ZIG_BUILD_MODE}"
echo "  build_platform:  ${build_platform}"
echo "  target_platform: ${target_platform}"
echo "  TG_:             ${TG_}"

# Dispatch to appropriate build script based on mode, TG_, and ZIG_BUILD_MODE
case "${build_mode}" in
    native)
        if [[ "${ZIG_BUILD_MODE}" == "bootstrap" ]]; then
            script_path="${RECIPE_DIR}/build_scripts/archived/gcc-based/native/${TG_}.sh"
        else
            script_path="${RECIPE_DIR}/build_scripts/native/${TG_}.sh"
        fi
        ;;
    cross-target)
        if [[ "${ZIG_BUILD_MODE}" == "bootstrap" ]]; then
            script_path="${RECIPE_DIR}/build_scripts/archived/gcc-based/cross-target/${TG_}.sh"
        else
            script_path="${RECIPE_DIR}/build_scripts/cross-target/${TG_}.sh"
        fi
        ;;
    cross-compiler)
        if [[ "${ZIG_BUILD_MODE}" == "bootstrap" ]]; then
            script_path="${RECIPE_DIR}/build_scripts/archived/gcc-based/cross-compiler/${TG_}.sh"
        else
            script_path="${RECIPE_DIR}/build_scripts/cross-compiler/${TG_}.sh"
        fi
        ;;
    *)
        echo "ERROR: Unknown build_mode: ${build_mode}"
        exit 1
        ;;
esac

if [[ -f "${script_path}" ]]; then
    echo "  Loading: ${script_path}"
    source "${script_path}"
else
    echo "ERROR: Build script not found: ${script_path}"
    echo "  Available scripts:"
    ls -la "${RECIPE_DIR}/build_scripts/${build_mode}/" 2>/dev/null || echo "    (directory not found)"
    exit 1
fi

if [[ "${force_cmake:-0}" != "1" ]] && build_zig_with_zig "${zig_build_dir}" "${zig}" "${PREFIX}"; then
  echo "SUCCESS: zig build completed successfully"
elif [[ "${build_mode}" == "cross-target" && "${TG_}" == "osx-arm64" ]]; then
  echo "***"
  echo "* ERROR: We cannot build cross-target osx-arm64 with CMake without an emulator"
  echo "* Temporarily skip and rebuild with the new ZIG from osx-64"
  echo "***"
  exit 1
elif [[ "${build_mode}" == "cross-target" && "${TG_}" == "linux-ppc64le" ]]; then
  echo "***"
  echo "* ERROR: zig build fails to complete cross-target linux-ppc64le with CMake (>6hrs)"
  echo "* Temporarily skip and rebuild with the new ZIG from linux-64"
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

# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

case "${PKG_NAME:-}" in
    zig_impl_*)
        echo "Post-install implementation package: ${PKG_NAME}"
        mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${TARGET_TRIPLET}"-zig
        ;;
    *)
        echo "WARNING: Unknown package name: ${PKG_NAME}"
        exit 1
        ;;
esac
