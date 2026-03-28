/*
 * non-unix compiler wrapper: invokes zig cc/c++ with flag filtering.
 *
 * Compiled twice at install time with different @ZIG_CC_MODE@:
 *   zig-cc.exe  (mode = "cc")
 *   zig-cxx.exe (mode = "c++")
 *
 * Filters out GCC/GNU ld flags that conda-build injects but zig's
 * lld-based linker rejects (-march, -fstack-protector, -Wl,-Bsymbolic, etc).
 * Port of the Unix _zig-cc-common.sh logic to compiled C.
 *
 * Placeholders replaced at install time:
 *   ZIG_CC_MODE    - "cc" or "c++"
 *   ZIG_BIN_NAME   - zig binary filename (e.g. x86_64-w64-mingw32-zig.exe)
 *   ZIG_TARGET     - zig target triplet (e.g. x86_64-windows-msvc)
 *
 * Compiled during package build with zig cc.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <windows.h>

#define ZIG_CC_MODE "@ZIG_CC_MODE@"
#define ZIG_BIN_NAME "@ZIG_BIN_NAME@"
#define ZIG_TARGET "@ZIG_TARGET@"

/* --- Flag classification helpers --- */
static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

/* -Xlinker passthrough flags to drop */
static int is_xlinker_drop(const char *arg) {
    return str_eq(arg, "-Bsymbolic-functions") ||
           str_eq(arg, "-Bsymbolic") ||
           str_eq(arg, "--color-diagnostics") ||
           starts_with(arg, "--dependency-file=");
}

/* -Wl,* flags to drop (entire arg) */
static int is_wl_drop(const char *arg) {
    if (!starts_with(arg, "-Wl,"))
        return 0;
    return starts_with(arg, "-Wl,-rpath-link") ||
           str_eq(arg, "-Wl,--disable-new-dtags") ||
           str_eq(arg, "-Wl,--allow-shlib-undefined") ||
           str_eq(arg, "-Wl,--no-allow-shlib-undefined") ||
           str_eq(arg, "-Wl,-Bsymbolic-functions") ||
           str_eq(arg, "-Wl,-Bsymbolic") ||
           str_eq(arg, "-Wl,--color-diagnostics") ||
           starts_with(arg, "-Wl,--version-script") ||
           starts_with(arg, "-Wl,-soname") ||
           starts_with(arg, "-Wl,-z,") ||
           starts_with(arg, "-Wl,-O") ||
           str_eq(arg, "-Wl,--gc-sections") ||
           str_eq(arg, "-Wl,--no-gc-sections") ||
           starts_with(arg, "-Wl,--build-id") ||
           str_eq(arg, "-Wl,--as-needed") ||
           str_eq(arg, "-Wl,--no-as-needed");
}

/* Standalone flags to drop */
static int is_drop_flag(const char *arg) {
    return starts_with(arg, "-march=") ||
           starts_with(arg, "-mtune=") ||
           starts_with(arg, "-mcpu=") ||
           str_eq(arg, "-ftree-vectorize") ||
           starts_with(arg, "-fstack-protector") ||
           str_eq(arg, "-fno-plt") ||
           starts_with(arg, "-fdebug-prefix-map=") ||
           starts_with(arg, "-stdlib=") ||
           str_eq(arg, "-Bsymbolic-functions") ||
           str_eq(arg, "-Bsymbolic");
}

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
    /* Find zig binary */
    char zig_path[MAX_PATH];
    if (!find_zig(zig_path, MAX_PATH)) {
        fprintf(stderr, "ERROR: zig-%s: zig binary not found (%s)\n",
                ZIG_CC_MODE, ZIG_BIN_NAME);
        fprintf(stderr, "  CONDA_PREFIX=%s\n",
                getenv("CONDA_PREFIX") ? getenv("CONDA_PREFIX") : "(unset)");
        return 1;
    }

    /* Allocate filtered args array (worst case: 1:1 with input) */
    const char **filtered = malloc(sizeof(char *) * (argc + 1));
    if (!filtered) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        return 1;
    }

    /* First pass: filter flags, detect -nostdlib++ */
    int fi = 0;
    int saw_nostdlibxx = 0;
    int grab_next = 0;

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];

        if (grab_next) {
            grab_next = 0;
            if (!is_xlinker_drop(arg)) {
                filtered[fi++] = "-Xlinker";
                filtered[fi++] = arg;
            }
            continue;
        }

        /* -Xlinker: grab next arg for inspection */
        if (str_eq(arg, "-Xlinker")) {
            grab_next = 1;
            continue;
        }

        /* -Wl,* drops */
        if (is_wl_drop(arg))
            continue;

        /* Standalone drops */
        if (is_drop_flag(arg))
            continue;

        /* -nostdlib++: downgrade mode from c++ to cc */
        if (str_eq(arg, "-nostdlib++")) {
            saw_nostdlibxx = 1;
            continue;
        }

        filtered[fi++] = arg;
    }

    /* Determine final mode */
    const char *mode = ZIG_CC_MODE;
    if (saw_nostdlibxx && str_eq(mode, "c++"))
        mode = "cc";

    /* Build final argv: zig mode -target TARGET -mcpu=baseline <filtered...> */
    int max_args = fi + 8;
    const char **new_argv = malloc(sizeof(char *) * max_args);
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        free(filtered);
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;
    new_argv[ni++] = mode;
    new_argv[ni++] = "-target";
    new_argv[ni++] = ZIG_TARGET;
    new_argv[ni++] = "-mcpu=baseline";

    for (int i = 0; i < fi; i++)
        new_argv[ni++] = filtered[i];

    new_argv[ni] = NULL;

    /* Execute zig */
    int ret = (int)_spawnv(_P_WAIT, zig_path, new_argv);
    free(filtered);
    free(new_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: zig-%s: failed to exec %s: %s\n",
                ZIG_CC_MODE, zig_path, strerror(errno));
        return 1;
    }
    return ret;
}
