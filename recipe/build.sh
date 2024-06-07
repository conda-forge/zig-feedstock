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
      -D CMAKE_PREFIX_PATH="${BUILD_PREFIX}/lib" \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_TARGET_TRIPLE="$TARGET" \
      -D ZIG_TARGET_MCPU="$MCPU" \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      -G Ninja
    cat config.h
  cd "${current_dir}"
}

function patchelf_installed_zig() {
  local install_dir=$1

  patchelf --remove-rpath                                                              "${install_dir}/bin/zig"
  patchelf --set-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64"     "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib"               "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/lib"                                      "${install_dir}/bin/zig"

  readelf -d "${install_dir}/bin/zig"
  ldd "${install_dir}/bin/zig"
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

function test_build() {
  local installed_dir=$1

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  cd "${SRC_DIR}"/zig-source && "${installed_dir}"/bin/zig build test && cd "${current_dir}"
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

    cat > _libc_file <<EOF
include_dir=${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/include
sys_include_dir=${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/include
crt_dir=${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

    rm \
      doc/langref/test_comptime_unwrap_null.zig \
      doc/langref/test_variadic_function.zig \
      doc/langref/cImport_builtin.zig \
      doc/langref/verbose_cimport_flag.zig

    "${installed_dir}/bin/zig" build \
      --prefix "${install_dir}" \
      --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64" \
      --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib" \
      --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
      --search-prefix "${BUILD_PREFIX}/lib" \
      --libc _libc_file \
      --sysroot "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot" \
      -Dconfig_h="${SRC_DIR}/build-release/config.h" \
      -Denable-llvm \
      -Ddynamic-linker="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
      -Dversion-string="${PKG_VERSION}"

    patchelf_installed_zig "${install_dir}"
  cd "${current_dir}"
}

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"
case "$(uname)" in
  Linux)
    install_dir="${PREFIX}"

    configure_linux_64 "${SRC_DIR}/build-release" "${install_dir}"
    cmake_build_install "${SRC_DIR}/build-release"
    patchelf_installed_zig "${install_dir}"
    # test_build "${install_dir}"

    # Self-built zig generates MemoryError std::badAlloc
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/self-built-install"
    ;;
  Darwin)
    echo "macOS is not supported yet."
    ;;
esac
