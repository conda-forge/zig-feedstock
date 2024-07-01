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
  case "${target_platform}" in
    linux-64)
      SYSROOT_ARCH="x86_64"
      EXTRA_ZIG_ARGS+=("-Dcpu=baseline")
      ;;

    linux-aarch64)
      SYSROOT_ARCH="aarch64"
      EXTRA_ZIG_ARGS+=("-Dcpu=baseline")
      ;;

    linux-ppc64le)
      SYSROOT_ARCH="powerpc64le"
      EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_MCPU=ppc64le")
      EXTRA_CMAKE_ARGS+=("-DZIG_SYSTEM_LIBCXX=stdc++")
      CFLAGS="${CFLAGS} -mlongcall -mcmodel=large -Os -Wl,--no-relax -fPIE -pie"
      CXXFLAGS="${CXXFLAGS} -mlongcall -mcmodel=large -Os -Wl,--no-relax -fPIE -pie"
      # export CFLAGS=${CFLAGS//-fno-plt/}
      # export CXXFLAGS=${CXXFLAGS//-fno-plt/}
      export CFLAGS=${CFLAGS}
      export CXXFLAGS=${CXXFLAGS}
      EXTRA_ZIG_ARGS+=("-Dcpu=ppc64le")
      ;;

    osx-64)
      SYSROOT_ARCH="macos"
      EXTRA_CMAKE_ARGS+=("-DZIG_SYSTEM_LIBCXX=c++")
      export DYLD_LIBRARY_PATH="${PREFIX}/lib"
      ;;
  esac

  if [[ "${build_platform}" != "osx-64" ]]; then
    EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu")
    EXTRA_CMAKE_ARGS+=("-DZIG_SYSTEM_LIBCXX=stdc++")
    # Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
    modify_libc_libm_for_zig "${BUILD_PREFIX}"
  fi

  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    EXTRA_CMAKE_ARGS+=("-DLLVM_CONFIG_EXE=${PREFIX}/bin/llvm-config")
    EXTRA_CMAKE_ARGS+=("-DZIG_TARGET_DYNAMIC_LINKER=${PREFIX}/aarch64-conda-linux-gnu/sysroot/libc64/libc.so.6")

    EXTRA_ZIG_ARGS+=("-Dtarget=${SYSROOT_ARCH}-linux-gnu")
    EXTRA_ZIG_ARGS+=("-fqemu")

    export ZIG_CROSS_TARGET_TRIPLE="${SYSROOT_ARCH}-linux-gnu"
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

    cmake --build . -v --target zigcpp -- -j"${CPU_COUNT}" > _build-zigcpp.log 2>&1
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
  local build_prefix=$1
  local sysroot_arch=$2

  cat <<EOF > _libc_file
include_dir=${build_prefix}/${sysroot_arch}-conda-linux-gnu/sysroot/usr/include
sys_include_dir=${build_prefix}/${sysroot_arch}-conda-linux-gnu/sysroot/usr/include
crt_dir=${build_prefix}/${sysroot_arch}-conda-linux-gnu/sysroot/usr/lib64
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

function patch_system() {
  local prefix_dir=$1

  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    signal="${prefix_dir}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/include/signal.h"
    expand -t 4 "${signal}" > "${signal}.tmp" && \
    mv "${signal}.tmp" "${signal}" && \
    if [[ -f "${SRC_DIR}"/build-level-patches/xxxx-sysroot-signal.h.patch ]]; then
      (cd "${prefix_dir}" && patch -Np0 -i "${SRC_DIR}"/build-level-patches/xxxx-sysroot-signal.h.patch --binary)
    fi
  fi
}

function staggered_cmake_with_patch() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}"
      if [[ "${target_platform}" == "linux-ppc64le" ]]; then
        cmake --build . -v --target zig2.c -- -j"${CPU_COUNT}" > _build-zig2.log 2>&1
        patch -Np0 -i "${SRC_DIR}"/build-level-patches/xxxx-zig2.c-asm-clobber-list.patch --binary
        cmake --build . -v --target compiler_rt.c -- -j"${CPU_COUNT}" >> _build-zig2.log 2>&1
        # patch -Np0 -i "${SRC_DIR}"/build-level-patches/xxxx-compiler_rt.c.patch --binary
        echo "Building zig2"
        cmake --build . -v --target zig2 -- -j"${CPU_COUNT}" >> _build-zig2.log 2>&1
      fi
  else
    echo "No build directory found"
    exit 1
  fi
  cd "${current_dir}"
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
cp -r "${RECIPE_DIR}"/patches/"${target_platform}"/xxxx* "${SRC_DIR}"/build-level-patches

# Configuration relevant to conda environment
EXTRA_CMAKE_ARGS+=( \
"-DZIG_SHARED_LLVM=OFF" \
"-DZIG_USE_LLVM_CONFIG=ON" \
)

# Current conda zig may not be able to build the latest zig
# mamba create -yp "${SRC_DIR}"/conda-zig-bootstrap zig
configure_platform

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

if [[ "${BUILD_SOURCE_WITH_CMAKE:-0}" == "1" ]]; then
  patch_system "${BUILD_PREFIX}"
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    export ZIG_CROSS_TARGET_TRIPLE="${SYSROOT_ARCH}-linux-gnu"
  fi
  staggered_cmake_with_patch "${cmake_build_dir}"
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
if [[ "${BUILD_SOURCE_WITH_CMAKE:-0}" == "1" ]]; then
  self_build "${SRC_DIR}/conda-zig-source" "${cmake_install_dir}" "${PREFIX}"
else
  self_build "${SRC_DIR}/conda-zig-source" "${SRC_DIR}/zig-bootstrap/zig" "${PREFIX}"
fi

if [[ "${target_platform}" == "linux-aarch64" ]] || [[ "${target_platform}" == "linux-ppc64le" ]]; then
  patchelf_installed_zig "${PREFIX}" "${PREFIX}"
fi