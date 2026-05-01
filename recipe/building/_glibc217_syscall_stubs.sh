function create_glibc217_syscall_stubs() {
  # Create syscall stubs for glibc < 2.25/2.27/2.28 compatibility
  #
  # zig2.c (the pre-generated C bootstrap) calls glibc wrapper functions that
  # don't exist in conda-forge's glibc 2.17 sysroot:
  #   - getrandom()        — glibc 2.25  (syscall since Linux 3.17)
  #   - copy_file_range()  — glibc 2.27  (syscall since Linux 4.5)
  #   - statx()            — glibc 2.28  (syscall since Linux 4.11)
  #
  # These stubs use the raw syscall() interface (available in all glibc versions)
  # to provide the missing functions at link time.

  local cc_compiler="${1}"
  local output_dir="${2:-${SRC_DIR}}"

  is_debug && echo "Creating glibc 2.17 syscall stubs (getrandom, copy_file_range, statx)"

  cat > "${output_dir}/glibc217_syscall_stubs.c" << 'EOF'
/*
 * Syscall stubs for glibc < 2.28 (conda-forge glibc 2.17 baseline).
 *
 * zig2.c references getrandom, copy_file_range, and statx which are
 * glibc wrappers added in 2.25/2.27/2.28 respectively. On glibc 2.17
 * these symbols don't exist, causing link failures. We provide them
 * via raw syscall() which is available in all glibc versions.
 *
 * Weak symbols so they're overridden if a newer glibc provides them.
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
#include <sys/types.h>

/* ---- getrandom (glibc 2.25, Linux 3.17) ---- */
#ifndef SYS_getrandom
#  if defined(__x86_64__)
#    define SYS_getrandom 318
#  elif defined(__aarch64__)
#    define SYS_getrandom 278
#  elif defined(__powerpc64__)
#    define SYS_getrandom 359
#  elif defined(__riscv)
#    define SYS_getrandom 278
#  elif defined(__s390x__)
#    define SYS_getrandom 349
#  endif
#endif

__attribute__((weak))
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) {
    long ret = syscall(SYS_getrandom, buf, buflen, flags);
    return ret;
}

/* ---- copy_file_range (glibc 2.27, Linux 4.5) ---- */
#ifndef SYS_copy_file_range
#  if defined(__x86_64__)
#    define SYS_copy_file_range 326
#  elif defined(__aarch64__)
#    define SYS_copy_file_range 285
#  elif defined(__powerpc64__)
#    define SYS_copy_file_range 379
#  elif defined(__riscv)
#    define SYS_copy_file_range 285
#  elif defined(__s390x__)
#    define SYS_copy_file_range 375
#  endif
#endif

__attribute__((weak))
ssize_t copy_file_range(int fd_in, off_t *off_in, int fd_out,
                        off_t *off_out, size_t len, unsigned int flags) {
    long ret = syscall(SYS_copy_file_range, fd_in, off_in,
                       fd_out, off_out, len, flags);
    return ret;
}

/* ---- statx (glibc 2.28, Linux 4.11) ---- */
#ifndef SYS_statx
#  if defined(__x86_64__)
#    define SYS_statx 332
#  elif defined(__aarch64__)
#    define SYS_statx 291
#  elif defined(__powerpc64__)
#    define SYS_statx 383
#  elif defined(__riscv)
#    define SYS_statx 291
#  elif defined(__s390x__)
#    define SYS_statx 379
#  endif
#endif

/* Forward-declare statx struct to avoid pulling in kernel headers
   that may conflict with glibc headers on older systems. */
struct statx;

__attribute__((weak))
int statx(int dirfd, const char *pathname, int flags,
          unsigned int mask, struct statx *statxbuf) {
    /* syscall() handles errno conversion: returns -1 and sets errno on error */
    long ret = syscall(SYS_statx, dirfd, pathname, flags, mask, statxbuf);
    return (int)ret;
}
EOF

  "${cc_compiler}" -c "${output_dir}/glibc217_syscall_stubs.c" \
    -o "${output_dir}/glibc217_syscall_stubs.o" || {
    echo "ERROR: Failed to compile glibc 2.17 syscall stubs" >&2
    return 1
  }

  if [[ ! -f "${output_dir}/glibc217_syscall_stubs.o" ]]; then
    echo "ERROR: glibc217_syscall_stubs.o was not created" >&2
    return 1
  fi

  is_debug && echo "glibc 2.17 syscall stubs created: ${output_dir}/glibc217_syscall_stubs.o"
  return 0
}
