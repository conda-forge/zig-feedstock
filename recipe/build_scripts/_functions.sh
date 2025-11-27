# Filter out arguments matching patterns from an array
# Usage: filter_array_args ARRAY_NAME "pattern1" "pattern2" ...
# Example: filter_array_args EXTRA_CMAKE_ARGS "-DZIG_SYSTEM_LIBCXX=*" "-DZIG_USE_LLVM_CONFIG=*"
function filter_array_args() {
  local array_name="$1"
  shift  # Remove array name, rest are patterns to filter

  # Use nameref to work with the array indirectly
  local -n arr_ref="$array_name"
  local new_args=()
  local arg
  local pattern
  local skip

  for arg in "${arr_ref[@]}"; do
    skip=false
    for pattern in "$@"; do
      case "$arg" in
        $pattern) skip=true; break ;;
      esac
    done

    if [[ "$skip" == "false" ]]; then
      new_args+=("$arg")
    fi
  done

  # Replace original array
  arr_ref=("${new_args[@]}")
}

function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}" || return 1
    cmake --build . -- -j"${CPU_COUNT}" || return 1
    cmake --install . || return 1
  cd "${current_dir}" || return 1
}

function modify_libc_libm_for_zig() {
  local prefix=${1:-$PREFIX}
  local sysroot_arch=${2:-${SYSROOT_ARCH:-x86_64}}

  # Helper: Check if file is a text/script file (linker script)
  is_text_file() {
    local file=$1
    [[ -f "$file" ]] && file "$file" | grep -qE "ASCII text|script"
  }

  # Replace libc.so and libm.so linker scripts with symlinks (Zig doesn't support relative paths in linker scripts)
  # The linker scripts contain relative paths like "libc.so.6" which Zig can't handle (hits TODO panic at line 1074)
  # Just replace them with symlinks directly to the actual .so files
  local libc_path="${prefix}/${sysroot_arch}-conda-linux-gnu/sysroot/usr/lib64/libc.so"
  if is_text_file "$libc_path"; then
    echo "  - Replacing libc.so linker script with symlink"
    rm -f "$libc_path"
    ln -sf ../../lib64/libc.so.6 "$libc_path"
  fi

  local libm_path="${prefix}/${sysroot_arch}-conda-linux-gnu/sysroot/usr/lib64/libm.so"
  if is_text_file "$libm_path"; then
    echo "  - Replacing libm.so linker script with symlink"
    rm -f "$libm_path"
    ln -sf ../../lib64/libm.so.6 "$libm_path"
  fi

  # Replace libgcc_s.so linker scripts with symlinks (Zig doesn't support relative paths in linker scripts)
  # The linker scripts contain "GROUP ( libgcc_s.so.1 )" which is a relative path - Zig can't handle this
  # Just replace the linker script with a symlink directly to the actual .so file
  while IFS= read -r -d '' libgcc_file; do
    if is_text_file "$libgcc_file"; then
      echo "  - Replacing $(basename $(dirname "$libgcc_file"))/libgcc_s.so linker script with symlink"
      rm -f "$libgcc_file"
      ln -sf libgcc_s.so.1 "$libgcc_file"
    fi
  done < <(find "${prefix}" -name "libgcc_s.so" -type f -print0 2>/dev/null)

  # Remove problematic ncurses linker scripts (Zig doesn't support relative paths in linker scripts)
  # The linker scripts reference libncurses.so.6 which is a relative path - Zig can't handle this
  # Just remove the linker script and create a symlink directly to the actual .so file
  local ncurses_path="${prefix}/lib/libncurses.so"
  if [[ -f "$ncurses_path" ]]; then
    echo "  - Replacing libncurses.so with symlink"
    rm -f "$ncurses_path"
    ln -sf libncurses.so.6 "$ncurses_path"
  fi

  local ncursesw_path="${prefix}/lib/libncursesw.so"
  if [[ -f "$ncursesw_path" ]]; then
    echo "  - Replacing libncursesw.so with symlink"
    rm -f "$ncursesw_path"
    ln -sf libncursesw.so.6 "$ncursesw_path"
  fi

  # Zig doesn't yet support custom lib search paths, so symlink needed libs to where Zig looks
  # Create symlinks from lib64 to usr/lib (Zig searches usr/lib by default)
  local sysroot="${prefix}/${sysroot_arch}-conda-linux-gnu/sysroot"
  echo "  - Creating symlinks in usr/lib for lib64 libraries"

  # Suppress error if symlink already exists
  ln -sf ../../../lib64/libm.so.6 "${sysroot}/usr/lib/libm.so.6" 2>/dev/null || true
  ln -sf ../../../lib64/libmvec.so.1 "${sysroot}/usr/lib/libmvec.so.1" 2>/dev/null || true
  ln -sf ../../../lib64/libc.so.6 "${sysroot}/usr/lib/libc.so.6" 2>/dev/null || true

  # Architecture-specific dynamic linker symlinks
  case "${sysroot_arch}" in
    aarch64)
      ln -sf ../../../lib64/ld-linux-aarch64.so.1 "${sysroot}/usr/lib/ld-linux-aarch64.so.1" 2>/dev/null || true
      ;;
    powerpc64le)
      ln -sf ../../../lib64/ld64.so.2 "${sysroot}/usr/lib/ld64.so.2" 2>/dev/null || true
      ;;
    x86_64)
      ln -sf ../../../lib64/ld-linux-x86-64.so.2 "${sysroot}/usr/lib/ld-linux-x86-64.so.2" 2>/dev/null || true
      ;;
  esac
}

