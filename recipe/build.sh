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

# --- Early exits ---

[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }

build_platform="${build_platform:-${target_platform}}"
if [[ "${build_platform}" == "${target_platform}" && "${TG_}" != "${target_platform}" ]]; then
  echo "ZIG cross-compiler are wrappers around the Native ZIG: Done"
  exit 0
fi

if [[ "${PKG_NAME:-}" != "zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: ${PKG_NAME} - Verify recipe.yaml script:"
  exit 1
fi

# Local debugging
if [[ "${ZIG_STUB_MODE:-0}" == "1" ]]; then
  echo "=== STUB MODE ENABLED ==="
  python "${RECIPE_DIR}/scripts/install_zig_stub.py"
  mv "${PREFIX}/bin/zig" "${PREFIX}/bin/${TARGET_TRIPLET}-zig"
  echo "=== STUB MODE COMPLETE ==="
  exit 0
fi

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig, remove_failing_langref

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

# --- Main ---

# This allows to skip a known failing zig build with zig
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
# - This should only be needed for 0.15.2 *_8 (it avoid output cycles due to zig -> metapackage)
if [[ "${PKG_VERSION}" == "0.15.2" ]] && [[ "${BUILD_NUMBER}" == "8" ]] || [[ ! -x "${BUILD_PREFIX}/bin/zig" ]]; then
  source "${RECIPE_DIR}/build_scripts/_bootstrap.sh"
  install_bootstrap_zig "0.15.2" "*_7"
  export zig="${BOOTSTRAP_ZIG:-${BUILD_PREFIX}/bin/zig}"
fi

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
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-zig-libcxx=false
  -Dtarget=${ZIG_TRIPLET}
)

# --- Platform Configuration ---

if is_osx; then
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
  EXTRA_ZIG_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
fi

if is_linux; then
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  _version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
  _UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
  _MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/${_version}/lib/x64"
  EXTRA_CMAKE_ARGS+=(-DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}")
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/build_scripts/_libc_tuning.sh"
  modify_libc_libm_for_zig "${BUILD_PREFIX}"
  create_gcc14_glibc28_compat_lib
  
  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
  is_cross && is_osx && ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath "${BUILD_PREFIX}"/lib "${PREFIX}"/bin/llvm-config
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- Post CMake Configuration ---

# Add conda separated library dependencies to config.h - This seems to be doing the same thing ... odd
is_linux &&             perl -pi -e 's@(#define ZIG_LLVM_LIBRARIES ".*)\"@$1;-lzstd;-lxml2;-lz"@' "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@;-lm@;-lc++;-lxml2;-lm@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;-L${PREFIX}/lib;-lxml2;-lzstd;-lz@" "${cmake_build_dir}"/config.h

echo "=== Pre ZIG build Configuration ==="
if is_linux && is_cross; then
  source "${RECIPE_DIR}/build_scripts/_cross.sh"
  create_zig_libc_file "${zig_build_dir}/libc_file"
  remove_failing_langref "${zig_build_dir}"
fi

if [[ "${force_cmake:-0}" != "1" ]] && build_zig_with_zig "${zig_build_dir}" "${zig}" "${PREFIX}"; then
  echo "SUCCESS: zig build completed successfully"
elif [[ "${TG_}" == "osx-arm64" ]]; then
  echo "***"
  echo "* ERROR: We cannot build cross-target osx-arm64 with CMake without an emulator"
  echo "* Temporarily skip and rebuild with the new ZIG from osx-64"
  echo "***"
  exit 1
elif [[ "${TG_}" == "linux-ppc64le" ]]; then
  echo "***"
  echo "* ERROR: zig build fails to complete cross-target linux-ppc64le with CMake (>6hrs)"
  echo "* Temporarily skip and rebuild with the new ZIG from linux-64"
  echo "***"
  exit 1
else
  source "${RECIPE_DIR}/build_scripts/_cmake.sh"  # apply_cmake_patches, cmake_build_install
  CMAKE_PATCHES=()

  if is_linux; then
    CMAKE_PATCHES+=(
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      source "${RECIPE_DIR}/build_scripts/_atfork.sh"
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
      perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
      create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
      perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TARGET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
  fi
  if is_not_unix; then
    CMAKE_PATCHES+=(
      0001-win-deprecations-zig_llvm.cpp.patch
      0001-win-deprecations-zig_llvm-ar.cpp.patch
    )
  fi

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

echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig
echo "=== Build installed for package: ${PKG_NAME} ==="
