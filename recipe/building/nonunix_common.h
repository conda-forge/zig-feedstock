/*
 * nonunix_common.h - shared helpers for non-unix C shims.
 *
 * Included by zig-cc-nonunix.c and zig-tool-nonunix.c.
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

#endif /* NONUNIX_COMMON_H */
