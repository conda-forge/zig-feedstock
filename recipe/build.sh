#!/usr/bin/env bash

# --- Functions ---

function remove_failing_langref() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}"/doc/langref ]]; then
    # These langerf code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
    # No idea why this comes up, there is no -lmvec_nonshared.a on the link command
    # there seems to be no way to redirect to sysroot/usr/lib64/libmvec_nonshared.a
    grep -v -f "${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt "${build_dir}"/doc/langref.html.in > "${build_dir}"/doc/_langref.html.in
    mv "${build_dir}"/doc/_langref.html.in "${build_dir}"/doc/langref.html.in
    while IFS= read -r file
    do
      rm -f "${build_dir}"/doc/langref/"$file"
    done < "${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt
  else
    echo "No langref directory found"
    exit 1
  fi
  cd "${current_dir}"
}

function configure_platform() {
  local zig_os="linux"
  local zig_cpu="-Dcpu=baseline"
  local zig_cxx="-DZIG_SYSTEM_LIBCXX=stdc++"
  local llvm_config="-DZIG_USE_LLVM_CONFIG=ON"

  case "${target_platform}" in
    # Native platforms
    linux-64)
      SYSROOT_ARCH="x86_64"
      ;;

    osx-64)
      SYSROOT_ARCH="x86_64"
      zig_os="macos"
      zig_cxx="-DZIG_SYSTEM_LIBCXX=c++"
      export DYLD_LIBRARY_PATH="${PREFIX}/lib"
      ;;

    # Cross-compiled platforms
    linux-aarch64)
      SYSROOT_ARCH="aarch64"
      zig_target="-Dtarget=${SYSROOT_ARCH}-${zig_os}-gnu"
      ;;

    linux-ppc64le)
      SYSROOT_ARCH="powerpc64le"
      zig_cpu="-Dcpu=ppc64le"
      zig_target="-Dtarget${SYSROOT_ARCH}-${zig_os}-gnu"
      ;;

    osx-arm64)
      SYSROOT_ARCH="aarch64"
      zig_os="macos"
      zig_cxx="-DZIG_SYSTEM_LIBCXX=c++"
      zig_target="-Dtarget=aarch64-macos.11-gnu"
      llvm_config="-DZIG_USE_LLVM_CONFIG=OFF"
      zig_sysroot=("--sysroot" "${SDKROOT}")
      export DYLD_LIBRARY_PATH="${PREFIX}/lib"
      ;;
  esac
  EXTRA_CMAKE_ARGS+=("${zig_cxx}")
  EXTRA_CMAKE_ARGS+=("${llvm_config}")
  EXTRA_CMAKE_ARGS+=("-DZIG_SHARED_LLVM=ON")
  EXTRA_CMAKE_ARGS+=("-DZIG_STATIC=OFF")

  EXTRA_ZIG_ARGS+=("${zig_cpu}")
  EXTRA_ZIG_ARGS+=("${zig_sysroot:-}")
  EXTRA_ZIG_ARGS+=("${zig_target:-}")

  if [[ "${build_platform}" != "osx-64" ]]; then
    EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu")
    # Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
    modify_libc_libm_for_zig "${BUILD_PREFIX}"
  fi
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    EXTRA_CMAKE_ARGS+=("-DLLVM_CONFIG_EXE=${PREFIX}/bin/llvm-config")
    EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_DYNAMIC_LINKER=${BUILD_PREFIX}/bin/${LD}")
    EXTRA_ZIG_ARGS+=("-fqemu")
  fi
}

function modify_libc_libm_for_zig() {
  local prefix=$1

  # Linux libm.so/libc.so has fullpath references (i.e. /usr/lib64/libmvec_shared.a) that do not exist on most environments
  sed -i -E 's@(/usr/lib(64)?/|/lib(64)?/)@@g' "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libm.so"
  sed -i -E 's@(/usr/lib(64)?/|/lib(64)?/)@@g' "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libc.so"

  # So far, not clear how to add lib search paths to ZIG so we copy the needed libs to where ZIG look for them
  ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/libm.so.6 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib
  ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/libmvec.so.1 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib
  ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/libc.so.6 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib

  if [[ "${SYSROOT_ARCH}" == "aarch64" ]]; then
    ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/ld-linux-aarch64.so.1 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib
  elif [[ "${SYSROOT_ARCH}" == "powerpc64le" ]]; then
    ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/ld64.so.2 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib
  elif [[ "${SYSROOT_ARCH}" == "x86_64" ]]; then
    ln -s "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/lib64/ld-linux-x86-64.so.2 "${prefix}"/"${SYSROOT_ARCH}"-conda-linux-gnu/sysroot/usr/lib
  fi
}

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}"
    if [[ "${zig:-}" != '' ]]; then
      _c="${zig};cc;-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline}"
      _cxx="${zig};c++;-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline}"
      if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
        _c="${_c};-fqemu"
        _cxx="${_cxx};-fqemu"
      fi
      EXTRA_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=${_c}")
      EXTRA_CMAKE_ARGS+=("-DCMAKE_CXX_COMPILER=${_cxx}")
      EXTRA_CMAKE_ARGS+=("-DCMAKE_AR=${zig}")
      EXTRA_CMAKE_ARGS+=("-DZIG_AR_WORKAROUND=ON")
    fi

    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${EXTRA_CMAKE_ARGS[@]}" \
      -G Ninja

    if [[ "${target_platform}" == "osx-64" ]]; then
      sed -i '' "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}/config.h"
    fi

    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
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
      if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
        remove_failing_langref "${SRC_DIR}/conda-zig-source"
      fi
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

function patchelf_installed_zig() {
  local install_dir=$1
  local _prefix=$2

  patchelf --remove-rpath                                                                          "${install_dir}/bin/zig"
  patchelf --set-rpath      "${_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64"             "${install_dir}/bin/zig"
  patchelf --add-rpath      "${_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/lib"                       "${install_dir}/bin/zig"
  patchelf --add-rpath      "${_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64"         "${install_dir}/bin/zig"
  patchelf --add-rpath      "${_prefix}/lib"                                                       "${install_dir}/bin/zig"
  patchelf --add-rpath      "${PREFIX}/lib"                                                        "${install_dir}/bin/zig"

  patchelf --set-interpreter "${_prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/lib64/ld-2.28.so" "${install_dir}/bin/zig"
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

# Configuration relevant to conda environment
EXTRA_CMAKE_ARGS+=( \
"-DZIG_SHARED_LLVM=ON" \
"-DZIG_USE_LLVM_CONFIG=OFF" \
)

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
configure_platform

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

if [[ "${BUILD_FROM_SOURCE:-0}" == "1" ]]; then
  cmake_build_install "${cmake_build_dir}"
fi

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
EXTRA_ZIG_ARGS+=( \
  "-Dconfig_h=${cmake_build_dir}/config.h" \
  "-Denable-llvm" \
  "-Dstrip" \
  "-Duse-zig-libcxx=false" \
  )

mkdir -p "${SRC_DIR}/conda-zig-source" && cp -r "${SRC_DIR}"/zig-source/* "${SRC_DIR}/conda-zig-source"
if [[ "${BUILD_FROM_SOURCE:-0}" == "1" ]]; then
  self_build "${SRC_DIR}/conda-zig-source" "${cmake_install_dir}" "${PREFIX}"
else
  self_build "${SRC_DIR}/conda-zig-source" "${SRC_DIR}/zig-bootstrap/zig" "${PREFIX}"
fi

if [[ "${target_platform}" == "linux-aarch64" ]]; then
  patchelf_installed_zig "${PREFIX}" "${PREFIX}"
fi
