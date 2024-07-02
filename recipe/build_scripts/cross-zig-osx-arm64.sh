#!/usr/bin/env bash

# --- Functions ---

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${EXTRA_CMAKE_ARGS[@]}" \
      -G Ninja

    sed -i '' "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"

    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  cd "${current_dir}"
}

function create_libc_file() {
  local sysroot=$1

  cat <<EOF > _libc_file
include_dir=${sysroot}/usr/include
sys_include_dir=${sysroot}/usr/include
crt_dir=${sysroot}/usr/lib64
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
}

function self_build() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}"
      "${zig}" build \
        --prefix "${install_dir}" \
        -Doptimize=ReleaseSafe \
        "${EXTRA_ZIG_ARGS[@]}" \
        -Dversion-string="${PKG_VERSION}"
    cd "${current_dir}"
  else
    echo "No build directory found"
    exit 1
  fi
}

# --- Main ---

set -euxo pipefail

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${cmake_install_dir}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
SYSROOT_ARCH="aarch64"
export DYLD_LIBRARY_PATH="${PREFIX}/lib"

EXTRA_CMAKE_ARGS+=("-DZIG_SYSTEM_LIBCXX=c++")
EXTRA_CMAKE_ARGS+=("-DZIG_USE_LLVM_CONFIG=OFF")
EXTRA_CMAKE_ARGS+=("-DZIG_SHARED_LLVM=ON")
EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-macos-none")

EXTRA_ZIG_ARGS+=("-Dcpu=baseline")
EXTRA_ZIG_ARGS+=("--sysroot" "${SDKROOT}")
EXTRA_ZIG_ARGS+=("-Dtarget=aarch64-macos-none")
EXTRA_ZIG_ARGS+=("-fqemu")

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
create_libc_file "${SDKROOT}"

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=( \
  "-Dconfig_h=${cmake_build_dir}/config.h" \
  "-Denable-llvm" \
  "-Dstrip" \
  "-Duse-zig-libcxx=false" \
  "--libc" "${SRC_DIR}/_libc_file" \
  )

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
remove_failing_langref "${SRC_DIR}/conda-zig-source"
self_build "${SRC_DIR}/conda-zig-source" "${SRC_DIR}/zig-bootstrap/zig" "${PREFIX}"
