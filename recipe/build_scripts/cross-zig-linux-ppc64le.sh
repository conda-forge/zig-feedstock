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

# STAGE 1: Build x86_64 Zig with PowerPC64LE patches for use as bootstrap compiler
echo "=== STAGE 1: Building x86_64 Zig with PowerPC64LE support ==="
stage1_build_dir="${SRC_DIR}/stage1-x86_64"
stage1_zig="${stage1_build_dir}/bin/zig"
(

  mkdir -p "${stage1_build_dir}"
  cp -r "${SRC_DIR}"/zig-source/* "${stage1_build_dir}"
  remove_failing_langref "${stage1_build_dir}"

  # Build native x86_64 Zig with patches applied (patches already applied during source extraction)
  # Need to build with LLVM support for proper cross-compilation
  # Save cross-compilation flags and clear them for native build
  SAVED_CFLAGS="${CFLAGS}"
  SAVED_CXXFLAGS="${CXXFLAGS}"
  SAVED_LDFLAGS="${LDFLAGS}"
  unset CFLAGS CXXFLAGS LDFLAGS

  cd "${stage1_build_dir}"
  "${BUILD_PREFIX}/bin/zig" build \
    --prefix "${stage1_build_dir}" \
    --sysroot "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot" \
    -fqemu \
    -Doptimize=ReleaseFast \
    -Dskip-release-fast=true \
    -Dstatic-llvm \
    -Dversion-string="${PKG_VERSION}"
  cd -

  # Restore cross-compilation flags for Stage 2
  export CFLAGS="${SAVED_CFLAGS}"
  export CXXFLAGS="${SAVED_CXXFLAGS}"
  export LDFLAGS="${SAVED_LDFLAGS}"

  echo "Stage 1 Zig built at: ${stage1_zig}"
  "${stage1_zig}" version
)

# Now set up PowerPC64LE cross-compilation environment for Stage 2
SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"
ZIG_ARCH="powerpc64le"

# Add ld.bfd for relocation issue
export CFLAGS="${CFLAGS} -fuse-ld=bfd"
export CXXFLAGS="${CXXFLAGS} -fuse-ld=bfd"
export LDFLAGS="${LDFLAGS} -fuse-ld=bfd"

echo "Stage 1 Zig built at: ${stage1_zig}"
"${stage1_zig}" version

# Use stage 1 Zig for cross-compilation
zig="${stage1_zig}"

EXTRA_CMAKE_ARGS+=(
  "-DZIG_SHARED_LLVM=ON"
  "-DZIG_USE_LLVM_CONFIG=OFF"
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu"
  "-DZIG_TARGET_MCPU=baseline"
  "-DZIG_SYSTEM_LIBCXX=stdc++"
)
#  "-DZIG_SINGLE_THREADED=ON"

# For some reason using the defined CMAKE_ARGS makes the build fail
USE_CMAKE_ARGS=0

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
# cat <<EOF >> "${cmake_build_dir}/config.zig"
# pub const mem_leak_frames = 0;
# EOF
#sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${BUILD_PREFIX}/bin@g" "${cmake_build_dir}/config.h"

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
# For ppc64le, we need to force use of ld.bfd instead of lld due to relocation issues
EXTRA_ZIG_ARGS+=(
  "-Dconfig_h=${cmake_build_dir}/config.h"
  "-Dstatic-llvm"
  "-Duse-zig-libcxx=false"
  "-Dtarget=${ZIG_ARCH}-linux-gnu"
  "-Dcpu=baseline"
)
#  "-Dstrip"

export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
remove_failing_langref "${SRC_DIR}/conda-zig-source"

# Capture full build output to log file
mkdir -p "${SRC_DIR}/build-logs"
LOG_FILE="${SRC_DIR}/build-logs/ppc64le-build-$(date +%Y%m%d-%H%M%S).log"
echo "Capturing build output to ${LOG_FILE}" | tee "${LOG_FILE}"

build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}" 2>&1 | tee -a "${LOG_FILE}"
BUILD_STATUS=${PIPESTATUS[0]}

echo "Build completed with status: ${BUILD_STATUS}" | tee -a "${LOG_FILE}"
exit ${BUILD_STATUS}
