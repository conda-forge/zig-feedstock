#!/usr/bin/env bash

# --- Functions ---

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_SHARED_LLVM=ON \
      -D ZIG_USE_LLVM_CONFIG=ON \
      "${EXTRA_CMAKE_ARGS[@]}" \
      -G Ninja
  cd "${current_dir}"
}

function patchelf_installed_zig() {
  local install_dir=$1

  patchelf --remove-rpath                                                              "${install_dir}/bin/zig"
  patchelf --set-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64"     "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/lib"               "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" "${install_dir}/bin/zig"
  patchelf --add-rpath      "${BUILD_PREFIX}/lib"                                      "${install_dir}/bin/zig"
  patchelf --add-rpath      "${PREFIX}/lib"                                            "${install_dir}/bin/zig"
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
  local target=${5:-$TARGET}

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

    "${zig}" build \
      --prefix "${install_dir}" \
      --sysroot "${BUILD_PREFIX}/${ARCH}-conda-linux-gnu/sysroot" \
      -Doptimize=ReleaseSafe \
      -Dconfig_h="${config_h}" \
      -Denable-llvm \
      -Dstrip \
      "${EXTRA_ZIG_ARGS[@]}" \
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

EXTRA_CMAKE_ARGS=()
EXTRA_ZIG_ARGS=()
if [[ "${target_platform}" == "linux-64" ]]; then
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_TRIPLE='x86_64-linux-gnu'")
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_MCPU='baseline'")

elif [[ "${target_platform}" == "linux-aarch64" ]]; then
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_TRIPLE='aarch64-linux-gnu'")
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_MCPU='baseline'")
  EXTRA_ZIG_ARGS+=("-Dtarget='aarch64-linux-gnu'")

elif [[ "${target_platform}" == "linux-ppc64le" ]]; then
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_TRIPLE='powerpc64le-linux-gnu'")
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_MCPU='baseline'")
  EXTRA_ZIG_ARGS+=("-Dpie=false")
  EXTRA_ZIG_ARGS+=("-Dtarget='powerpc64le-linux-gnu'")

elif [[ "${target_platform}" == "osx-64" ]]; then
  # EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_TRIPLE='x86_64-macos-none'")
  # EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_MCPU='baseline'")
  export DYLD_LIBRARY_PATH="${PREFIX}/lib"

elif [[ "${target_platform}" == "osx-arm64" ]]; then
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_TRIPLE='arm64-linux-gnu'")
  EXTRA_CMAKE_ARGS+=("-D ZIG_TARGET_MCPU='baseline'")
  EXTRA_ZIG_ARGS+=("-Dtarget='arm64-linux-gnu'")
fi

configure_cmake "${cmake_build_dir}" "${cmake_install_dir}"
if [[ "${target_platform}" == "osx-64" ]]; then
  sed -i '' "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}/config.h"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
  cmake_build_install "${cmake_build_dir}"

  if [[ "${target_platform}" == "linux-64" ]]; then
    patchelf_installed_zig "${cmake_install_dir}"
  elif [[ "${target_platform}" == "osx-64" ]]; then
    install_name_tool -add_rpath "${PREFIX}/lib" "${cmake_install_dir}/bin/zig"
  fi

  zig="${cmake_install_dir}/bin/zig"
else
  cd "${cmake_build_dir}" && cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  zig="${SRC_DIR}/zig-bootstrap/zig"
  EXTRA_ZIG_ARGS+=("-fqemu")
fi

self_build \
  "${self_build_dir}" \
  "${zig}" \
  "${cmake_build_dir}/config.h" \
  "${PREFIX}"
