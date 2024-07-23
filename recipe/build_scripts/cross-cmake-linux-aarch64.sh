#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

cmake_build_dir="${SRC_DIR}/_conda-cmake-build"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

mkdir -p "${SRC_DIR}"/_conda-build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/_conda-build-level-patches

# Current conda zig may not be able to build the latest zig
SYSROOT_ARCH="aarch64"
SYSROOT_PATH="${PREFIX}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-linux-${SYSROOT_ARCH}.so.1"

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_PREFIX_PATH=${PREFIX};${SYSROOT_PATH}" \
  "-DCMAKE_C_COMPILER=${CC}" \
  "-DCMAKE_CXX_COMPILER=${CXX}" \
  "-DZIG_SHARED_LLVM=ON" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu" \
)
# This path is too long for Target.zig
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

USE_CMAKE_ARGS=1

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF

cmake_build_cmake_target "${cmake_build_dir}" zig2
patchelf_sysroot_interpreter "${SYSROOT_PATH}" "${TARGET_INTERPRETER}" "${cmake_build_dir}/zig2" 1

sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${PREFIX}/bin@g" "${cmake_build_dir}/config.h"
pushd "${cmake_build_dir}"
  cmake --build . -- -j"${CPU_COUNT}"
  cmake --install .
popd

# patchelf --set-interpreter "${TARGET_INTERPRETER}" "${PREFIX}/bin/zig"
patchelf --set-rpath "\$ORIGIN/../${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64" "${PREFIX}/bin/zig"
patchelf --add-rpath "\$ORIGIN/../lib" "${PREFIX}/bin/zig"

${QEMU_EXECVE} "${PREFIX}/bin/zig" version

# patchelf_sysroot_interpreter "${SYSROOT_PATH}" "${TARGET_INTERPRETER}" "${PREFIX}/bin/zig"

# Use stage3/zig to self-build: This failed locally with SEGV in qemu
# build_zig_with_zig "${zig_build_dir}" "${PREFIX}/bin/zig" "${PREFIX}"
