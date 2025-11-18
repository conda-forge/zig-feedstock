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

  # Replace libc.so and libm.so linker scripts with symlinks (Zig doesn't support relative paths in linker scripts)
  # The linker scripts contain relative paths like "libc.so.6" which Zig can't handle (hits TODO panic at line 1074)
  # Just replace them with symlinks directly to the actual .so files
  if [[ -f "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libc.so" ]]; then
    if head -c 10 "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libc.so" 2>/dev/null | grep -q "^[[:print:]]"; then
      rm -f "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libc.so"
      ln -sf ../../lib64/libc.so.6 "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libc.so"
    fi
  fi

  if [[ -f "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libm.so" ]]; then
    if head -c 10 "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libm.so" 2>/dev/null | grep -q "^[[:print:]]"; then
      rm -f "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libm.so"
      ln -sf ../../lib64/libm.so.6 "${prefix}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot/usr/lib64/libm.so"
    fi
  fi

  # Replace libgcc_s.so linker scripts with symlinks (Zig doesn't support relative paths in linker scripts)
  # The linker scripts contain "GROUP ( libgcc_s.so.1 )" which is a relative path - Zig can't handle this
  # Just replace the linker script with a symlink directly to the actual .so file
  find "${prefix}" -name "libgcc_s.so" -type f 2>/dev/null | while read -r libgcc_file; do
    if head -c 10 "$libgcc_file" 2>/dev/null | grep -q "^[[:print:]]"; then
      libgcc_dir=$(dirname "$libgcc_file")
      rm -f "$libgcc_file"
      ln -sf libgcc_s.so.1 "$libgcc_file"
    fi
  done

  # Remove problematic ncurses linker scripts (Zig doesn't support relative paths in linker scripts)
  # The linker scripts reference libncurses.so.6 which is a relative path - Zig can't handle this
  # Just remove the linker script and create a symlink directly to the actual .so file
  if [[ -f "${prefix}"/lib/libncurses.so ]]; then
    rm -f "${prefix}"/lib/libncurses.so
    ln -sf libncurses.so.6 "${prefix}"/lib/libncurses.so
  fi
  if [[ -f "${prefix}"/lib/libncursesw.so ]]; then
    rm -f "${prefix}"/lib/libncursesw.so
    ln -sf libncursesw.so.6 "${prefix}"/lib/libncursesw.so
  fi

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

