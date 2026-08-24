# Patch a single CRT object file with __libc_csu_init/fini stubs
#
# GCC 14 removed __libc_csu_init and __libc_csu_fini from crtbegin/crtend
# but glibc 2.28 crt1.o still references them, causing linker errors
#
# Args:
#   $1 - Path to CRT object file (e.g., crt1.o)
#   $2 - Stub directory containing architecture-specific stub objects
#
# Returns: 0 on success, 1 if patching not possible/needed
#
# Process:
#   1. Backup original CRT file
#   2. Detect architecture from ELF header
#   3. Select appropriate stub object file for architecture
#   4. Use ld -r to combine original and stub objects
#   5. Replace original with combined version
#
function patch_crt_object() {
  local crt_path="$1"
  local stub_dir="$2"

  [[ -f "${crt_path}" ]] || return 1

  # Backup original
  cp "${crt_path}" "${crt_path}.backup" || {
    echo "WARNING: _libc_tuning: backup copy failed for ${crt_path}" >&2
    return 1
  }

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
      # Unrecognized arch: only warn if the object actually needs the stubs
      if ! grep -qa '__libc_csu_init' "${crt_path}.backup"; then
        dbg echo "_libc_tuning: ${crt_path} does not reference __libc_csu_init, no patch needed"
        cp "${crt_path}.backup" "${crt_path}"
        return 0
      fi
      echo "WARNING: _libc_tuning: unrecognized architecture: ${file_output} for ${crt_path}" >&2
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
  local ld_err
  if ! ld_err=$("${linker_cmd}" -r -o "${crt_path}.tmp" "${crt_path}.backup" "${stub_obj}" 2>&1); then
    # Linking failed - restore original and skip
    echo "WARNING: _libc_tuning: 'ld -r' link failed for ${crt_path}: ${ld_err}" >&2
    cp "${crt_path}.backup" "${crt_path}"
    return 1
  fi

  # Replace original with combined version
  mv "${crt_path}.tmp" "${crt_path}"
  dbg echo "    Patched $(basename "${crt_path}") [${obj_arch}]" >&2
  return 0
}

# Create GCC 14 + glibc 2.28 compatibility library
#
# GCC 14 removed __libc_csu_init and __libc_csu_fini from crtbegin/crtend
# but glibc 2.28 crt1.o still references them, causing linker errors
#
# This function:
#   1. Creates stub source code with empty __libc_csu_init and __libc_csu_fini
#   2. Compiles stub objects for all available cross-compiler architectures
#   3. Creates a static library (libcsu_compat.a) with the stubs
#   4. Patches all glibc crt1.o files to include the stub symbols
#
# Args:
#   $1 - Prefix directory (default: $BUILD_PREFIX)
#
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

  dbg echo "Compiling CSU stubs for available architectures..."

  # Compile stub objects for all available architectures
  local arch_compilers=(
    "x86_64:${prefix}/bin/x86_64-conda-linux-gnu-cc:libc_csu_stubs_x86_64.o"
    "powerpc64le:${prefix}/bin/powerpc64le-conda-linux-gnu-cc:libc_csu_stubs_ppc64le.o"
    "aarch64:${prefix}/bin/aarch64-conda-linux-gnu-cc:libc_csu_stubs_aarch64.o"
  )

  for entry in "${arch_compilers[@]}"; do
    IFS=: read -r arch compiler output <<< "${entry}"
    if [[ -x "${compiler}" ]]; then
      dbg echo "  - Compiling for ${arch}"
      "${compiler}" -c "${stub_dir}/libc_csu_stubs.c" -o "${stub_dir}/${output}" || {
        echo "    Warning: Failed to compile for ${arch}" >&2
      }
    fi
  done

  # Patch glibc crt1.o files which reference __libc_csu_init/fini
  # NOTE: We do NOT patch GCC's crtbegin*.o files to avoid duplicate symbol definitions
  dbg echo "Patching glibc crt1.o files..."
  local crt_files=(crt1.o Scrt1.o gcrt1.o grcrt1.o)

  local _crt_failed=0
  for sysroot_dir in "${prefix}"/*-conda-linux-gnu/sysroot/usr/lib; do
    [[ -d "${sysroot_dir}" ]] || continue

    for crt_file in "${crt_files[@]}"; do
      [[ -f "${sysroot_dir}/${crt_file}" ]] || continue
      patch_crt_object "${sysroot_dir}/${crt_file}" "${stub_dir}" || _crt_failed=$(( _crt_failed + 1 ))
    done
  done

  if [[ "${_crt_failed}" -gt 0 ]]; then
    echo "WARNING: _libc_tuning: ${_crt_failed} CRT object(s) failed to patch (see warnings above)" >&2
  fi

  dbg echo "Created GCC 14 + glibc 2.28 compatibility:"
  dbg echo "  - Patched all glibc crt1*.o files with stub symbols"
}
