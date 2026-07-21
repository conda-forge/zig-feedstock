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


function create_cxa_thread_atexit_impl_stub() {
  # Create __cxa_thread_atexit_impl stub for cross-compiler builds targeting glibc < 2.18
  # (Itanium C++ ABI thread_local destructor registration; glibc added this symbol in
  # 2.18). Rather than a pure no-op (which would silently drop every registered
  # thread_local destructor -- a real correctness gap since the shipped zig binary is
  # a genuinely multi-threaded, long-running process, unlike pthread_atfork above where
  # zig simply never calls fork()), this queues each (dtor, obj) pair and runs them all
  # via a single atexit() handler in LIFO order -- a deliberate approximation of the
  # real glibc per-thread-exit semantics: destructors run once, in the right order,
  # with a still-valid process image, but deferred to process exit rather than
  # immediate thread exit.

  local arch_name="${1}"
  local cc_compiler="${2}"
  local output_dir="${3:-${SRC_DIR}}"

  dbg echo "Creating __cxa_thread_atexit_impl stub for glibc < 2.18 ${arch_name}"

  cat > "${output_dir}/cxa_thread_atexit_impl_stub.c" << 'EOF'
// Weak stub for __cxa_thread_atexit_impl when targeting glibc < 2.18
// (Itanium C++ ABI thread_local destructor registration; glibc added this
// symbol in 2.18). See create_cxa_thread_atexit_impl_stub() in _atfork.sh
// for the full rationale.
//
// Rather than a pure no-op (which would silently drop every registered
// thread_local destructor -- a real correctness gap, not just a missed
// optimization), this queues each (dtor, obj) pair and runs them all via
// a single atexit() handler in LIFO order. This is a deliberate
// approximation of the real glibc per-thread-exit semantics: destructors
// run once, in the right order, with a still-valid process image, but
// deferred to process exit rather than immediate thread exit.
#include <stdlib.h>
#include <pthread.h>

struct cxa_thread_dtor_entry {
    void (*dtor)(void *);
    void *obj;
    struct cxa_thread_dtor_entry *next;
};

static pthread_mutex_t cxa_thread_dtor_lock = PTHREAD_MUTEX_INITIALIZER;
static struct cxa_thread_dtor_entry *cxa_thread_dtor_list = NULL;
static int cxa_thread_dtor_atexit_registered = 0;

static void run_cxa_thread_dtors(void) {
    pthread_mutex_lock(&cxa_thread_dtor_lock);
    struct cxa_thread_dtor_entry *entry = cxa_thread_dtor_list;
    cxa_thread_dtor_list = NULL;
    pthread_mutex_unlock(&cxa_thread_dtor_lock);

    while (entry != NULL) {
        struct cxa_thread_dtor_entry *next = entry->next;
        entry->dtor(entry->obj);
        free(entry);
        entry = next;
    }
}

__attribute__((weak))
int __cxa_thread_atexit_impl(void (*dtor)(void *), void *obj, void *dso_symbol) {
    (void)dso_symbol;  // Statically-linked binary: no DSO-unload cleanup to do

    struct cxa_thread_dtor_entry *entry =
        (struct cxa_thread_dtor_entry *)malloc(sizeof(*entry));
    if (entry == NULL) {
        return -1;  // Match the glibc OOM failure contract
    }
    entry->dtor = dtor;
    entry->obj = obj;

    pthread_mutex_lock(&cxa_thread_dtor_lock);
    entry->next = cxa_thread_dtor_list;
    cxa_thread_dtor_list = entry;  // LIFO: matches __cxa_atexit ordering
    if (!cxa_thread_dtor_atexit_registered) {
        cxa_thread_dtor_atexit_registered = 1;
        atexit(run_cxa_thread_dtors);
    }
    pthread_mutex_unlock(&cxa_thread_dtor_lock);

    return 0;  // Success
}
EOF

  _compile_stub_object "${cc_compiler}" "${output_dir}/cxa_thread_atexit_impl_stub.c" "${output_dir}/cxa_thread_atexit_impl_stub.o" "cxa_thread_atexit_impl" || return 1

  dbg echo "__cxa_thread_atexit_impl stub created: ${output_dir}/cxa_thread_atexit_impl_stub.o"
  return 0
}
