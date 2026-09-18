# Post-CMake config.h patch chain: appends missing link deps (zstd/xml2/z), fixes
# BUILD_PREFIX->PREFIX paths for osx cross, and (linux, real sysroot) injects the
# glibc 2.17 syscall-stub object. Perl substitutions are SEQUENTIAL - order matters.
# Requires: cmake_build_dir, CC, ZIG_LOCAL_CACHE_DIR, CONDA_BUILD_SYSROOT, RECIPE_DIR.

# --- Post CMake Configuration ---

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
# Append LLVM deps that conda's split packaging doesn't bake into
# config.h's ZIG_LLVM_LIBRARIES: zlib (adler32 refs in lld-ELF),
# zstd (compression), libxml2. Needed on every native + cross linux
# build -- linux-aarch64 failed linking zig2 with undefined adler32
# when this was gated on `is_cross`.
is_linux && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
# Note: do NOT inject ${PREFIX}/lib/libc++.dylib into ZIG_LLVM_LIBRARIES on macOS.
# build.zig sets mod.link_libcpp = true for darwin targets, which (via patches/
# Lld.zig-prefer-shared-libcxx.patch) already resolves to ${PREFIX}/lib/libc++.1.dylib.
# Injecting libc++.dylib here would add a second LC_LOAD_DYLIB to the same dylib;
# macOS SDK >= 26 dyld aborts on duplicate linked dylibs ("duplicate linked dylib
# '@rpath/libc++.1.dylib'" -- Abort trap: 6).

# zig2.c (the pre-generated C bootstrap from 0.16) calls getrandom,
# copy_file_range, and statx -- all absent from conda-forge's glibc 2.17
# sysroot. Compile weak-symbol syscall() stubs and inject the .o into
# both the zig-build path (via config.h's ZIG_LLVM_LIBRARIES) and the
# CMake fallback path (via cmake/0002 target_link_libraries).
# Guard on CONDA_BUILD_SYSROOT: outside conda-forge CI (e.g. local
# dev with a modern glibc system), the stubs aren't needed.
if is_linux && [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
  source "${RECIPE_DIR}/building/_glibc217_syscall_stubs.sh"
  create_glibc217_syscall_stubs "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/glibc217_syscall_stubs.o\"|g" "${cmake_build_dir}/config.h"
fi

dbg echo "=== config.h (ZIG_/LLVM_ keys) ==="
dbg grep -E '^#define (ZIG_|LLVM_)' "${cmake_build_dir}"/config.h
dbg echo "=== end config.h ==="
