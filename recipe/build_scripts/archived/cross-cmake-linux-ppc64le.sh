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
SYSROOT_ARCH="powerpc64le"
ZIG_ARCH="powerpc64"
QEMU_ARCH="ppc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"

# source "${RECIPE_DIR}/build_scripts/_build_qemu_execve.sh"
# build_qemu_execve "${QEMU_ARCH}"

# export CC=$(which clang)
# export CXX=$(which clang++)
#
# export CFLAGS="-target ${SYSROOT_ARCH}-linux-gnu -fno-plt"
# export CXXFLAGS="-target ${SYSROOT_ARCH}-linux-gnu -fno-plt --stdlib=libstdc++ -v -fverbose-asm"

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
# This path is too long for Target.zig
#  "-DZIG_TARGET_DYNAMIC_LINKER=${TARGET_INTERPRETER}" \

# export CROSSCOMPILING_EMULATOR="${BUILD_PREFIX}/bin/qemu-${SYSROOT_ARCH}"

# export CROSSCOMPILING_EMULATOR="${QEMU_EXECVE}"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"
export CROSSCOMPILING_LIBC="-L${SYSROOT_PATH}/lib64;-lc"

# CFLAGS="${CFLAGS} -mlongcall -mcmodel=large -Os -Wl,--no-relax -fPIE -pie"
# CXXFLAGS="${CXXFLAGS} -mlongcall -mcmodel=large -Os -Wl,--no-relax -fPIE -pie"
# CFLAGS=${CFLAGS//-fno-plt/}
# CXXFLAGS=${CXXFLAGS//-fno-plt/}

export CFLAGS="${CFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"
export CXXFLAGS="${CXXFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${TARGET_INTERPRETER}"

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="ppc64le"

USE_CMAKE_ARGS=0

# CFLAGS=${CFLAGS//-fPIC/}
# CXXFLAGS=${CXXFLAGS//-fPIC/}
# CFLAGS=${CFLAGS//-fpie/}
# CXXFLAGS=${CXXFLAGS//-fpie/}
# CFLAGS=${CFLAGS//-fno-plt/}
# CXXFLAGS=${CXXFLAGS//-fno-plt/}
# export CFLAGS="${CFLAGS}"
# export CXXFLAGS="${CXXFLAGS} -fno-optimize-sibling-calls -fno-threadsafe-statics"
# echo "CFLAGS=${CFLAGS}"
# echo "CXXFLAGS=${CXXFLAGS}"
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF

cmake_build_cmake_target "${cmake_build_dir}" zig2.c
# pushd "${cmake_build_dir}"
#   patch -Np0 -i "${SRC_DIR}"/_conda-build-level-patches/xxxx-zig2.c-asm-clobber-list.patch --binary
# popd

# cmake_build_cmake_target "${cmake_build_dir}" zig2
# patchelf_sysroot_interpreter "${SYSROOT_PATH}" "${TARGET_INTERPRETER}" "${cmake_build_dir}/zig2" 1
# cmake_build_cmake_target "${cmake_build_dir}" stage3

sed -i -E "s@#define ZIG_CXX_COMPILER \".*/bin@#define ZIG_CXX_COMPILER \"${PREFIX}/bin@g" "${cmake_build_dir}/config.h"
pushd "${cmake_build_dir}"
  VERBOSE=1 cmake --build . -- -j"${CPU_COUNT}" > "${SRC_DIR}"/_make_post_zig2.log 2>&1
  cmake --install . > "${SRC_DIR}"/_install_post_zig2.log 2>&1
popd

# patchelf --set-interpreter "${PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64/ld-linux-${SYSROOT_ARCH}.so.1" "${PREFIX}/bin/zig"
patchelf --set-rpath "\$ORIGIN/../${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64" "${PREFIX}/bin/zig"
patchelf --add-rpath "\$ORIGIN/../lib" "${PREFIX}/bin/zig"

# Use stage3/zig to self-build: This failed locally with SEGV in qemu
# build_zig_with_zig "${zig_build_dir}" "${PREFIX}/bin/zig" "${PREFIX}"
