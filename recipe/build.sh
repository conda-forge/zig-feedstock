#!/usr/bin/env bash

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
      -D CMAKE_BUILD_TYPE=Debug \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_PREFIX_PATH="${PREFIX}" \
      -D CMAKE_C_COMPILER="$ZIG;cc" \
      -D CMAKE_CXX_COMPILER="$ZIG;c++" \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      -G Ninja
      # ${CMAKE_ARGS} \
      # -D CMAKE_CXX_IMPLICIT_LINK_LIBRARIES="c++" \
      # -D ZIG_TARGET_TRIPLE="${TARGET}" \
      # -D ZIG_TARGET_MCPU="${MCPU}" \
      # -DCMAKE_SYSTEM_NAME="Darwin" \

    #sed -i '' 's@\$PREFIX@\$BUILD_PREFIX@g' config.h
    sed -i '' "s@;-lm@;$PREFIX/lib/libc++.so;-lm@" config.h
    cat config.h
  cd "${current_dir}"
}

function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}"
    cmake --build . -- -j"${CPU_COUNT}"
    cmake --install .
  cd "${current_dir}"
}

function self_build_osx_64() {
  local build_dir=$1
  local zig=$2
  local config_h=$3
  local install_dir=$4

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  mkdir -p "${build_dir}"
  mkdir -p "${install_dir}"
  cd "${build_dir}"
    cp -r "${SRC_DIR}"/zig-source/* .
    # "${zig}" build test
    "${zig}" version

    "${zig}" build \
      --prefix "${install_dir}" \
      --search-prefix "${PREFIX}/lib" \
      -Dconfig_h="${config_h}" \
      -Denable-llvm \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

# --- Main ---

set -ex
export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

MCPU="baseline"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
self_build_dir="${SRC_DIR}/self-built-source"

case "$(uname)" in
  Linux)
    echo "Linux not supported yet"
    ;;
  Darwin)
    ZIG="${SRC_DIR}/zig-bootstrap/zig"
    # Not working due to headerpad: bootstrap_osx_64
    configure_osx_64 "${cmake_build_dir}" "${cmake_install_dir}"
    cd "${cmake_build_dir}" && cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
    # cmake_build_install "${SRC_DIR}/build-release"
    export DYLD_LIBRARY_PATH="${PREFIX}/lib"
    self_build_osx_64 \
      "${self_build_dir}" \
      "${SRC_DIR}/zig-bootstrap/zig" \
      "${cmake_build_dir}/config.h" \
      "${PREFIX}"
    ;;
esac
