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

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
SYSROOT_ARCH="aarch64"
zig="${SRC_DIR}/zig-bootstrap/zig"

EXTRA_CMAKE_ARGS+=( \
"-DZIG_SHARED_LLVM=ON" \
"-DZIG_USE_LLVM_CONFIG=ON" \
"-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu" \
)
# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=( \
  "-Dconfig_h=${cmake_build_dir}/config.h" \
  "-Doptimize=ReleaseFast"
  "-Denable-llvm" \
  "-Dstrip" \
  "-Duse-zig-libcxx=false" \
  "-Dtarget=${SYSROOT_ARCH}-linux-gnu" \
  "-fqemu"
  "--glibc-runtimes" "${PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64/libc.so.6"
)

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
remove_failing_langref "${SRC_DIR}/conda-zig-source"
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
patchelf_installed_zig "${PREFIX}" "${PREFIX}"
