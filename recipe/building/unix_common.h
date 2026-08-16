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

    if (xdg && *xdg) {
        snprintf(base, sizeof base, "%s/zig/zig-cache", xdg);
    } else if (home && *home) {
        snprintf(base, sizeof base, "%s/.local/share/zig/zig-cache", home);
    } else {
        const char *tmp = getenv("TMPDIR");
        if (!tmp || !*tmp)
            tmp = "/tmp";
        snprintf(base, sizeof base, "%s/zig-cache-%u", tmp, (unsigned)getuid());
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

/* Replace this process with zig.  Returns only on failure. */
static inline int exec_zig(const char *zig_bin, char *const argv[]) {
    execv(zig_bin, argv);
    fprintf(stderr, "%s: failed to exec %s: %s\n",
            argv[0] ? argv[0] : "zig-wrapper", zig_bin, strerror(errno));
    return 127;
}

#endif /* UNIX_COMMON_H */
