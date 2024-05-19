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
      -D ZIG_STATIC_LIB=ON \
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
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}"
    cmake --build . -- -j"${CPU_COUNT}"
    cmake --install .

    patchelf \
      --remove-rpath \
      "${install_dir}/bin/zig"
    patchelf \
      --add-rpath "${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib" \
      --add-rpath "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64" \
      --add-rpath "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
      --add-rpath "${BUILD_PREFIX}/lib" \
      "${install_dir}/bin/zig"
    patchelf \
      --add-needed libc-2.28.so \
      --add-needed libm-2.28.so \
      --add-needed libdl-2.28.so \
      --add-needed librt-2.28.so \
      --add-needed libpthread-2.28.so \
      --add-needed libclang-cpp.so.17 \
      --add-needed libzstd.so.1 \
      --add-needed libstdc++.so.6 \
      --add-needed libz.so.1 \
      --add-needed libgcc_s.so.1 \
      "${install_dir}/bin/zig"
  cd "${current_dir}"
}

function test_build() {
  local installed_dir=$1

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  cd "${SRC_DIR}"/zig-source
    "${installed_dir}"/bin/zig build test
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

    LD_LIBRARY_PATH="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64" "${installed_dir}/bin/zig" build \
      --prefix "${install_dir}" \
      --search-prefix "${BUILD_PREFIX}/lib" \
      --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib" \
      --sysroot "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot" \
      -Dconfig_h="${SRC_DIR}/build-release/config.h" \
      -Ddynamic-linker="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
    configure_linux_64 "${SRC_DIR}/build-release" "${PREFIX}"
    cmake_build_install "${SRC_DIR}/build-release" "${PREFIX}"
    # test_build "${PREFIX}"

    self_build_x86_64 "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/_self-built"
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${SRC_DIR}/_self-built" "${SRC_DIR}/_self-built1"
    ;;
  Darwin)
    echo "macOS is not supported yet."
    ;;
esac
