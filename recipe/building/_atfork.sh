function create_pthread_atfork_stub() {
  # Create pthread_atfork stub for glibc 2.28 on PowerPC64LE and aarch64
  # glibc 2.28 for these architectures doesn't export pthread_atfork symbol
  # (x86_64 glibc 2.28 has it, but PowerPC64LE and aarch64 don't)

  local arch_name="${1}"
  local cc_compiler="${2}"
  local output_dir="${3:-${SRC_DIR}}"

  is_debug && echo "Creating pthread_atfork stub for glibc 2.28 ${arch_name}"

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

  is_debug && echo "pthread_atfork stub created: ${output_dir}/pthread_atfork_stub.o"
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

  is_debug && echo "Creating __libc_single_threaded stub for ${arch_name}"

  cat > "${output_dir}/libc_single_threaded_stub.c" << 'EOF'
// Weak stub for __libc_single_threaded when targeting glibc < 2.32
// glibc 2.32 introduced this symbol; GCC 15 libstdc++ references it.
// Value 0 = multi-threaded (safe conservative default).
__attribute__((weak))
char __libc_single_threaded = 0;
EOF

  "${cc_compiler}" -c "${output_dir}/libc_single_threaded_stub.c" -o "${output_dir}/libc_single_threaded_stub.o" || {
    echo "ERROR: Failed to compile __libc_single_threaded stub" >&2
    return 1
  }

  if [[ ! -f "${output_dir}/libc_single_threaded_stub.o" ]]; then
    echo "ERROR: libc_single_threaded_stub.o was not created" >&2
    return 1
  fi

  is_debug && echo "__libc_single_threaded stub created: ${output_dir}/libc_single_threaded_stub.o"
  return 0
}
