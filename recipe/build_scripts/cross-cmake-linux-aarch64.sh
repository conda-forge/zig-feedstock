#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/_conda-cmake-build"
mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"

mkdir -p "${SRC_DIR}"/_conda-build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/_conda-build-level-patches

# Current conda zig may not be able to build the latest zig
SYSROOT_ARCH="aarch64"
ZIG_ARCH="aarch64"
QEMU_ARCH="aarch64"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_BUILD_TYPE=Release" \
  "-DCMAKE_PREFIX_PATH=${PREFIX};${SYSROOT_PATH}" \
  "-DCMAKE_C_COMPILER=${CC}" \
  "-DCMAKE_CXX_COMPILER=${CXX}" \
  "-DZIG_SHARED_LLVM=OFF" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_TRIPLE=${ZIG_ARCH}-linux-gnu" \
  "-DZIG_TARGET_MCPU=baseline" \
  "-DZIG_SYSTEM_LIBCXX=stdc++" \
  "-DZIG_SINGLE_THREADED=ON" \
)

export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"
export CROSSCOMPILING_LIBC="-L${SYSROOT_PATH}/lib64;-lc"

export CFLAGS="${CFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"
export CXXFLAGS="${CXXFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="baseline"

USE_CMAKE_ARGS=0

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF

cmake_build_cmake_target "${cmake_build_dir}" zig2.c

sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${PREFIX}/bin@g" "${cmake_build_dir}/config.h"
pushd "${cmake_build_dir}"
  VERBOSE=1 cmake --build . -- -j"${CPU_COUNT}"
  cmake --install . > "${SRC_DIR}"/_install_post_zig2.log 2>&1
popd

patchelf --set-rpath "\$ORIGIN/../${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64" "${PREFIX}/bin/zig"
patchelf --add-rpath "\$ORIGIN/../lib" "${PREFIX}/bin/zig"
