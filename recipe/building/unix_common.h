/*
 * unix_common.h - shared helpers for unix C shims.
 *
 * Included by the unix wrapper shim.
 * All functions are static inline so no shared state or linkage issues arise.
 *
 * Mirrors nonunix_common.h but for POSIX: setenv() rather than _putenv(),
 * execv() rather than the Windows spawn path, and zig's Linux getAppDataDir()
 * resolution (XDG_DATA_HOME > HOME/.local/share) rather than APPDATA.
 */

#ifndef UNIX_COMMON_H
#define UNIX_COMMON_H

/* setenv() is POSIX, not ISO C.  Under a strict -std=cNN build glibc sets
 * __STRICT_ANSI__ and hides it behind a feature macro, producing an implicit
 * declaration -- a hard ERROR on clang >= 16, which zig cc is built on.
 * Production currently compiles without -std= (gnu dialect, _DEFAULT_SOURCE
 * implied) so only strict builds bite, but request POSIX 2008 explicitly so
 * both work.  getuid() needs no such request: glibc guards it under
 * __USE_POSIX, which stays on.  realpath() is guarded differently -- glibc
 * requires __USE_MISC or __USE_XOPEN_EXTENDED, neither of which
 * _POSIX_C_SOURCE alone implies, so it hits the same warning-on-gcc /
 * hard-error-on-clang>=16 class as setenv() unless _XOPEN_SOURCE 700 is
 * also requested (XSI extras plus POSIX.1-2008).
 *
 * This MUST precede every system header, so this header is deliberately
 * included FIRST in zig-cc-unix.c (:33).  Keep it that way.
 * _DARWIN_C_SOURCE restores the BSD extras that _POSIX_C_SOURCE alone hides
 * on macOS. */
#if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif
#if !defined(_XOPEN_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#  define _XOPEN_SOURCE 700
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#  define _DARWIN_C_SOURCE
#endif

/* zig_self_path() needs uint32_t and _NSGetExecutablePath on macOS. */
#include <stdint.h>
#if defined(__APPLE__)
#  include <mach-o/dyld.h>
#endif

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* Ensure zig can resolve its cache directory.
 * zig's global cache resolves as: ZIG_GLOBAL_CACHE_DIR (explicit) >
 * std.fs.getAppDataDir("zig")/zig-cache, where getAppDataDir on Linux checks
 * XDG_DATA_HOME then HOME/.local/share.  If neither is set, zig panics with
 * AppDataDirUnavailable.  Always set ZIG_GLOBAL_CACHE_DIR if unset, mirroring
 * zig's own resolution so the variable is always populated before exec.
 *
 * C equivalent of recipe/scripts/_zig-cache-common.sh -- the two must stay in
 * step until the bash wrappers are retired. */
static inline void init_zig_global_cache_dir(void) {
    if (getenv("ZIG_GLOBAL_CACHE_DIR"))
        return;

    char base[PATH_MAX];
    const char *xdg = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");
    int n = -1;

    if (xdg && *xdg) {
        n = snprintf(base, sizeof base, "%s/zig/zig-cache", xdg);
    } else if (home && *home) {
        n = snprintf(base, sizeof base, "%s/.local/share/zig/zig-cache", home);
    }

    /* Either no XDG_DATA_HOME/HOME, or the path truncated.  Fall back to
     * TMPDIR, which is short enough that truncation is not a practical
     * concern.  A TRUNCATED path must never be exported: it would silently
     * point zig's cache at the wrong directory, which is worse than the
     * AppDataDirUnavailable panic this function exists to prevent.  Matches
     * the checked idiom already used by zig_resolve_sysroot below.
     *
     * Note this is a deliberate divergence from _zig-cache-common.sh: bash has
     * no fixed-size buffers and so cannot truncate. */
    if (n <= 0 || (size_t)n >= sizeof base) {
        const char *tmp = getenv("TMPDIR");
        if (!tmp || !*tmp)
            tmp = "/tmp";
        n = snprintf(base, sizeof base, "%s/zig-cache-%u", tmp, (unsigned)getuid());
        if (n <= 0 || (size_t)n >= sizeof base)
            return;
    }

    setenv("ZIG_GLOBAL_CACHE_DIR", base, 0);
}

