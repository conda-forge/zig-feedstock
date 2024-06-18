#!/usr/bin/env bash

# --- Functions ---

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  echo "Configuring cmake build"
  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    if [[ "${zig:-}" != '' ]]; then
      _c="${zig};cc"
      _cxx="${zig};c++"
      if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
        _c="${_c};-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline};-fqemu"
        _cxx="${_cxx};-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline};-fqemu"
      fi
      echo "C: ${_c}"
      echo "C: ${_cxx}"
      $zig cc --version
      $zig c++ --version
      EXTRA_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=${_c}")
      EXTRA_CMAKE_ARGS+=("-DCMAKE_CXX_COMPILER=${_cxx}")
      EXTRA_CMAKE_ARGS+=("-DCMAKE_AR=${zig}")
      EXTRA_CMAKE_ARGS+=("-DZIG_AR_WORKAROUND=ON")
    #else
    #  _toolchain="-DCMAKE_C_COMPILER=$CC_FOR_BUILD;-DCMAKE_CXX_COMPILER=$CXX_FOR_BUILD;-DCMAKE_EXE_LINKER_FLAGS=\"-L$BUILD_PREFIX/lib\";-DCMAKE_MODULE_LINKER_FLAGS=;-DCMAKE_SHARED_LINKER_FLAGS=;-DCMAKE_STATIC_LINKER_FLAGS=;-DCMAKE_AR=$(which ${AR});-DCMAKE_RANLIB=$(which ${RANLIB});-DCMAKE_PREFIX_PATH=${BUILD_PREFIX}"
    #  EXTRA_CMAKE_ARGS+=("-DCROSS_TOOLCHAIN_FLAGS_NATIVE=${_toolchain}")
    fi

    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_USE_LLVM_CONFIG=ON \
      "${EXTRA_CMAKE_ARGS[@]}" \
      -G Ninja
  cd "${current_dir}"
  echo "Done"
}

function patchelf_installed_zig() {
  local install_dir=$1
  local build_prefix=$2

  patchelf --remove-rpath                                                               "${install_dir}/bin/zig"
  patchelf --set-rpath      "${build_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64"     "${install_dir}/bin/zig"
  patchelf --add-rpath      "${build_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/lib"               "${install_dir}/bin/zig"
  patchelf --add-rpath      "${build_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64" "${install_dir}/bin/zig"
  patchelf --add-rpath      "${build_prefix}/lib"                                       "${install_dir}/bin/zig"
  patchelf --add-rpath      "${PREFIX}/lib"                                             "${install_dir}/bin/zig"

  patchelf --set-interpreter "${build_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64/ld-2.28.so" "${install_dir}/bin/zig"
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

function self_build() {
  local build_dir=$1
  local zig=$2
  local config_h=$3
  local install_dir=$4

  echo "Building zig from source"

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    cp -r "${SRC_DIR}"/zig-source/* .

    # These langerf code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
    # No idea why this comes up, there is no -lmvec_nonshared.a on the link command
    # there seems to be no way to redirect to sysroot/usr/lib64/libmvec_nonshared.a
    rm \
      doc/langref/test_comptime_unwrap_null.zig \
      doc/langref/test_variadic_function.zig \
      doc/langref/cImport_builtin.zig \
      doc/langref/verbose_cimport_flag.zig

    echo "Building zig from source"
    echo "ZIG: ${zig}"
    echo "     ${config_h}"
    ls -l "${zig}"
    uname -a
    objdump -h "${zig}"
    nm "${zig}"
    readelf -s "${zig}"
    $zig build.exe -mcpu=ppc64le
    $zig build -Dcpu=ppc64
    $zig build -Dcpu=ppc64

    mkdir -p "${install_dir}"
    "${zig}" build \
      --prefix "${install_dir}" \
      --search-prefix "${PREFIX}" \
      -Doptimize=ReleaseSafe \
      -Dconfig_h="${config_h}" \
      "${EXTRA_ZIG_ARGS[@]}" \
      -Dversion-string="${PKG_VERSION}"
  cd "${current_dir}"
}

# --- Main ---

set -euxo pipefail

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
self_build_dir="${SRC_DIR}/self-built-source"

EXTRA_CMAKE_ARGS=("-DZIG_SHARED_LLVM=ON")
EXTRA_ZIG_ARGS=("-Denable-llvm" "-Dstrip")

if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  SYSROOT_ARCH="powerpc64le"
  TARGET="${SYSROOT_ARCH}-linux"
  MCPU=ppc64
  EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_TRIPLE=${TARGET}")
  EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_MCPU=${MCPU}")
  configure_cmake "${cmake_build_dir}" "${cmake_install_dir}"
  echo "------------------"
  cmake_build_install "${cmake_build_dir}"
fi
#
# if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
#   cmake_build_install "${cmake_build_dir}"
#
#   if [[ "${target_platform}" == "linux-64" ]]; then
#     patchelf_installed_zig "${cmake_install_dir}" "${BUILD_PREFIX}"
#   elif [[ "${target_platform}" == "osx-64" ]]; then
#     otool -l "${cmake_install_dir}"/bin/zig
#   fi
#
#   zig="${cmake_install_dir}/bin/zig"
# else
#   EXTRA_ZIG_ARGS+=("-fqemu")
#   if [[ "${target_platform}" == "linux-ppc64le" ]] ; then
#     # echo "$CMAKE_ARGS"
#     # export CFLAGS="${CFLAGS} -fPIC"
#     # export CXXFLAGS="${CXXFLAGS} -fPIC"
#     # EXTRA_CMAKE_ARGS+=("${CMAKE_ARGS[@]}")
#     # cd "${cmake_build_dir}" && cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
#     zig="${SRC_DIR}/zig-bootstrap/zig"
#     #zig="${cmake_install_dir}"/zig
#     # cmake_build_install "${cmake_build_dir}"
#     #zig="${cmake_install_dir}/bin/zig"
#   else
#     cd "${cmake_build_dir}" && cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
#     zig="${SRC_DIR}/zig-bootstrap/zig"
#   fi
# fi

self_build \
  "${self_build_dir}" \
  "${SRC_DIR}/zig-bootstrap/zig" \
  "${cmake_build_dir}/config.h" \
  "${PREFIX}"
