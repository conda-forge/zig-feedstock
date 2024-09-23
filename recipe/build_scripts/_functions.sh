function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}" || exit 1
    cmake --build . -- -j"${CPU_COUNT}"
    cmake --install .
  cd "${current_dir}" || exit 1
}

function cmake_build_cmake_target() {
  local build_dir=$1
  local target=$2

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}" || exit 1
    cmake --build . --target "${target}" -v -- -j"${CPU_COUNT}"
  cd "${current_dir}" || exit 1
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
  cd "${build_dir}" || exit 1
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
      sed -i '' "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" config.h
    elif [[ "${target_platform}" == "osx-arm64" ]]; then
      sed -i '' "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
    fi

    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  cd "${current_dir}" || exit 1
}

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  export HTTP_PROXY=http://localhost
  export HTTPS_PROXY=https://localhost
  export http_proxy=http://localhost

  if [[ -d "${build_dir}" ]]; then
    if [[ "${CROSSCOMPILING_EMULATOR:-0}" == *"qemu"* ]]; then
      ln -s "${CROSSCOMPILING_EMULATOR}" "${BUILD_PREFIX}/bin/qemu-${SYSROOT_ARCH}"
    fi

    cd "${build_dir}" || exit 1
      "${zig}" build \
        --prefix "${install_dir}" \
        --search-prefix "${install_dir}" \
        "${EXTRA_ZIG_ARGS[@]}" \
        -Dversion-string="${PKG_VERSION}"
    cd "${current_dir}" || exit 1
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

function remove_failing_langref() {
  local build_dir=$1
  local testslistfile=${2:-"${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt}

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}"/doc/langref ]]; then
    # These langerf code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
    # No idea why this comes up, there is no -lmvec_nonshared.a on the link command
    # there seems to be no way to redirect to sysroot/usr/lib64/libmvec_nonshared.a
    grep -v -f "${testslistfile}" "${build_dir}"/doc/langref.html.in > "${build_dir}"/doc/_langref.html.in
    mv "${build_dir}"/doc/_langref.html.in "${build_dir}"/doc/langref.html.in
    while IFS= read -r file
    do
      rm -f "${build_dir}"/doc/langref/"$file"
    done < "${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt
  else
    echo "No langref directory found"
    exit 1
  fi
}

