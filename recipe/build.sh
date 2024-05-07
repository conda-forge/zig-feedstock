#!/usr/bin/env bash

set -ex

function configure_linux_64() {
  TARGET="x86_64-linux-gnu"
  MCPU="baseline"

  cmake .. \
    ${CMAKE_ARGS} \
    -DCMAKE_PREFIX_PATH="${PREFIX};${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64;${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBC_CONDA_VERSION="${LIBC_CONDA_VERSION-2.28}" \
    -DLIBC_INTERPRETER="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
    -DLIBC_RPATH="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64:${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib:${PREFIX}/lib64:${PREFIX}/lib" \
    -DZIG_TARGET_TRIPLE="$TARGET" \
    -DZIG_TARGET_MCPU="$MCPU" \
    -DZIG_TARGET_DYNAMIC_LINKER="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
    -GNinja
}

function configure_macos_x86_64() {
  TARGET="$ARCH-macos-none"
  MCPU="baseline"

  cmake .. \
    ${CMAKE_ARGS} \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DZIG_TARGET_TRIPLE="$TARGET" \
    -DZIG_TARGET_MCPU="$MCPU" \
    -GNinja
}

ARCH="$(uname -m)"
TARGET="$ARCH-linux-gnu"
MCPU="baseline"

mkdir -p ${SRC_DIR}/build-release
cd build-release
  export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$PWD/zig-local-cache"

  case "$(uname)" in
    Linux)
      configure_linux_64
      ;;
    Darwin)
      configure_macos_x86_64
      ;;
  esac

  cmake --build .

  cmake --install .

  patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
cd ..
