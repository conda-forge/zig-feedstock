#!/usr/bin/env bash

set -ex

function configure_linux_64() {
  local build_dir=$1

  mkdir -p "${build_dir}"
  cd "${build_dir}"
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
  cd ..
}

function configure_osx_64() {
  local build_dir=$1

  mkdir -p "${build_dir}"
  cd "${build_dir}"
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
      -GNinja
  cd ..
}

function bootstrap_osx_64() {
  TARGET="x86_64-macos-none"
  MCPU="baseline"

  mkdir build
  cd build
    cmake .. \
      ${CMAKE_ARGS} \
      -DCMAKE_PREFIX_PATH="${PREFIX}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME="Darwin" \
      -DZIG_TARGET_TRIPLE="${TARGET}" \
      -DZIG_TARGET_MCPU="${MCPU}" \
      -DZIG_NO_LIB=ON \
      -GNinja
  cd ..

  grep -q '^#define ZIG_LLVM_LIBRARIES' build/config.h
  sed -i '' 's/^#define ZIG_LLVM_LIBRARIES "\(.*\)"$/#define ZIG_LLVM_LIBRARIES "\1;-lxml2;-headerpad;-headerpad_max_install_names"/' build/config.h
  grep -q '^#define ZIG_LLVM_LIBRARIES' build/config.h

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  $ZIG build \
      --prefix "${PREFIX}" \
      -Dconfig_h="build/config.h" \
      -Denable-macos-sdk \
      -Doptimize=ReleaseFast \
      -Dstrip \
      -Dversion-string="${PKG_VERSION}"
#       -Denable-llvm \
}

function cmake_build_install() {
  local build_dir=$1
  cd "${build_dir}"
    cmake --build .
    cmake --install .
  cd ..
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
      configure_linux_64 "${SRC_DIR}/build-release"
      cmake_build_install "${SRC_DIR}/build-release"
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
    ;;
  Darwin)
    ZIG="${SRC_DIR}/zig-bootstrap/zig"
    bootstrap_osx_64
    ;;
esac
