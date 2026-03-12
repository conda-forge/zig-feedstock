/*
 * Cross-compiler .exe shim for zig on Windows.
 *
 * Replaces .bat/.cmd wrappers that cause issues with CMake's compiler
 * detection. Injects -target flag based on the subcommand:
 *   cc/c++         -> -target CC_TRIPLET  (glibc version stripped)
 *   build-exe/etc  -> -target ZIG_TRIPLET (full triplet)
 *   other          -> passthrough
 *
 * Placeholders replaced at install time:
 *   NATIVE_ZIG_EXE  - filename of the native zig binary (e.g. x86_64-w64-mingw32-zig.exe)
 *   CC_TRIPLET      - target for cc/c++ (e.g. aarch64-windows-msvc)
 *   ZIG_TRIPLET     - target for zig commands (e.g. aarch64-windows-msvc)
 *
 * Compiled during package build:
 *   cl /Fe:target-zig.exe cross-zig-shim.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <windows.h>

/* These are replaced by the install script */
#define NATIVE_ZIG_EXE "@NATIVE_ZIG_EXE@"
#define CC_TRIPLET "@CC_TRIPLET@"
#define ZIG_TRIPLET "@ZIG_TRIPLET@"

static int str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

static int needs_cc_target(const char *cmd) {
    return str_eq(cmd, "cc") || str_eq(cmd, "c++");
}

static int needs_zig_target(const char *cmd) {
    return str_eq(cmd, "build-exe") || str_eq(cmd, "build-lib") ||
           str_eq(cmd, "build-obj") || str_eq(cmd, "test") ||
           str_eq(cmd, "run") || str_eq(cmd, "translate-c");
}

int main(int argc, char *argv[]) {
    /* Find native zig relative to this exe's directory */
    char self_path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, self_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        fprintf(stderr, "ERROR: cross-zig-shim: cannot determine own path\n");
        return 1;
    }

    /* Replace last path component with native zig exe name */
    char *last_sep = strrchr(self_path, '\\');
    if (!last_sep) last_sep = strrchr(self_path, '/');
    if (!last_sep) {
        fprintf(stderr, "ERROR: cross-zig-shim: cannot parse own path\n");
        return 1;
    }
    *(last_sep + 1) = '\0';

    char zig_path[MAX_PATH];
    snprintf(zig_path, MAX_PATH, "%s%s", self_path, NATIVE_ZIG_EXE);

    /*
     * Build new argv:
     *   - If cmd is cc/c++: zig_path cmd -target CC_TRIPLET [rest...]
     *   - If cmd is build-*: zig_path cmd -target ZIG_TRIPLET [rest...]
     *   - Otherwise: zig_path [all args...]
     */

    /* Max new args = original args + 3 extra (-target, triplet, NULL) */
    const char **new_argv = malloc(sizeof(char *) * (argc + 4));
    if (!new_argv) {
        fprintf(stderr, "ERROR: cross-zig-shim: malloc failed\n");
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;

    if (argc > 1) {
        const char *cmd = argv[1];
        if (needs_cc_target(cmd)) {
            new_argv[ni++] = cmd;
            new_argv[ni++] = "-target";
            new_argv[ni++] = CC_TRIPLET;
            for (int i = 2; i < argc; i++)
                new_argv[ni++] = argv[i];
        } else if (needs_zig_target(cmd)) {
            new_argv[ni++] = cmd;
            new_argv[ni++] = "-target";
            new_argv[ni++] = ZIG_TRIPLET;
            for (int i = 2; i < argc; i++)
                new_argv[ni++] = argv[i];
        } else {
            for (int i = 1; i < argc; i++)
                new_argv[ni++] = argv[i];
        }
    }
    new_argv[ni] = NULL;

    /* _spawnv replaces this process, returns exit code */
    int ret = (int)_spawnv(_P_WAIT, zig_path, new_argv);
    free(new_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: cross-zig-shim: failed to exec %s: %s\n",
                zig_path, strerror(errno));
        return 1;
    }
    return ret;
}
