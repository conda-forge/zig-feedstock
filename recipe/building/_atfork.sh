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
