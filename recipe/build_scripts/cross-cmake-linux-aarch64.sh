#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/_conda-cmake-build"
zig_build_dir="${SRC_DIR}/_conda-zig-build"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

mkdir -p "${SRC_DIR}"/_conda-build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/_conda-build-level-patches

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
SYSROOT_ARCH="aarch64"
SYSROOT_PATH="${PREFIX}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-linux-${SYSROOT_ARCH}.so.1"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_PREFIX_PATH=${PREFIX};${SYSROOT_PATH}" \
  "-DCMAKE_C_COMPILER=${CC}" \
  "-DCMAKE_CXX_COMPILER=${CXX}" \
  "-DZIG_SHARED_LLVM=ON" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu" \
)
# This path is too oong for Target.zig
#  "-DZIG_TARGET_DYNAMIC_LINKER=${TARGET_INTERPRETER}" \

source "${RECIPE_DIR}/build_scripts/_build_qemu_execve.sh"
build_qemu_execve "${SYSROOT_ARCH}"

# export CROSSCOMPILING_EMULATOR="${BUILD_PREFIX}/bin/qemu-${SYSROOT_ARCH}"

export CROSSCOMPILING_EMULATOR="${QEMU_EXECVE}"
export CROSSCOMPILING_LIBC="Wl,-dynamic-linker,${TARGET_INTERPRETER};-L${SYSROOT_PATH}/lib64;-lc"

export CFLAGS="${CFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"
export CXXFLAGS="${CXXFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"

export ZIG_CROSS_TARGET_TRIPLE="${SYSROOT_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="native"

# When using installed c++ libs, zig needs libzigcpp.a
USE_CMAKE_ARGS=1

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF

# remove_failing_langref "${cmake_build_dir}"
cmake_build_cmake_target "${cmake_build_dir}" zig-wasm2c
cmake_build_cmake_target "${cmake_build_dir}" zig1
cmake_build_cmake_target "${cmake_build_dir}" zig2

patchelf_sysroot_interpreter "${SYSROOT_PATH}" "${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1" "${cmake_build_dir}/zig2" 1

sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${PREFIX}/bin@g" "${cmake_build_dir}/config.h"
pushd "${cmake_build_dir}"
  cmake --build . -- -j"${CPU_COUNT}"
  cmake --install .
popd

# Use stage3/zig to self-build
# Zig needs the config.h to correctly (?) find the conda installed llvm, etc

EXTRA_ZIG_ARGS+=( \
  "-Doptimize=ReleaseSafe" \
  "-Denable-llvm" \
  "-Dstrip" \
  "-Duse-zig-libcxx=false" \
)

patchelf_sysroot_interpreter "${SYSROOT_PATH}" "${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1" "${cmake_build_dir}/stage3/bin/zig"

# mkdir -p "${zig_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${zig_build_dir}"
# build_zig_with_zig "${zig_build_dir}" "${cmake_build_dir}/stage3/bin/zig" "${PREFIX}"