# Patch a single CRT object file with __libc_csu_init/fini stubs
# Args:
#   $1 - Path to CRT object file
#   $2 - Stub directory containing architecture-specific stub objects
# Returns: 0 on success, 1 if patching not possible/needed
patch_crt_object() {
  local crt_path="$1"
  local stub_dir="$2"

  [[ -f "${crt_path}" ]] || return 1

  # Backup original
  cp "${crt_path}" "${crt_path}.backup" || return 1

  # Detect architecture of object file
  local file_output
  file_output=$(file "${crt_path}.backup")

  local obj_arch linker_cmd stub_obj
  case "${file_output}" in
    *x86-64*)
      obj_arch="x86-64"
      linker_cmd="${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-ld"
      stub_obj="${stub_dir}/libc_csu_stubs_x86_64.o"
      ;;
    *PowerPC*|*ppc64*)
      obj_arch="PowerPC64"
      linker_cmd="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
      stub_obj="${stub_dir}/libc_csu_stubs_ppc64le.o"
      ;;
    *aarch64*|*ARM*64*)
      obj_arch="aarch64"
      linker_cmd="${BUILD_PREFIX}/bin/aarch64-conda-linux-gnu-ld"
      stub_obj="${stub_dir}/libc_csu_stubs_aarch64.o"
      ;;
    *)
      # Unknown architecture - restore original and skip
      cp "${crt_path}.backup" "${crt_path}"
      return 1
      ;;
  esac

  # Check if stub object exists for this architecture
  if [[ ! -f "${stub_obj}" ]]; then
    cp "${crt_path}.backup" "${crt_path}"
    return 1
  fi

  # Use 'ld -r' to combine the original and stub objects
  if ! "${linker_cmd}" -r -o "${crt_path}.tmp" "${crt_path}.backup" "${stub_obj}" 2>/dev/null; then
    # Linking failed - restore original and skip
    cp "${crt_path}.backup" "${crt_path}"
    return 1
  fi

  # Replace original with combined version
  mv "${crt_path}.tmp" "${crt_path}"
  echo "    ✓ Patched $(basename "${crt_path}") [${obj_arch}]" >&2
  return 0
}

