/*
 * nonunix_common.h - shared helpers for non-unix C shims.
 *
 * Included by zig-cc-nonunix.c, zig-tool-nonunix.c and zig-windres-nonunix.c.
 * All functions are static inline so no shared state or linkage issues arise.
 */

#ifndef NONUNIX_COMMON_H
#define NONUNIX_COMMON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

/* Ensure zig can resolve its cache directory.
 * ZIG_GLOBAL_CACHE_DIR overrides zig's getAppDataDir() lookup entirely.
 * Always set it if unset: mirrors zig's resolution (APPDATA > USERPROFILE
 * > GetTempPath fallback) so the variable is always populated before exec.
 * This prevents AppDataDirUnavailable even when APPDATA is set but zig's
 * internal resolution fails for any reason. */
static inline void init_zig_global_cache_dir(void) {
    if (!getenv("ZIG_GLOBAL_CACHE_DIR")) {
        char base[MAX_PATH];
        char shortdir[MAX_PATH];
        const char *appdata = getenv("APPDATA");
        const char *userprofile = getenv("USERPROFILE");
        /* zig panics with an integer overflow when ZIG_GLOBAL_CACHE_DIR is a
         * long path (conda-forge zig-feedstock PR#120). The long component is
         * always the user-profile dir (e.g. C:\Users\<long name>\AppData\
         * Roaming). Convert that existing directory to its 8.3 short form with
         * GetShortPathName (which only shortens path components that exist) and
         * append the short cache suffix, keeping the exported path short. Fall
         * back to the unshortened path if the API fails. */
        if (appdata) {
            if (GetShortPathNameA(appdata, shortdir, MAX_PATH) > 0)
                snprintf(base, MAX_PATH, "%s\\zig\\zig-cache", shortdir);
            else
                snprintf(base, MAX_PATH, "%s\\zig\\zig-cache", appdata);
        } else if (userprofile) {
            if (GetShortPathNameA(userprofile, shortdir, MAX_PATH) > 0)
                snprintf(base, MAX_PATH, "%s\\AppData\\Roaming\\zig\\zig-cache", shortdir);
            else
                snprintf(base, MAX_PATH, "%s\\AppData\\Roaming\\zig\\zig-cache", userprofile);
        } else {
            DWORD tmp_len = GetTempPathA(MAX_PATH, base);
            if (tmp_len > 0)
                snprintf(base + tmp_len - 1, MAX_PATH - tmp_len, "\\zig-cache");
        }
        char *env_val = malloc(strlen("ZIG_GLOBAL_CACHE_DIR=") + strlen(base) + 2);
        if (env_val) {
            sprintf(env_val, "ZIG_GLOBAL_CACHE_DIR=%s", base);
            _putenv(env_val);
            free(env_val);
        }
    }
}

/* MSYS2 strips C:\Windows\System32 from PATH, but zig-compiled binaries
 * link against UCRT (api-ms-win-crt-*.dll) which lives there. Ensure
 * System32 is in PATH so zig's linker and any child processes can find it. */
static inline void restore_msys2_system32_path(void) {
    if (getenv("MSYSTEM") != NULL) {
        const char *path = getenv("PATH");
        const char *sys32 = "C:\\Windows\\System32";
        if (path && !strstr(path, sys32)) {
            char *new_path = malloc(strlen(path) + strlen(sys32) + 7);
            if (new_path) {
                sprintf(new_path, "PATH=%s;%s", sys32, path);
                _putenv(new_path);
                free(new_path);
            }
        }
    }
}

/* Resolve <prefix>\Library\bin\<bin_name> against the env vars that may hold
 * the RUN env, returning the name of the var that matched or NULL.
 *
 * rattler-build spins up a separate BUILD env whenever a test block declares
 * `requirements: build:`; CONDA_PREFIX then points at that build env while the
 * package under test lives in PREFIX. Probe order and the existence check
 * mirror recipe/testing/_test_utils.py resolve_test_prefix() -- keep the two
 * in sync. The existence check is what makes PREFIX-first safe during the
 * build phase, where PREFIX may not hold zig at all. */
static inline const char *zig_find_in_prefixes(char *out, size_t out_size,
                                               const char *bin_name) {
    static const char *const VARS[] = { "PREFIX", "CONDA_PREFIX" };
    for (size_t i = 0; i < sizeof(VARS) / sizeof(VARS[0]); i++) {
        const char *base = getenv(VARS[i]);
        if (!base || !base[0])
            continue;
        snprintf(out, out_size, "%s\\Library\\bin\\%s", base, bin_name);
        if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES)
            return VARS[i];
    }
    return NULL;
}

/* Resolve which prefix actually contains <subpath>, PREFIX first, returning
 * that prefix (not the probed path). Same rationale as zig_find_in_prefixes():
 * a test block declaring `requirements: build:` moves CONDA_PREFIX to the test
 * build env while the package under test lives in PREFIX. The marker is the
 * subpath the caller goes on to consume, so the prefix chosen is one that
 * really has it; falling back to CONDA_PREFIX keeps lanes without build
 * requirements (and the build phase, where PREFIX may not hold zig yet)
 * working. Keep in sync with recipe/testing/_test_utils.py resolve_test_prefix(). */
static inline const char *zig_prefix_with_subpath(const char *subpath) {
    static const char *const VARS[] = { "PREFIX", "CONDA_PREFIX" };
    char probe[512];
    for (size_t i = 0; i < sizeof(VARS) / sizeof(VARS[0]); i++) {
        const char *base = getenv(VARS[i]);
        if (!base || !base[0])
            continue;
        snprintf(probe, sizeof(probe), "%s\\%s", base, subpath);
        if (GetFileAttributesA(probe) != INVALID_FILE_ATTRIBUTES)
            return base;
    }
    return getenv("CONDA_PREFIX");
}

#endif /* NONUNIX_COMMON_H */
