#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# --- Functions ---

source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig, remove_failing_langref

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

if [[ "${PKG_NAME:-}" != "zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: ${PKG_NAME} - Verify recipe.yaml script:"
  exit 1
fi

# === Build caching for quick recipe iteration ===
# Set ZIG_USE_CACHE=1 to enable build caching:
#   - First run: builds normally, caches result
#   - Subsequent runs: restores from cache, skips build
if [[ "${ZIG_USE_CACHE:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  if stub_cache_restore; then
    echo "=== Build restored from cache (skipping compilation) ==="
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi

# --- Main ---

# This allows to skip a known failing zig build with zig
force_cmake=0

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# --- Common CMake/zig configuration ---

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_SHARED_LLVM=ON
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
  -DZIG_USE_LLVM_CONFIG=ON
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  --search-prefix "${PREFIX}"
  -fallow-so-scripts
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Dstatic-llvm=false
  -Dtarget=${ZIG_TRIPLET}
  -Duse-zig-libcxx=false
)
#  -Dstrip=true

# --- Platform Configuration ---

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    -fqemu
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  modify_libc_libm_for_zig "${BUILD_PREFIX}"
  create_gcc14_glibc28_compat_lib
  
  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
  is_cross && is_osx && ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath "${BUILD_PREFIX}"/lib "${PREFIX}"/bin/llvm-config
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- Post CMake Configuration ---

# Add conda separated library dependencies to config.h - This seems to be doing the same thing ... odd
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

is_debug && echo "=== DEBUG ===" && cat "${cmake_build_dir}"/config.h && echo "=== DEBUG ==="

# Stage 1 (Linux only): Build zig with -Dno-langref to bootstrap past ld script TODOs.
# The conda zig_impl bootstrap can't handle GNU ld scripts with relative paths/-l flags
# (fixed in patch 0006). Stage 1 produces a zig with the fix; Stage 2 uses it as bootstrap
# so langref doctests (which link -lc) can process sysroot ld scripts correctly.
# On non-Linux or if Stage 1 fails, fall back to stripping failing langref tests.
if is_linux; then
  stage1_install_dir="${SRC_DIR}/stage1-install"
  mkdir -p "${stage1_install_dir}"
  echo "=== Stage 1: Building zig with -Dno-langref (bootstrap lacks ld script support) ==="
  EXTRA_ZIG_ARGS+=(-Dno-langref)
  if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${stage1_install_dir}"; then
    echo "=== Stage 1 SUCCESS — switching bootstrap to Stage 1 zig ==="
    # Remove -Dno-langref for Stage 2
    _new_args=()
    for _a in "${EXTRA_ZIG_ARGS[@]}"; do
      [[ "$_a" != "-Dno-langref" ]] && _new_args+=("$_a")
    done
    EXTRA_ZIG_ARGS=("${_new_args[@]}")
    unset _new_args _a
    # Stage 2 uses the freshly-built zig (has patches 0004+0006)
    # Fix RPATH so Stage 1 zig can find LLVM shared libs from $PREFIX
    patchelf --set-rpath "${PREFIX}/lib" "${stage1_install_dir}/bin/zig"
    BUILD_ZIG="${stage1_install_dir}/bin/zig"
  else
    echo "=== Stage 1 FAILED — falling back to remove_failing_langref ==="
    # Remove -Dno-langref since we won't use two-stage
    _new_args=()
    for _a in "${EXTRA_ZIG_ARGS[@]}"; do
      [[ "$_a" != "-Dno-langref" ]] && _new_args+=("$_a")
    done
    EXTRA_ZIG_ARGS=("${_new_args[@]}")
    unset _new_args _a
    remove_failing_langref "${zig_build_dir}"
  fi
fi

if is_linux && is_cross; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  # Fix sysroot libc.so linker scripts 2.17 to use relative paths
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
fi

echo "=== Building with ZIG ==="
if [[ "${force_cmake:-0}" != "1" ]] && build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  echo "SUCCESS: zig build completed successfully"
elif [[ "${cross_target_platform_}" == "osx-arm64" ]]; then
  echo "***"
  echo "* ERROR: We cannot build cross-target osx-arm64 with CMake without an emulator"
  echo "* Temporarily skip and rebuild with the new ZIG from osx-64"
  echo "***"
  exit 1
elif [[ "${cross_target_platform_}" == "linux-ppc64le" ]]; then
  echo "***"
  echo "* ERROR: zig build fails to complete cross-target linux-ppc64le with CMake (>6hrs)"
  echo "* Temporarily skip and rebuild with the new ZIG from linux-64"
  echo "***"
  exit 1
else
  source "${RECIPE_DIR}/building/_cmake.sh"  # apply_cmake_patches, cmake_build_install
  CMAKE_PATCHES=()

  if is_linux; then
    CMAKE_PATCHES+=(
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
      perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TRIPLET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
  fi
  if is_not_unix; then
    _version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
    _UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
    _MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/${_version}/lib/x64"
    EXTRA_CMAKE_ARGS+=(
      -DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}"
    )
    CMAKE_PATCHES+=(
      0001-win-deprecations-zig_llvm.cpp.patch
      0001-win-deprecations-zig_llvm-ar.cpp.patch
    )
  fi

  echo "Applying CMake patches..."
  apply_cmake_patches "${cmake_source_dir}"

  if cmake_build_install "${cmake_build_dir}" "${PREFIX}"; then
    echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed"
    exit 1
  fi
fi

# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Windows conda convention: artifacts go under Library/
if is_not_unix; then
  echo "Relocating to Library/ for Windows conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

echo "=== Build installed for package: ${PKG_NAME} ==="

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  echo "=== Build cached for future restoration ==="
fi
