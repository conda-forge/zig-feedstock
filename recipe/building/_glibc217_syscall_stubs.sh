function create_glibc217_syscall_stubs() {
  # Create compatibility stubs for glibc < 2.18/2.25/2.27/2.28 gaps
  #
  # zig2.c (the pre-generated C bootstrap) and libc++/libsupc++ call glibc
  # exports that don't exist in conda-forge's glibc 2.17 sysroot:
  #   - __cxa_thread_atexit_impl — glibc 2.18  (thread_local dtor registration)
  #   - getrandom()        — glibc 2.25  (syscall since Linux 3.17)
  #   - copy_file_range()  — glibc 2.27  (syscall since Linux 4.5)
  #   - statx()            — glibc 2.28  (syscall since Linux 4.11)
  #
  # getrandom/copy_file_range/statx use the raw syscall() interface (available
  # in all glibc versions). __cxa_thread_atexit_impl has no syscall number --
  # it's a userspace runtime function -- so it's reimplemented below using
  # pthread_key_create, matching the fallback algorithm glibc/libstdc++ use
  # internally when this export is absent.

  local cc_compiler="${1}"
  local output_dir="${2:-${SRC_DIR}}"

  dbg echo "Creating glibc 2.17 compat stubs (__cxa_thread_atexit_impl, getrandom, copy_file_range, statx)"

  cat > "${output_dir}/glibc217_syscall_stubs.c" << 'EOF'
/*
 * Compat stubs for glibc < 2.18/2.28 (conda-forge glibc 2.17 baseline).
 *
 * zig2.c references getrandom, copy_file_range, and statx which are
 * glibc wrappers added in 2.25/2.27/2.28 respectively; libc++/libsupc++
 * reference __cxa_thread_atexit_impl, added in glibc 2.18. On glibc 2.17
 * these symbols don't exist, causing link failures. getrandom/
 * copy_file_range/statx are provided via raw syscall() (available in all
 * glibc versions); __cxa_thread_atexit_impl has no syscall number, so it's
 * reimplemented via pthread_key_create below.
 *
 * Weak symbols so they're overridden if a newer glibc provides them.
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
#include <sys/types.h>
#include <pthread.h>
#include <stdlib.h>

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

/* ---- __cxa_thread_atexit_impl (glibc 2.18) ---- */
/*
 * Unlike the stubs above, this has no raw syscall equivalent -- it's a
 * userspace glibc export used by libc++/libsupc++ to register non-trivial
 * thread_local destructors: __cxa_thread_atexit_impl(dtor, obj, dso_symbol).
 * glibc 2.17 predates it. Reimplemented here using pthread_key_create,
 * matching the fallback algorithm glibc/libstdc++ use internally when this
 * export is absent: a per-thread LIFO list of (dtor, obj) pairs run via a
 * single pthread_key destructor at thread exit -- LIFO order matches the
 * C++ standard's requirement that thread_local destructors run in reverse
 * order of construction. dso_symbol (used by real glibc to keep the owning
 * DSO alive until the thread exits) is intentionally unused: zig-produced
 * binaries here are statically linked, so there's no dlclose hazard to
 * guard against.
 */
struct __cxa_thread_atexit_node {
    void (*dtor)(void *);
    void *obj;
    struct __cxa_thread_atexit_node *next;
};

static pthread_key_t __cxa_thread_atexit_key;
static pthread_once_t __cxa_thread_atexit_once = PTHREAD_ONCE_INIT;

static void __cxa_thread_atexit_run(void *arg) {
    struct __cxa_thread_atexit_node *node = (struct __cxa_thread_atexit_node *)arg;
    while (node) {
        struct __cxa_thread_atexit_node *next = node->next;
        node->dtor(node->obj);
        free(node);
        node = next;
    }
}

static void __cxa_thread_atexit_make_key(void) {
    pthread_key_create(&__cxa_thread_atexit_key, __cxa_thread_atexit_run);
}

__attribute__((weak))
int __cxa_thread_atexit_impl(void (*dtor)(void *), void *obj, void *dso_symbol) {
    (void)dso_symbol;
    pthread_once(&__cxa_thread_atexit_once, __cxa_thread_atexit_make_key);
    struct __cxa_thread_atexit_node *node =
        (struct __cxa_thread_atexit_node *)malloc(sizeof(*node));
    if (!node) {
        return -1;
    }
    node->dtor = dtor;
    node->obj = obj;
    node->next = (struct __cxa_thread_atexit_node *)pthread_getspecific(__cxa_thread_atexit_key);
    pthread_setspecific(__cxa_thread_atexit_key, node);
    return 0;
}
EOF

  # zig cc injects UBSan instrumentation by default even for this bare
  # -target/-c invocation. The __cxa_thread_atexit_impl stub's void*-cast
  # pthread destructor callback (required by POSIX's destructor signature)
  # triggers a __ubsan_handle_type_mismatch_v1 call, but no UBSan runtime is
  # linked at final zig build-exe link time, causing an undefined reference.
  # Suppress the instrumentation for this standalone stub object.
  "${cc_compiler}" -c "${output_dir}/glibc217_syscall_stubs.c" \
    -fno-sanitize=undefined \
    -o "${output_dir}/glibc217_syscall_stubs.o" || {
    echo "ERROR: Failed to compile glibc 2.17 syscall stubs" >&2
    return 1
  }

  if [[ ! -f "${output_dir}/glibc217_syscall_stubs.o" ]]; then
    echo "ERROR: glibc217_syscall_stubs.o was not created" >&2
    return 1
  fi

  dbg echo "glibc 2.17 syscall stubs created: ${output_dir}/glibc217_syscall_stubs.o"
  return 0
}
