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
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_TARGET_TRIPLE="$TARGET" \
      -D ZIG_TARGET_MCPU="$MCPU" \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      -D ZIG_TARGET_DYNAMIC_LINKER="${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64/ld-${LIBC_CONDA_VERSION-2.28}.so" \
      -G Ninja
      # "${CMAKE_ARGS}" \
      # -D CMAKE_PREFIX_PATH="${PREFIX}/lib" \
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

#  patchelf --remove-needed  libc.so.6                                                  "${install_dir}/bin/zig"
#  patchelf --remove-needed  libm.so.6                                                  "${install_dir}/bin/zig"
#  patchelf --remove-needed  libdl-2.28.so                                              "${install_dir}/bin/zig"
#  patchelf --remove-needed  librt-2.28.so                                              "${install_dir}/bin/zig"
#  patchelf --remove-needed  libpthread-2.28.so                                         "${install_dir}/bin/zig"
#  patchelf --remove-needed  libzstd.so.1                                               "${install_dir}/bin/zig"
#  patchelf --remove-needed  libstdc++.so.6                                             "${install_dir}/bin/zig"
#  patchelf --remove-needed  libz.so.1                                                  "${install_dir}/bin/zig"
#  patchelf --remove-needed  libgcc_s.so.1                                              "${install_dir}/bin/zig"
#
#  patchelf \
#    --add-needed libc-2.28.so \
#    --add-needed libm-2.28.so \
#    --add-needed libdl-2.28.so \
#    --add-needed librt-2.28.so \
#    --add-needed libpthread-2.28.so \
#    --add-needed libzstd.so.1 \
#    --add-needed libstdc++.so.6 \
#    --add-needed libz.so.1 \
#    --add-needed libgcc_s.so.1 \
#    "${install_dir}/bin/zig"

  readelf -d "${install_dir}/bin/zig"
  ldd "${install_dir}/bin/zig"
}

function cmake_build_install() {
  local build_dir=$1
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}"
    _prefix="${PREFIX}"
    export PREFIX="${BUILD_PREFIX}"
    cmake --build . -- -j"${CPU_COUNT}"
    export PREFIX="${_prefix}"
    cmake --install .

    patchelf_installed_zig "${install_dir}"
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
    configure_linux_64 "${SRC_DIR}/build-release" "${SRC_DIR}/_bootstrapped"
    cmake_build_install "${SRC_DIR}/build-release" "${PREFIX}"
    # test_build "${PREFIX}"

    rm -rf ${ZIG_GLOBAL_CACHE_DIR} ${ZIG_LOCAL_CACHE_DIR}
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${PREFIX}" "${SRC_DIR}/_self-built"
    self_build_x86_64 "${SRC_DIR}/self-built-source" "${SRC_DIR}/_self-built" "${SRC_DIR}/_self-built1"
    ;;
  Darwin)
    echo "macOS is not supported yet."
    ;;
esac