# Create GCC 14 + glibc 2.28 compatibility library
# GCC 14 removed __libc_csu_init and __libc_csu_fini from crtbegin/crtend
# but glibc 2.28 crt1.o still references them
function create_gcc14_glibc28_compat_lib() {
  local prefix="${1:-$BUILD_PREFIX}"
  
  local stub_dir="${prefix}/lib/gcc14-glibc28-compat"
  mkdir -p "${stub_dir}" || return 1

  # Create stub source file
  cat > "${stub_dir}/libc_csu_stubs.c" << 'EOF'
/* Stub implementations for GCC 14 + glibc 2.28 compatibility */
void __libc_csu_init(void) {
    /* Empty - old-style static constructors not used anymore */
}

void __libc_csu_fini(void) {
    /* Empty - old-style static destructors not used anymore */
}
EOF

  echo "Compiling CSU stubs for available architectures..."

  # Compile stub objects for all available architectures
  # We need architecture-specific object files to patch architecture-specific CRT files
  local arch_compilers=(
    "x86_64:${prefix}/bin/x86_64-conda-linux-gnu-cc:libc_csu_stubs_x86_64.o"
    "powerpc64le:${prefix}/bin/powerpc64le-conda-linux-gnu-cc:libc_csu_stubs_ppc64le.o"
    "aarch64:${prefix}/bin/aarch64-conda-linux-gnu-cc:libc_csu_stubs_aarch64.o"
  )

  for entry in "${arch_compilers[@]}"; do
    IFS=: read -r arch compiler output <<< "${entry}"
    if [[ -x "${compiler}" ]]; then
      echo "  - Compiling for ${arch}"
      "${compiler}" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/${output}" || {
        echo "    Warning: Failed to compile for ${arch}" >&2
      }
    fi
  done

  # Create static library using the current target architecture
  echo "Creating static library..."
  "${CC}" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/libc_csu_stubs.o" || return 1
  "${AR}" rcs "${stub_dir}/libcsu_compat.a" "${stub_dir}/libc_csu_stubs.o" || return 1

  # Copy to standard library location
  cp "${stub_dir}/libcsu_compat.a" "${prefix}/lib/" || return 1

  # Patch glibc crt1.o files which reference __libc_csu_init/fini
  # NOTE: We do NOT patch GCC's crtbegin*.o files to avoid duplicate symbol definitions
  echo "Patching glibc crt1.o files..."
  local crt_files=(crt1.o Scrt1.o gcrt1.o grcrt1.o)

  for sysroot_dir in "${prefix}"/*-conda-linux-gnu/sysroot/usr/lib; do
    [[ -d "${sysroot_dir}" ]] || continue

    for crt_file in "${crt_files[@]}"; do
      patch_crt_object "${sysroot_dir}/${crt_file}" "${stub_dir}" || true
    done
  done

  echo "Created GCC 14 + glibc 2.28 compatibility:"
  echo "  - ${prefix}/lib/libcsu_compat.a"
  echo "  - Patched all glibc crt1*.o files with stub symbols"
}

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  # Build local cmake args array
  local cmake_args=()

  # Add zig compiler configuration if provided
  if [[ -n "${zig}" ]]; then
    local _c="${zig};cc;-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline}"
    local _cxx="${zig};c++;-target;${SYSROOT_ARCH}-linux-gnu;-mcpu=${MCPU:-baseline}"

    # Add QEMU flag for native (non-cross) compilation
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
      _c="${_c};-fqemu"
      _cxx="${_cxx};-fqemu"
    fi

    cmake_args+=("-DCMAKE_C_COMPILER=${_c}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${_cxx}")
    cmake_args+=("-DCMAKE_AR=${zig}")
    cmake_args+=("-DZIG_AR_WORKAROUND=ON")
  fi

  # Merge with global EXTRA_CMAKE_ARGS if it exists
  # Use ${var+x} syntax for bash 3.2 compatibility (macOS default bash)
  if [[ -n "${EXTRA_CMAKE_ARGS+x}" ]]; then
    cmake_args+=("${EXTRA_CMAKE_ARGS[@]}")
  fi

  # Add CMAKE_ARGS from environment if requested
  if [[ ${USE_CMAKE_ARGS:-0} == 1 ]]; then
    IFS=' ' read -r -a cmake_args_from_env <<< "${CMAKE_ARGS:-}"
    cmake_args+=("${cmake_args_from_env[@]}")
  fi

  # Create build directory and run cmake
  mkdir -p "${build_dir}" || return 1

  (
    cd "${build_dir}" &&
    cmake "${cmake_source_dir}" \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${cmake_args[@]}" \
      -G Ninja
  ) || return 1
}

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  configure_cmake "${build_dir}" "${install_dir}" "${zig}"
  pushd "${build_dir}"
    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  popd
}

function setup_crosscompiling_emulator() {
  local qemu_prg=$1

  if [[ -z "${qemu_prg}" ]]; then
    echo "ERROR: qemu_prg parameter required for setup_crosscompiling_emulator" >&2
    return 1
  fi

  # Set CROSSCOMPILING_EMULATOR if not already set
  if [[ -z "${CROSSCOMPILING_EMULATOR:-}" ]]; then
    if [[ -f /usr/bin/"${qemu_prg}" ]]; then
      export CROSSCOMPILING_EMULATOR=/usr/bin/"${qemu_prg}"
      echo "Set CROSSCOMPILING_EMULATOR=${CROSSCOMPILING_EMULATOR}"
    else
      echo "ERROR: CROSSCOMPILING_EMULATOR not set and ${qemu_prg} not found in /usr/bin/" >&2
      return 1
    fi
  else
    echo "Using existing CROSSCOMPILING_EMULATOR=${CROSSCOMPILING_EMULATOR}"
  fi

  return 0
}

function create_qemu_llvm_config_wrapper() {
  local sysroot_path=$1

  if [[ -z "${sysroot_path}" ]]; then
    echo "ERROR: sysroot_path parameter required for create_qemu_llvm_config_wrapper" >&2
    return 1
  fi

  if [[ -z "${CROSSCOMPILING_EMULATOR:-}" ]]; then
    echo "ERROR: CROSSCOMPILING_EMULATOR must be set before calling create_qemu_llvm_config_wrapper" >&2
    return 1
  fi

  echo "Creating QEMU wrapper for llvm-config"

  # Backup original llvm-config
  mv "${PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config.zig_conda_real || return 1

  # Create wrapper script that runs llvm-config under QEMU
  cat > "${PREFIX}"/bin/llvm-config << EOF
#!/usr/bin/env bash
export QEMU_LD_PREFIX="${sysroot_path}"
"${CROSSCOMPILING_EMULATOR}" "${PREFIX}"/bin/llvm-config.zig_conda_real "\$@"
EOF

  chmod +x "${PREFIX}"/bin/llvm-config || return 1
  echo "✓ llvm-config wrapper created"
  return 0
}

function remove_qemu_llvm_config_wrapper() {
  if [[ -f "${PREFIX}"/bin/llvm-config.zig_conda_real ]]; then
    rm -f "${PREFIX}"/bin/llvm-config && mv "${PREFIX}"/bin/llvm-config.zig_conda_real "${PREFIX}"/bin/llvm-config || return 1
  fi
  return 0
}

function create_zig_libc_file() {
  local output_file=$1
  local sysroot_path=$2
  local sysroot_arch=$3

  if [[ -z "${output_file}" ]] || [[ -z "${sysroot_path}" ]] || [[ -z "${sysroot_arch}" ]]; then
    echo "ERROR: create_zig_libc_file requires: output_file, sysroot_path, sysroot_arch" >&2
    return 1
  fi

  echo "Creating Zig libc configuration file: ${output_file}"

  # Find GCC library directory (contains crtbegin.o, crtend.o)
  local gcc_lib_dir
  gcc_lib_dir=$(dirname "$(find "${BUILD_PREFIX}"/lib/gcc/${sysroot_arch}-conda-linux-gnu -name "crtbeginS.o" | head -1)")

  if [[ -z "${gcc_lib_dir}" ]] || [[ ! -d "${gcc_lib_dir}" ]]; then
    echo "WARNING: Could not find GCC library directory for ${sysroot_arch}" >&2
    gcc_lib_dir=""
  else
    echo "  Found GCC library directory: ${gcc_lib_dir}"
  fi

  # Create libc configuration file
  cat > "${output_file}" << EOF
include_dir=${sysroot_path}/usr/include
sys_include_dir=${sysroot_path}/usr/include
crt_dir=${sysroot_path}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_lib_dir}
EOF

  echo "✓ Zig libc file created: ${output_file}"
  return 0
}

function apply_cmake_patches() {
  local build_dir=$1

  # Check if CMAKE_PATCHES array exists and has elements
  if [[ -z "${CMAKE_PATCHES+x}" ]] || [[ ${#CMAKE_PATCHES[@]} -eq 0 ]]; then
    echo "No CMAKE_PATCHES defined, skipping patch application"
    return 0
  fi

  echo "Applying ${#CMAKE_PATCHES[@]} cmake patches to ${build_dir}"

  local patch_dir="${RECIPE_DIR}/patches/cmake"
  if [[ ! -d "${patch_dir}" ]]; then
    echo "ERROR: Patch directory ${patch_dir} does not exist" >&2
    return 1
  fi

  pushd "${build_dir}" > /dev/null || return 1
    for patch_file in "${CMAKE_PATCHES[@]}"; do
      local patch_path="${patch_dir}/${patch_file}"
      if [[ ! -f "${patch_path}" ]]; then
        echo "ERROR: Patch file ${patch_path} not found" >&2
        popd > /dev/null
        return 1
      fi

      echo "  Applying patch: ${patch_file}"
      if patch -p1 < "${patch_path}"; then
        echo "    ✓ ${patch_file} applied successfully"
      else
        echo "ERROR: Failed to apply patch ${patch_file}" >&2
        popd > /dev/null
        return 1
      fi
    done
  popd > /dev/null

  echo "All cmake patches applied successfully"
  return 0
}

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
        -Dversion-string="${PKG_VERSION}" || return 1
        # --search-prefix "${install_dir}" \
    cd "${current_dir}" || return 1
  else
    echo "No build directory found" >&2
    return 1
  fi
}

function remove_failing_langref() {
  local build_dir=$1
  local testslistfile=${2:-"${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt}

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}"/doc/langref ]]; then
    # These langref code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
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

function create_pthread_atfork_stub() {
  # Create pthread_atfork stub for glibc 2.28 on PowerPC64LE and aarch64
  # glibc 2.28 for these architectures doesn't export pthread_atfork symbol
  # (x86_64 glibc 2.28 has it, but PowerPC64LE and aarch64 don't)

  local arch_name="${1}"
  local cc_compiler="${2}"
  local output_dir="${3:-${SRC_DIR}}"

  echo "=== Creating pthread_atfork stub for glibc 2.28 ${arch_name} ==="

  cat > "${output_dir}/pthread_atfork_stub.c" << 'EOF'
// Weak stub for pthread_atfork when glibc 2.28 doesn't provide it
// This is safe because Zig compiler doesn't actually use fork()
__attribute__((weak))
int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    // Stub implementation - returns success without doing anything
    // (void) casts suppress unused parameter warnings
    (void)prepare;
    (void)parent;
    (void)child;
    return 0;  // Success
}
EOF

  "${cc_compiler}" -c "${output_dir}/pthread_atfork_stub.c" -o "${output_dir}/pthread_atfork_stub.o" || {
    echo "ERROR: Failed to compile pthread_atfork stub" >&2
    return 1
  }

  if [[ ! -f "${output_dir}/pthread_atfork_stub.o" ]]; then
    echo "ERROR: pthread_atfork_stub.o was not created" >&2
    return 1
  fi

  echo "=== pthread_atfork stub created: ${output_dir}/pthread_atfork_stub.o ==="
}

function build_cmake_lld() {
  local build_dir=$1
  local install_dir=$2

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}" || exit 1
    cmake "$ROOTDIR/llvm" \
      -DCMAKE_INSTALL_PREFIX="${install_dir}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_BINDINGS=OFF \
      -DLLVM_ENABLE_LIBEDIT=OFF \
      -DLLVM_ENABLE_LIBPFM=OFF \
      -DLLVM_ENABLE_LIBXML2=ON \
      -DLLVM_ENABLE_OCAMLDOC=OFF \
      -DLLVM_ENABLE_PLUGINS=OFF \
      -DLLVM_ENABLE_PROJECTS="lld" \
      -DLLVM_ENABLE_Z3_SOLVER=OFF \
      -DLLVM_ENABLE_ZSTD=ON \
      -DLLVM_INCLUDE_UTILS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF \
      -DLLVM_TOOL_LLVM_LTO_BUILD=OFF \
      -DLLVM_TOOL_LTO_BUILD=OFF \
      -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF \
      -DCLANG_BUILD_TOOLS=OFF \
      -DCLANG_INCLUDE_DOCS=OFF \
      -DCLANG_INCLUDE_TESTS=OFF \
      -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF \
      -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF \
      -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
      -DCLANG_TOOL_LIBCLANG_BUILD=OFF
    cmake --build . --target install
  cd "${current_dir}" || exit 1
}

function build_lld_ppc64le_mcmodel() {
  # Build LLD libraries for PowerPC64LE with -mcmodel=medium to avoid R_PPC64_REL24 truncation
  # Similar to configure_cmake_zigcpp but for LLD libraries

  local llvm_source_dir=$1
  local build_dir=$2
  local target_arch="${3:-linux-ppc64le}"

  # Build LLD from scratch with mcmodel=medium
  echo "Building LLD libraries for PowerPC64LE with -mcmodel=medium..."

  local current_dir
  current_dir=$(pwd)

  mkdir -p "${build_dir}"
  cd "${build_dir}" || exit 1

  # Configure LLVM to build only LLD libraries
  cmake "${llvm_source_dir}/lld" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DLLVM_ENABLE_PROJECTS="lld" \
    -DLLVM_TARGETS_TO_BUILD="PowerPC" \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_BUILD_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_CONFIG_PATH=$BUILD_PREFIX/bin/llvm-config \
    -DLLVM_TABLEGEN_EXE=$BUILD_PREFIX/bin/llvm-tblgen \
    -DLLVM_ENABLE_RTTI=ON \
    -G Ninja

  # Build all LLD libraries (they're defined as add_lld_library in lld/*/CMakeLists.txt)
  # Target names: lldELF, lldCommon, lldCOFF, lldMachO, lldWasm, lldMinGW
  cmake --build . -- -j${CPU_COUNT}

  cd "${current_dir}" || exit 1
}
