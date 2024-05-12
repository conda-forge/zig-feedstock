#!/usr/bin/env bash

set -ex

function configure_linux_64() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    TARGET="x86_64-linux-gnu"
    MCPU="baseline"

    cmake ${SRC_DIR}/zig-source \
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
  cd "${current_dir}"
}

function configure_osx_64() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    TARGET="x86_64-macos-none"
    MCPU="baseline"

    cmake ${SRC_DIR}/zig-source \
      -DCMAKE_PREFIX_PATH="${PREFIX}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DZIG_TARGET_TRIPLE="${TARGET}" \
      -DZIG_TARGET_MCPU="${MCPU}" \
      -GNinja
      # ${CMAKE_ARGS} \
      # -DCMAKE_SYSTEM_NAME="Darwin" \
      # -DCMAKE_C_COMPILER="$ZIG;cc;-target;$TARGET;-mcpu=$MCPU" \
      # -DCMAKE_CXX_COMPILER="$ZIG;c++;-target;$TARGET;-mcpu=$MCPU" \
  cd "${current_dir}"
}

function bootstrap_osx_64() {
  local current_dir
  current_dir=$(pwd)

  TARGET="x86_64-macos-none"
  MCPU="baseline"

  mkdir build
  cd build
    cmake ${SRC_DIR}/zig-source \
      ${CMAKE_ARGS} \
      -DCMAKE_PREFIX_PATH="${PREFIX}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME="Darwin" \
      -DCMAKE_STATIC_LINKER_FLAGS="-headerpad_max_install_names" \
      -DCMAKE_SHARED_LINKER_FLAGS="-headerpad_max_install_names" \
      -DZIG_TARGET_TRIPLE="${TARGET}" \
      -DZIG_TARGET_MCPU="${MCPU}" \
      -DZIG_NO_LIB=ON \
      -GNinja
  cd "${current_dir}"

  #grep -q '^#define ZIG_LLVM_LIBRARIES' build/config.h
  #sed -i '' 's/^#define ZIG_LLVM_LIBRARIES "\(.*\)"$/#define ZIG_LLVM_LIBRARIES "\1;-lxml2;-headerpad;-headerpad_max_install_names"/' build/config.h
  #grep -q '^#define ZIG_LLVM_LIBRARIES' build/config.h

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  $ZIG build \
      --prefix "${PREFIX}" \
      -Dconfig_h="build/config.h" \
      -Denable-macos-sdk \
      -Denable-llvm \
      -Doptimize=ReleaseFast \
      -Dstrip \
      -Dversion-string="${PKG_VERSION}"
}

function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}"
    cmake --build .
    cmake --install .
  cd "${current_dir}"
}

function self_build() {
  local build_dir=$1
  local installed_dir=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    cp -r "${SRC_DIR}"/zig-source/* .
    "${installed_dir}/bin/zig" build \
      --prefix "${install_dir}" \
      --search-prefix "${install_dir};${install_dir}/lib;${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64;${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
      --sysroot "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot" \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
    configure_linux_64 "${SRC_DIR}/build-release"
    cmake_build_install "${SRC_DIR}/build-release"
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
    self_build "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/build-release"
    ;;
  Darwin)
    ZIG="${SRC_DIR}/zig-bootstrap/zig"
    # Not working due to headerpad: bootstrap_osx_64
    configure_osx_64 "${SRC_DIR}/build-release"
    cmake_build_install "${SRC_DIR}/build-release"
    ;;
esac
