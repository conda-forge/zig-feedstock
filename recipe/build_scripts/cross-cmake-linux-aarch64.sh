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
SYSROOT_PATH="${PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"

EXTRA_CMAKE_ARGS+=( \
  "-DCMAKE_PREFIX_PATH=${PREFIX};${SYSROOT_PATH}" \
  "-DCMAKE_C_COMPILER=${CC}" \
  "-DCMAKE_CXX_COMPILER=${CXX}" \
  "-DZIG_SHARED_LLVM=ON" \
  "-DZIG_USE_LLVM_CONFIG=ON" \
  "-DZIG_TARGET_DYNAMIC_LINKER=${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1" \
)
#  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu" \

source "${RECIPE_DIR}/build_scripts/_build_qemu_execve.sh"
build_qemu_execve "${SYSROOT_ARCH}"

# export CROSSCOMPILING_EMULATOR="${BUILD_PREFIX}/bin/qemu-${SYSROOT_ARCH}"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_LOG_FILENAME="${SRC_DIR}/_qemu_%d.log"
export QEMU_LOG="strace"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"
export QEMU_SET_ENV="LD_PRELOAD=${SYSROOT_PATH}/lib64/libdl.so.2:${SYSROOT_PATH}/lib64/libc.so.6:${SYSROOT_PATH}/lib64/libm.so.6"
export QEMU_STACK_SIZE="67108864"
export QEMU_EXECVE="${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1"

export CFLAGS="${CFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1"
export CXXFLAGS="${CXXFLAGS} -Wl,-rpath-link,${SYSROOT_PATH}/lib64 -Wl,-dynamic-linker,${SYSROOT_PATH}/lib64/ld-linux-aarch64.so.1"

export CROSSCOMPILING_LIBC="Wl,-dynamic-linker,${SYSROOT_PATH}//lib64/ld-linux-aarch64.so.1;-L${SYSROOT_PATH}/lib64;-lc"

export ZIG_CROSS_TARGET_TRIPLE="${SYSROOT_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="native"

# When using installed c++ libs, zig needs libzigcpp.a
USE_CMAKE_ARGS=1

# Patch ld.lld to use the correct interpreter
patchelf --set-interpreter "${SYSROOT_PATH}"/lib64/ld-linux-aarch64.so.1 "${PREFIX}/bin/ld.lld"
patchelf --set-rpath "\$ORIGIN/../lib" "${PREFIX}/bin/ld.lld"
patchelf --add-rpath "\$ORIGIN/../aarch64-conda-linux-gnu/sysroot/lib64" "${PREFIX}/bin/ld.lld"
patchelf --add-needed "libdl.so.2" "${PREFIX}/bin/ld.lld"
patchelf --add-needed "librt.so.1" "${PREFIX}/bin/ld.lld"
patchelf --add-needed "libm.so.6" "${PREFIX}/bin/ld.lld"

configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
cat <<EOF >> "${cmake_build_dir}/config.zig"
pub const mem_leak_frames = 0;
EOF

# remove_failing_langref "${cmake_build_dir}"
cmake_build_cmake_target "${cmake_build_dir}" zig-wasm2c
cmake_build_cmake_target "${cmake_build_dir}" zig1
cmake_build_cmake_target "${cmake_build_dir}" zig2

# patchelf --set-interpreter "${SYSROOT_PATH}"/lib64/ld-linux-aarch64.so.1 "${PREFIX}/bin/ld.lld"
cd "${cmake_build_dir}" || exit 1
  export QEMU_LOG_FILENAME="${SRC_DIR}/_qemu_%d.log"
  "${CROSSCOMPILING_EMULATOR}" "${SRC_DIR}"/build-release/zig2 build || true
  export QEMU_LOG_FILENAME="${SRC_DIR}/_qemu_execve_%d.log"

  # Patch zig2 to use the correct interpreter
  patchelf --set-interpreter "${SYSROOT_PATH}"/lib64/ld-linux-aarch64.so.1 "${SRC_DIR}"/build-release/zig2
  patchelf --set-rpath "${PREFIX}"/lib "${SRC_DIR}"/build-release/zig2
  patchelf --add-rpath "${SYSROOT_PATH}"/lib64 "${SRC_DIR}"/build-release/zig2
  patchelf --add-needed "libdl.so.2" "${SRC_DIR}"/build-release/zig2
  patchelf --add-needed "librt.so.1" "${SRC_DIR}"/build-release/zig2
  patchelf --add-needed "libm.so.6" "${SRC_DIR}"/build-release/zig2

  # Patch ld.lld to use the correct interpreter
  patchelf --set-interpreter "${SYSROOT_PATH}"/lib64/ld-linux-aarch64.so.1 "${PREFIX}/bin/ld.lld"
  patchelf --set-rpath "\$ORIGIN/../lib" "${PREFIX}/bin/ld.lld"
  patchelf --add-rpath "\$ORIGIN/../aarch64-conda-linux-gnu/sysroot/lib64" "${PREFIX}/bin/ld.lld"
  patchelf --add-needed "libdl.so.2" "${PREFIX}/bin/ld.lld"
  patchelf --add-needed "librt.so.1" "${PREFIX}/bin/ld.lld"
  patchelf --add-needed "libm.so.6" "${PREFIX}/bin/ld.lld"

  export QEMU_SET_ENV="PATH=${PREFIX}/bin:${PATH:-}"

  "${BUILD_PREFIX}"/bin/qemu-${SYSROOT_ARCH} "$SRC_DIR"/build-release/zig2 env
  "${BUILD_PREFIX}"/bin/qemu-${SYSROOT_ARCH} "$SRC_DIR"/build-release/zig2 libc
  "${BUILD_PREFIX}"/bin/qemu-${SYSROOT_ARCH} "$SRC_DIR"/build-release/zig2 help
  "${BUILD_PREFIX}"/bin/qemu-${SYSROOT_ARCH} "$SRC_DIR"/build-release/zig2 build
cd "${SRC_DIR}" || exit 1
cmake_build_install "${cmake_build_dir}"
