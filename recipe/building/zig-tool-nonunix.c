/*
 * non-unix simple tool wrapper: prepends configured args to argv and execs zig.
 *
 * Compiled once per tool at install time with different @ZIG_PREFIX_ARGS@:
 *   zig-ar.exe      args = { "ar" }
 *   zig-ranlib.exe  args = { "ranlib" }
 *   zig-rc.exe      args = { "rc" }
 *   zig-lld.exe     args = { "lld-link" }
 *   zig-asm.exe     args = { "cc", "-target", "<triplet>", "-mcpu=baseline" }
 *
 * No flag filtering. Mirrors the MSYS2 PATH and ZIG_GLOBAL_CACHE_DIR
 * setup from zig-cc-nonunix.c so behavior is identical to those shims.
 *
 * Placeholders replaced at install time:
 *   ZIG_BIN_NAME     - zig binary filename (e.g. x86_64-w64-mingw32-zig.exe)
 *   ZIG_PREFIX_ARGS  - C array initializer fragment of prepended args
 *
 * Compiled during package build with zig cc (same as zig-cc-nonunix.c).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <process.h>
#include <windows.h>

#define ZIG_BIN_NAME "@ZIG_BIN_NAME@"

static const char *PREFIX_ARGS[] = { @ZIG_PREFIX_ARGS@ };
static const size_t PREFIX_ARGS_COUNT = sizeof(PREFIX_ARGS) / sizeof(PREFIX_ARGS[0]);

static int find_zig(char *out, size_t out_size) {
    const char *conda = getenv("CONDA_PREFIX");
    if (conda && conda[0]) {
        snprintf(out, out_size, "%s\\Library\\bin\\%s", conda, ZIG_BIN_NAME);
        if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES)
            return 1;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    /* Ensure ZIG_GLOBAL_CACHE_DIR is set (mirrors zig-cc-nonunix.c). */
    if (!getenv("ZIG_GLOBAL_CACHE_DIR")) {
        char base[MAX_PATH];
        const char *appdata = getenv("APPDATA");
        const char *userprofile = getenv("USERPROFILE");
        if (appdata) {
            snprintf(base, MAX_PATH, "%s\\zig\\zig-cache", appdata);
        } else if (userprofile) {
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

    /* Find zig binary. */
    char zig_path[MAX_PATH];
    if (!find_zig(zig_path, MAX_PATH)) {
        fprintf(stderr, "ERROR: zig-tool: zig binary not found (%s)\n", ZIG_BIN_NAME);
        fprintf(stderr, "  CONDA_PREFIX=%s\n",
                getenv("CONDA_PREFIX") ? getenv("CONDA_PREFIX") : "(unset)");
        return 1;
    }

    /* Build new argv: zig_path PREFIX_ARGS... argv[1..argc-1] NULL */
    int new_argc = 1 + (int)PREFIX_ARGS_COUNT + (argc - 1);
    const char **new_argv = malloc(sizeof(char *) * (new_argc + 1));
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-tool: malloc failed\n");
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;
    for (size_t i = 0; i < PREFIX_ARGS_COUNT; i++)
        new_argv[ni++] = PREFIX_ARGS[i];
    for (int i = 1; i < argc; i++)
        new_argv[ni++] = argv[i];
    new_argv[ni] = NULL;

    /* MSYS2 strips System32 from PATH; restore it so UCRT DLLs resolve. */
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

    /* Execute zig. */
    int ret = (int)_spawnv(_P_WAIT, zig_path, new_argv);
    free(new_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: zig-tool: failed to exec %s: %s\n",
                zig_path, strerror(errno));
        return 1;
    }
    return ret;
}
