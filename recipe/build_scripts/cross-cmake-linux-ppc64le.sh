#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
SYSROOT_ARCH="aarch64"

EXTRA_CMAKE_ARGS+=( \
  "-DZIG_SHARED_LLVM=ON" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=x86_64-linux-gnu" \
  "-DZIG_DYNAMIC_LINKER=${PREFIX}/lib/ld-linux-ppc64le.so.2" \
)
# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

if [[ "${CROSSCOMPILING_EMULATOR:-0}" == *"qemu"* ]]; then
  # This is a hack to make zig use the correct qemu binary
  ln -s "${CROSSCOMPILING_EMULATOR}" "${BUILD_PREFIX}/bin/qemu-${SYSROOT_ARCH}"
  export CROSSCOMPILING_EMULATOR="${CROSSCOMPILING_EMULATOR}"
  export ZIG_CROSS_TARGET_TRIPLE="${SYSROOT_ARCH}"-linux-gnu
fi

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
# remove_failing_langref "${cmake_build_dir}"
cmake_build_zig2 "${cmake_build_dir}"
patchelf_for_2.28 "${cmake_build_dir}/zig2" "${PREFIX}"
cmake_build_install "${cmake_build_dir}"