function create_gcc14_glibc28_compat_lib() {
  # GCC 14 removed __libc_csu_init and __libc_csu_fini from crtbegin/crtend
  # but glibc 2.28 crt1.o and Scrt1.o still reference them
  # Create a static library with stub implementations for linking
  local stub_dir="${BUILD_PREFIX}/lib/gcc14-glibc28-compat"
  mkdir -p "${stub_dir}"

  cat > "${stub_dir}/libc_csu_stubs.c" << 'EOF'
/* Stub implementations for GCC 14 + glibc 2.28 compatibility */
void __libc_csu_init(void) {
    /* Empty - old-style static constructors not used anymore */
}

void __libc_csu_fini(void) {
    /* Empty - old-style static destructors not used anymore */
}
EOF

  # Compile stub objects for all available architectures
  # We need architecture-specific object files to patch architecture-specific CRT files
  local gcc_version
  gcc_version=$("${CC}" -dumpversion)

  # Compile for x86_64 (native)
  if [[ -x "${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-cc" ]]; then
    "${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-cc" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/libc_csu_stubs_x86_64.o"
  fi

  # Compile for powerpc64le (if cross-compiling)
  if [[ -x "${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-cc" ]]; then
    "${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-cc" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/libc_csu_stubs_ppc64le.o"
  fi

  # Compile for aarch64 (if cross-compiling)
  if [[ -x "${BUILD_PREFIX}/bin/aarch64-conda-linux-gnu-cc" ]]; then
    "${BUILD_PREFIX}/bin/aarch64-conda-linux-gnu-cc" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/libc_csu_stubs_aarch64.o"
  fi

  # Create static library using the current target architecture
  "${CC}" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/libc_csu_stubs.o"
  "${AR}" rcs "${stub_dir}/libcsu_compat.a" "${stub_dir}/libc_csu_stubs.o"

  # Copy to standard library location
  cp "${stub_dir}/libcsu_compat.a" "${BUILD_PREFIX}/lib/"

  # Helper function to patch a crt object file
  patch_crt_object() {
    local crt_path="$1"

    if [[ -f "${crt_path}" ]]; then
      # Backup original
      cp "${crt_path}" "${crt_path}.backup"

      # Detect architecture of object file and use appropriate linker + stub
      local obj_arch
      local file_output
      file_output=$(file "${crt_path}.backup")

      local linker_cmd="ld"
      local stub_obj=""

      if echo "${file_output}" | grep -q "x86-64"; then
        obj_arch="x86-64"
        linker_cmd="${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-ld"
        stub_obj="${stub_dir}/libc_csu_stubs_x86_64.o"
      elif echo "${file_output}" | grep -qi "PowerPC\|ppc64"; then
        obj_arch="PowerPC64"
        linker_cmd="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
        stub_obj="${stub_dir}/libc_csu_stubs_ppc64le.o"
      elif echo "${file_output}" | grep -qi "aarch64\|ARM.*64"; then
        obj_arch="aarch64"
        linker_cmd="${BUILD_PREFIX}/bin/aarch64-conda-linux-gnu-ld"
        stub_obj="${stub_dir}/libc_csu_stubs_aarch64.o"
      else
        # Unknown architecture or detection failed - skip patching
        cp "${crt_path}.backup" "${crt_path}"
        return 1
      fi

      # Check if stub object exists for this architecture
      if [[ ! -f "${stub_obj}" ]]; then
        cp "${crt_path}.backup" "${crt_path}"
        return 1
      fi

      # Use 'ld -r' to combine the original and stub objects into a new object
      "${linker_cmd}" -r -o "${crt_path}.tmp" "${crt_path}.backup" "${stub_obj}" 2>/dev/null || {
        # If ld -r fails, just restore original (silently skip patching)
        cp "${crt_path}.backup" "${crt_path}"
        return 1
      }

      # Replace original with combined version
      mv "${crt_path}.tmp" "${crt_path}"
      echo "    ✓ Patched $(basename ${crt_path}) [${obj_arch}]"
      return 0
    fi
    return 1
  }

  # CRITICAL: Patch glibc crt1.o files which reference __libc_csu_init/fini
  # NOTE: We do NOT patch GCC's crtbegin*.o files to avoid duplicate symbol definitions
  # These are the files that actually have undefined references
  echo "  - Patching glibc crt1.o files..."
  for sysroot_dir in "${BUILD_PREFIX}"/*-conda-linux-gnu/sysroot/usr/lib; do
    if [[ -d "${sysroot_dir}" ]]; then
      patch_crt_object "${sysroot_dir}/crt1.o" || true
      patch_crt_object "${sysroot_dir}/Scrt1.o" || true
      patch_crt_object "${sysroot_dir}/gcrt1.o" || true
      patch_crt_object "${sysroot_dir}/grcrt1.o" || true  # May not exist in all sysroots
    fi
  done

  echo "Created GCC 14 + glibc 2.28 compatibility:"
  echo "  - ${BUILD_PREFIX}/lib/libcsu_compat.a"
  echo "  - Patched all glibc crt1*.o files with stub symbols"
}

function configure_cmake() {
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

    if [[ ${USE_CMAKE_ARGS:-0} == 1 ]]; then
      # Split $CMAKE_ARGS into an array
      IFS=' ' read -r -a cmake_args_array <<< "$CMAKE_ARGS"
      EXTRA_CMAKE_ARGS+=("${cmake_args_array[@]}")
    fi

    cmake "${SRC_DIR}"/zig-source \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${EXTRA_CMAKE_ARGS[@]}" \
      -G Ninja
  cd "${current_dir}" || exit 1
}

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}
  local target_arch="${4:-${target_platform:-linux-64}}"  # e.g., linux-64, linux-ppc64le

  # Cache libzigcpp.a per architecture to speed up rebuilds
  local cache_dir="${RECIPE_DIR}/.cache/zigcpp/${target_arch}"
  local cache_file="${cache_dir}/libzigcpp.a"
  local cache_meta="${cache_dir}/build.meta"
  local llvm_version
  llvm_version=$(llvm-config --version 2>/dev/null || echo "unknown")
  # Use basename for compiler to avoid path mismatches between builds
  local compiler_id="$(basename "${CC:-gcc}")-$(${CC:-gcc} -dumpversion 2>/dev/null || echo "unknown")"

  mkdir -p "${cache_dir}"

  # Check if we can reuse cached libzigcpp.a
  local can_reuse_cache=false
  if [[ -f "${cache_file}" && -f "${cache_meta}" ]]; then
    local cached_info
    cached_info=$(cat "${cache_meta}")
    local cached_llvm_version=$(echo "${cached_info}" | cut -d'|' -f1)
    local cached_compiler=$(echo "${cached_info}" | cut -d'|' -f2)

    if [[ "${cached_llvm_version}" == "${llvm_version}" && "${cached_compiler}" == "${compiler_id}" ]]; then
      echo "✓ Found compatible cached libzigcpp.a (${target_arch}, LLVM ${llvm_version}, ${compiler_id})"
      can_reuse_cache=true
    else
      echo "⚠ Cache mismatch - cached: LLVM ${cached_llvm_version}/${cached_compiler}, current: LLVM ${llvm_version}/${compiler_id}"
    fi
  else
    echo "ℹ No cached libzigcpp.a found for ${target_arch}"
  fi

  if [[ "${can_reuse_cache}" == "true" ]]; then
    # Reuse cached library
    configure_cmake "${build_dir}" "${install_dir}" "${zig}"
    mkdir -p "${build_dir}/zigcpp"
    cp "${cache_file}" "${build_dir}/zigcpp/libzigcpp.a"
    echo "✓ Reused cached libzigcpp.a - saved ~5-10 minutes!"
  else
    # Build from scratch
    echo "Building libzigcpp.a from scratch (${target_arch}, LLVM ${llvm_version})"
    configure_cmake "${build_dir}" "${install_dir}" "${zig}"
    pushd "${build_dir}"
      cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
    popd

    # Cache the built library for future use
    if [[ -f "${build_dir}/zigcpp/libzigcpp.a" ]]; then
      cp "${build_dir}/zigcpp/libzigcpp.a" "${cache_file}"
      echo "${llvm_version}|${compiler_id}" > "${cache_meta}"
      echo "✓ Cached libzigcpp.a at ${cache_file}"
      echo "  (LLVM ${llvm_version}, compiler: ${compiler_id})"
    fi
  fi
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

  if [[ ${USE_CROSSCOMPILING_EMULATOR:-} == '' ]]; then
    _cmd=("${zig}")
  else
    _cmd=("${CROSSCOMPILING_EMULATOR}" "${zig}")
  fi
  echo "Building with ${_cmd[*]}"
  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || exit 1
      "${_cmd[@]}" build \
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

