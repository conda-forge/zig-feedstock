source "${RECIPE_DIR}/building/_common.sh"

function _compile_stub_object() {
  # Helper to compile a stub .c file into a .o object
  # Args: cc_compiler src_file out_file label (for error messages)
  local cc="${1}"
  local src="${2}"
  local out="${3}"
  local label="${4}"

  "${cc}" -c "${src}" -o "${out}" || {
    echo "ERROR: Failed to compile ${label} stub" >&2
    return 1
  }

  if [[ ! -f "${out}" ]]; then
    echo "ERROR: ${label}.o was not created" >&2
    return 1
  fi
}

function create_pthread_atfork_stub() {
  # Create pthread_atfork stub for glibc 2.28 on PowerPC64LE and aarch64
  # glibc 2.28 for these architectures doesn't export pthread_atfork symbol
  # (x86_64 glibc 2.28 has it, but PowerPC64LE and aarch64 don't)

  local arch_name="${1}"
  local cc_compiler="${2}"
  local output_dir="${3:-${SRC_DIR}}"

  dbg echo "Creating pthread_atfork stub for glibc 2.28 ${arch_name}"

  cat > "${output_dir}/pthread_atfork_stub.c" << 'EOF'
// Strong __wrap_pthread_atfork for --wrap=pthread_atfork linker redirect.
// The linker rewrites all pthread_atfork references to __wrap_pthread_atfork;
// this strong definition satisfies them without pulling in libpthread_nonshared.a
// (which emits R_PPC64_REL24 relocations that truncate on ppc64le).
// Declared strong because the cmake path's --wrap mechanism does not require weak;
// the stub is intentionally NOT injected on the zig-build path (see recipe/build.sh),
// so duplicate-symbol concerns do not apply. The --wrap flag renames references
// regardless of weak/strong, so the redirect still activates correctly on the cmake path.
// This is safe because Zig compiler doesn't actually use fork().
int __wrap_pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    // Stub implementation - returns success without doing anything
    // (void) casts suppress unused parameter warnings
    (void)prepare;
    (void)parent;
    (void)child;
    return 0;  // Success
}
EOF

  _compile_stub_object "${cc_compiler}" "${output_dir}/pthread_atfork_stub.c" "${output_dir}/pthread_atfork_stub.o" "pthread_atfork" || return 1

  dbg echo "pthread_atfork stub created: ${output_dir}/pthread_atfork_stub.o"
  return 0
}

function create_libc_single_threaded_stub() {
  # Create __libc_single_threaded stub for cross-compiler builds targeting glibc < 2.32
  # GCC 15+ libstdc++/zigcpp references __libc_single_threaded (added in glibc 2.32).
  # When targeting gnu.2.17 or similar, the symbol is missing at link time.
  #
  # Declared as 'char' in <sys/single_threaded.h> (not bool).
  # Value 0 = multi-threaded (conservative/safe default for a stub).

  local arch_name="${1}"
  local cc_compiler="${2}"
  local output_dir="${3:-${SRC_DIR}}"

  dbg echo "Creating __libc_single_threaded stub for ${arch_name}"

  cat > "${output_dir}/libc_single_threaded_stub.c" << 'EOF'
// Weak stub for __libc_single_threaded when targeting glibc < 2.32
// glibc 2.32 introduced this symbol; GCC 15 libstdc++ references it.
// Value 0 = multi-threaded (safe conservative default).
__attribute__((weak))
char __libc_single_threaded = 0;
EOF

  _compile_stub_object "${cc_compiler}" "${output_dir}/libc_single_threaded_stub.c" "${output_dir}/libc_single_threaded_stub.o" "libc_single_threaded" || return 1

  dbg echo "__libc_single_threaded stub created: ${output_dir}/libc_single_threaded_stub.o"
  return 0
}