/* Returns non-zero iff path is non-NULL, non-empty, and names a directory. */
static inline int zig_sysroot_is_dir(const char *path) {
    struct stat st;
    if (!path || !*path)
        return 0;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* C mirror of recipe/scripts/_zig-cc-common.sh:29-38 -- the two must stay in
 * step until the bash wrappers are retired.
 *
 * The return value is exactly what bash leaves in its _sr global, and is
 * what feeds zig_translate_profile.sysroot for R12 (-print-sysroot).
 * Callers must use zig_sysroot_is_dir() separately to decide on -isysroot/-L
 * injection, because R12 prints the value even when it is not a directory. */
static inline const char *zig_resolve_sysroot(const char *conda_prefix,
                                              const char *target_arch,
                                              int target_is_native) {
#ifdef __linux__
    if (target_is_native)
        return "";

    static char buf[PATH_MAX];
    const char *prefix = conda_prefix ? conda_prefix : "";
    const char *arch = target_arch ? target_arch : "";
    int n = snprintf(buf, sizeof buf, "%s/%s-conda-linux-gnu/sysroot",
                      prefix, arch);
    if (n > 0 && (size_t)n < sizeof buf && zig_sysroot_is_dir(buf))
        return buf;

    const char *cbs = getenv("CONDA_BUILD_SYSROOT");
    if (!cbs || !*cbs)
        return "";
    /* Copy out of the environment: setenv() elsewhere in this header may
     * reallocate environ and invalidate getenv()'s pointer, so the returned
     * string must not alias it. */
    int m = snprintf(buf, sizeof buf, "%s", cbs);
    if (m < 0 || (size_t)m >= sizeof buf)
        return "";   /* pathologically long value -- treat as unset */
    return buf;
#else
    (void)conda_prefix;
    (void)target_arch;
    (void)target_is_native;
    return "";
#endif
}

/* Absolute path of the running executable, written to buf.  Returns 0 on
 * success, -1 if unavailable on this platform or the lookup failed.
 *
 * Model: zig-feedstock-0.15.2/recipe/building/zig-wrapper.c:303-345.  Only the
 * two POSIX arms are needed here (the Windows arm lives in nonunix_common.h).
 * On platforms with neither (e.g. the BSDs) this returns -1 and the caller
 * falls back to the install-time-baked path. */
static inline int zig_self_path(char *buf, size_t bufsz) {
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, bufsz - 1);
    if (n <= 0 || (size_t)n >= bufsz - 1)
        return -1;
    buf[n] = '\0';
    return 0;
#elif defined(__APPLE__)
    /* _NSGetExecutablePath may return a non-canonical path (symlinks, "..",
     * or a relative argv[0]-derived path), so canonicalize it. */
    char raw[PATH_MAX];
    uint32_t sz = (uint32_t)sizeof raw;
    if (_NSGetExecutablePath(raw, &sz) != 0)
        return -1;
    char resolved[PATH_MAX];
    if (!realpath(raw, resolved))
        return -1;
    size_t len = strlen(resolved);
    if (len >= bufsz)
        return -1;
    memcpy(buf, resolved, len + 1);
    return 0;
#else
    (void)buf;
    (void)bufsz;
    return -1;
#endif
}

/* Resolve the zig binary to exec.
 *
 * WHY THIS EXISTS.  install_zig_activation.py's _find_zig_bin() bakes the
 * LITERAL string "${CONDA_PREFIX}/bin/<triplet>-zig" into @ZIG_BIN@.  That
 * works for the bash wrappers because bash expands ${CONDA_PREFIX} at exec
 * time; a C shim gets no such expansion and would execv() a path containing a
 * literal "${CONDA_PREFIX}" component.  The baked value therefore can never be
 * used verbatim -- a latent bug that went unnoticed only because the unix shim
 * was dead code until now.
 *
 * Resolution order:
 *   1. SELF-LOCATION (preferred, and relocation-proof).  Every wrapper is
 *      installed alongside zig itself as <dir>/<prefix>zig-<tool>, so zig is
 *      at <dir>/<prefix>zig.  This needs no environment at all and survives
 *      conda's prefix rewriting -- what the Relocation section of
 *      WRAPPER_C_PORT_SCOPE.md asks for.
 *   2. ${CONDA_PREFIX} expansion of the baked template, for platforms where
 *      zig_self_path() is unavailable.
 *   3. The template verbatim -- reachable only if it never contained the
 *      placeholder, i.e. a future install path baking a real absolute path.
 *      Kept so that change needs no edit here.
 *
 * Returns a pointer to static storage; never NULL. */
static inline const char *zig_resolve_zig_bin(const char *baked,
                                              const char *wrapper_prefix) {
    static char buf[PATH_MAX];

    char self[PATH_MAX];
    if (zig_self_path(self, sizeof self) == 0) {
        char *slash = strrchr(self, '/');
        if (slash) {
            *slash = '\0';   /* self is now the containing directory */
            int n = snprintf(buf, sizeof buf, "%s/%szig", self, wrapper_prefix);
            if (n > 0 && (size_t)n < sizeof buf && access(buf, X_OK) == 0)
                return buf;
        }
    }

    static const char kPlaceholder[] = "${CONDA_PREFIX}";
    size_t plen = sizeof kPlaceholder - 1;
    if (strncmp(baked, kPlaceholder, plen) == 0) {
        const char *cp = getenv("CONDA_PREFIX");
        if (cp && *cp) {
            int n = snprintf(buf, sizeof buf, "%s%s", cp, baked + plen);
            if (n > 0 && (size_t)n < sizeof buf)
                return buf;
        }
    }

    return baked;
}

/* Replace this process with zig.  Returns only on failure. */
static inline int exec_zig(const char *zig_bin, char *const argv[]) {
    /* Test-observability hook: print the final argv instead of exec'ing. */
    const char *print_argv = getenv("ZIG_WRAPPER_PRINT_ARGV");
    if (print_argv && *print_argv && strcmp(print_argv, "0") != 0) {
        int i;
        for (i = 0; argv[i]; i++)
            printf("%s\n", argv[i]);
        exit(0);
    }

    execv(zig_bin, argv);
    fprintf(stderr, "%s: failed to exec %s: %s\n",
            argv[0] ? argv[0] : "zig-wrapper", zig_bin, strerror(errno));
    return 127;
}

#endif /* UNIX_COMMON_H */
