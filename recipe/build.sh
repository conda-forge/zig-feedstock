#!/usr/bin/env bash

set -ex
ZIG=${SRC_DIR}\zig-bootstrap\zig

function configure_osx_64() {
  local build_dir=$1
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    TARGET="x86_64-macos-none"
    MCPU="baseline"

    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_BUILD_TYPE=Release \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_PREFIX_PATH="${BUILD_PREFIX}" \
      -D CMAKE_CXX_IMPLICIT_LINK_LIBRARIES="c++" \
      -D CMAKE_C_COMPILER="$ZIG;cc" \
      -D CMAKE_CXX_COMPILER="$ZIG;c++" \
      -D LLVM_ENABLE_LIBCXX=ON \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      -G Ninja
      # ${CMAKE_ARGS} \
      # -D ZIG_TARGET_TRIPLE="${TARGET}" \
      # -D ZIG_TARGET_MCPU="${MCPU}" \
      # -DCMAKE_SYSTEM_NAME="Darwin" \

    #sed -i '' 's@\$PREFIX@\$BUILD_PREFIX@g' config.h
    sed -i '' 's@;-lm@;\$PREFIX/lib/libc++.dylib;-lm@' config.h
    cat config.h
  cd "${current_dir}"
}

function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}"
    _prefix="${PREFIX}"
    export PREFIX="${BUILD_PREFIX}"
    cmake --build . -- -j"${CPU_COUNT}"
    export PREFIX="${_prefix}"
    cmake --install .
  cd "${current_dir}"
}

function self_build_osx_64() {
  local build_dir=$1
  local installed_dir=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  mkdir -p "${build_dir}"
  mkdir -p "${install_dir}"
  cd "${build_dir}"
    cp -r "${SRC_DIR}"/zig-source/* .
    # "${installed_dir}/bin/zig" build test
    ${installed_dir}/bin/zig version

    "${installed_dir}/bin/zig" build \
      --prefix "${install_dir}" \
      --verbose-link \
      -Dconfig_h="${SRC_DIR}/build-release/config.h" \
      -Denable-llvm \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
    echo "Linux not supported yet"
    ;;
  Darwin)
    ZIG="${SRC_DIR}/zig-bootstrap/zig"
    # Not working due to headerpad: bootstrap_osx_64
    configure_osx_64 "${SRC_DIR}/build-release" "${PREFIX}"
    cmake_build_install "${SRC_DIR}/build-release"
    export DYLD_LIBRARY_PATH="${PREFIX}/lib"
    self_build_osx_64 "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/_self-built"
    ;;
esac
