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
  TARGET="x86_64-macos-none"
  MCPU="baseline"

  cmake .. \
    ${CMAKE_ARGS} \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${ZIG};cc;-target;${TARGET};-mcpu=${MCPU}" \
    -DCMAKE_CXX_COMPILER="${ZIG};c++;-target;${TARGET};-mcpu=${MCPU}" \
    -DZIG_TARGET_TRIPLE="${TARGET}" \
    -DZIG_TARGET_MCPU="${MCPU}" \
    -DZIG_NO_LIB=ON \
    -GNinja
}

function bootstrap_macos_x86_64() {
  TARGET="x86_64-macos-none"
  MCPU="baseline"

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export NO_PROXY=localhost,
  export http_proxy=http://localhost

  $ZIG build \
      --prefix "${PREFIX}" \
      -Dstatic-llvm \
      -Dno-lib \
      -Doptimize=ReleaseFast \
      -Dstrip \
      -Dtarget="${TARGET}" \
      -Dcpu="${MCPU}" \
      -Dversion-string="${ZIG_VERSION}"
}

case "$(uname)" in
  Linux)
    mkdir -p ${SRC_DIR}/build-release
    cd build-release
      export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
      export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
      configure_linux_64
      cmake --build .
      cmake --install .
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
    cd ..
    ;;
  Darwin)
    ZIG="${SRC_DIR}/zig-bootstrap/zig"
    bootstrap_macos_x86_64
    ;;
esac
