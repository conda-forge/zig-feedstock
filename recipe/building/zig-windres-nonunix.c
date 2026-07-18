/*
 * non-unix windres wrapper: translates windres-style -o <out> to zig rc's -fo <out>
 * and forwards remaining args to `zig rc`.
 *
 * windres and zig rc both process Windows resource (.rc) files, but differ in
 * output flag naming: windres uses -o, zig rc uses -fo.
 *
 * Placeholder replaced at install time:
 *   ZIG_BIN_NAME   - zig binary filename (e.g. x86_64-w64-mingw32-zig.exe)
 *
 * Compiled during package build with zig cc.
 */

#include "nonunix_common.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <windows.h>

#define ZIG_BIN_NAME "@ZIG_BIN_NAME@"

/* --- Find zig binary --- */
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
    init_zig_global_cache_dir();

    /* Find zig binary */
    char zig_path[MAX_PATH];
    if (!find_zig(zig_path, MAX_PATH)) {
        fprintf(stderr, "ERROR: zig-windres: zig binary not found (%s)\n", ZIG_BIN_NAME);
        fprintf(stderr, "  CONDA_PREFIX=%s\n",
                getenv("CONDA_PREFIX") ? getenv("CONDA_PREFIX") : "(unset)");
        return 1;
    }

    /* Allocate new argv: zig_path + "rc" + translated user args + NULL sentinel.
     * Size (argc + 4) is safe: at most argc-1 user args, plus path, "rc", NULL. */
    const char **new_argv = malloc(sizeof(char *) * (argc + 4));
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-windres: malloc failed\n");
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;
    new_argv[ni++] = "rc";

    /* Translate user args: -o <X> -> -fo <X>, -o<X> -> -fo<X>, rest unchanged. */
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];

        if (strcmp(arg, "-o") == 0) {
            /* Two-arg form: -o followed by separate output path */
            new_argv[ni++] = "-fo";
            if (i + 1 < argc) {
                new_argv[ni++] = argv[++i];
            }
        } else if (strncmp(arg, "-o", 2) == 0 && arg[2] != '\0') {
            /* Concatenated form: -o<path> (no space) */
            size_t rest_len = strlen(arg) - 2;  /* length after "-o" */
            char *translated = malloc(3 + rest_len + 1);  /* "-fo" + rest + NUL */
            if (!translated) {
                fprintf(stderr, "ERROR: zig-windres: malloc failed\n");
                free(new_argv);
                return 1;
            }
            strcpy(translated, "-fo");
            strcat(translated, arg + 2);
            new_argv[ni++] = translated;
        } else {
            new_argv[ni++] = arg;
        }
    }

    new_argv[ni] = NULL;

    restore_msys2_system32_path();

    /* Execute zig rc */
    int ret = (int)_spawnv(_P_WAIT, zig_path, new_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: zig-windres: failed to exec %s: %s\n",
                zig_path, strerror(errno));
        free(new_argv);
        return 1;
    }
    free(new_argv);
    return ret;
}
