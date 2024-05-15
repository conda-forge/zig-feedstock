#!/usr/bin/env bash

set -ex

function configure_linux_64() {
  local build_dir=$1
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    TARGET="x86_64-linux-gnu"
    MCPU="baseline"

    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_PREFIX_PATH="${PREFIX}/lib" \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_TARGET_TRIPLE="$TARGET" \
      -D ZIG_TARGET_MCPU="$MCPU" \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      -D ZIG_TARGET_DYNAMIC_LINKER="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
      -G Ninja
      # "${CMAKE_ARGS}" \
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

    patchelf --add-rpath "${PREFIX}/lib" "${installed_dir}/bin/zig"
  cd "${current_dir}"
}

function self_build_x86_64() {
  local build_dir=$1
  local installed_dir=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    cp -r "${SRC_DIR}"/zig-source/* .

    "${installed_dir}/bin/zig" build \
      --prefix "${install_dir}" \
      --search-prefix "${PREFIX}/lib" \
      --sysroot "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot" \
      -Dconfig_h="${SRC_DIR}/build-release/config.h" \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
    configure_linux_64 "${SRC_DIR}/build-release" "${PREFIX}"
    cmake_build_install "${SRC_DIR}/build-release"
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "${PREFIX}/bin/zig"
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/_self-built"
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${SRC_DIR}/_self-built" "${SRC_DIR}/_self-built1"
    ;;
  Darwin)
    echo "macOS is not supported yet."
    ;;
esac
