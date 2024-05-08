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

function bootstrap_macos_x86_64() {
  TARGET="x86_64-macos-none"
  MCPU="baseline"

  ZIG="${SRC_DIR}/zig-bootstrap/zig"

  $ZIG build \
      --prefix "$PREFIX" \
      --search-prefix "$PREFIX" \
      -Dflat \
      -Denable-llvm \
      -Doptimize=ReleaseFast \
      -Dstrip \
      -Dtarget="$TARGET" \
      -Dcpu="$MCPU" \
      -Dversion-string="$ZIG_VERSION"
}

case "$(uname)" in
  Linux)
    mkdir -p ${SRC_DIR}/build-release
    cd build-release
      export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-global-cache"
      export ZIG_LOCAL_CACHE_DIR="$PWD/zig-local-cache"
      configure_linux_64
      cmake --build .
      cmake --install .
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
    cd ..
    ;;
  Darwin)
    bootstrap_macos_x86_64
    ;;
esac
