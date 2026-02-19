#!/usr/bin/env bash

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

case "${target_platform}" in
  *-64)
    ZIG_ARCH="x86_64"
    ;;
  *-arm64|*-aarch64)
    ZIG_ARCH="aarch64"
    ;;
  *-ppc64le)
    ZIG_ARCH="powerpc64le"
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac

case "${target_platform}" in
  linux-*)
    ZIG_TARGET_TRIPLE=${ZIG_ARCH}-linux-gnu
    ;;
  osx-*)
    ZIG_TARGET_TRIPLE=${ZIG_ARCH}-macos-none
    ;;
  win-*)
    ZIG_TARGET_TRIPLE=${ZIG_ARCH}-windows-msvc
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac

# Declare global arrays with common flags
EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_TARGET_MCPU=baseline
  -DZIG_USE_LLVM_CONFIG=ON
  -DZIG_TARGET_TRIPLE=${ZIG_TARGET_TRIPLE}
)

# Critical, CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-zig-libcxx=false
  -Dtarget=${ZIG_TARGET_TRIPLE}
)

if [[ "${target_platform}" == "osx-"* ]]; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=stdc++
  )
fi

if [[ "${target_platform}" == "win-"* ]]; then
  # windows LLVM is static only
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    -DZIG_CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH};${LIB}"
  )
  EXTRA_ZIG_ARGS+=(
    --maxrss 7500000000
  )
else
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=ON
  )
fi

source "${RECIPE_DIR}/build_scripts/_functions.sh"

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" && "${target_platform}" == "linux-*" ]]; then
  if [[ "${CROSSCOMPILING_EMULATOR:-}" == "" ]]; then
    echo "We require a crosscompiling_emulator for linux;"
    exit 1
  fi
  EXTRA_ZIG_ARGS+=(
    -fqemu
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes ${CONDA_BUILD_SYSROOT}/lib
  )
  # Remove documentation tests that fail during cross-compilation
  remove_failing_langref "${zig_build_dir}"
  # Create Zig libc configuration file
  create_zig_libc_file "${zig_build_dir}/libc_file"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" && "${CMAKE_CROSSCOMPILING_EMULATOR:-}" == "" ]]; then
  rm $PREFIX/bin/llvm-config
  cp $BUILD_PREFIX/bin/llvm-config $PREFIX/bin/llvm-config
  if [[ "$target_platform" == osx-* ]]; then
    ${INSTALL_NAME_TOOL:-install_name_tool} -add_rpath $BUILD_PREFIX/lib $PREFIX/bin/llvm-config
  fi
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
  export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TARGET_TRIPLE}"
  export ZIG_CROSS_TARGET_MCPU="baseline"
fi

if [[ "$target_platform" == "linux-"* ]]; then
  # Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
  modify_libc_libm_for_zig "${BUILD_PREFIX}"
  # Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
  create_gcc14_glibc28_compat_lib
fi
# Now that build scripts are much simpler, scripts could remove native/cross
case "${target_platform}" in
  linux-64|osx-64|osx-arm64)
    # When using installed c++ libs, zig needs libzigcpp.a
    configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "${target_platform}"
    ;;
  win-64)
    source "${RECIPE_DIR}"/build_scripts/native-"${builder}-${target_platform}".sh
    ;;
  linux-ppc64le|linux-aarch64)
    source "${RECIPE_DIR}"/build_scripts/cross-"${builder}-${target_platform}".sh
    ;;
  *)
    echo "Unsupported target_platform: ${target_platform}"
    exit 1
    ;;
esac

case "${target_platform}" in
  osx-arm64)
    perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
    ;;
  osx-64)
    perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
    ;;
  linux-*)
    # Create pthread_atfork stub for CMake fallback
    create_pthread_atfork_stub "${ZIG_ARCH}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
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
  if cmake_build_install "${cmake_build_dir}"; then
    echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed"
    exit 1
  fi
fi

# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb
