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

/* Translate conda triplets to zig target format.
 * Returns a static string or the input unchanged. */
static const char *conda_to_zig_target(const char *triplet) {
    if (starts_with(triplet, "x86_64-w64-mingw32"))  return "x86_64-windows-gnu";
    if (starts_with(triplet, "aarch64-w64-mingw32")) return "aarch64-windows-gnu";
    if (starts_with(triplet, "x86_64-apple-darwin"))  return "x86_64-macos-none";
    if (starts_with(triplet, "arm64-apple-darwin"))   return "aarch64-macos-none";
    /* *-conda-linux-gnu* -> *-linux-gnu (strip -conda-) */
    if (strstr(triplet, "-conda-linux-gnu")) {
        static char buf[256];
        const char *p = strstr(triplet, "-conda-linux-gnu");
        size_t prefix_len = p - triplet;
        snprintf(buf, sizeof(buf), "%.*s-linux-gnu", (int)prefix_len, triplet);
        return buf;
    }
    return triplet;  /* pass through as-is */
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
           str_eq(arg, "-ftree-vectorize") ||
           starts_with(arg, "-fstack-protector") ||
           str_eq(arg, "-fno-plt") ||
           starts_with(arg, "-fdebug-prefix-map=") ||
           starts_with(arg, "-stdlib=");
}

/* Flags that trigger auto-promotion to LLD (unsupported by self-hosted linker) */
static int is_lld_trigger(const char *arg) {
    if (str_eq(arg, "-fuse-ld=lld")) return 1;
    /* ELF flags (-Wl, prefixed) */
    if (starts_with(arg, "-Wl,--version-script")) return 1;
    if (starts_with(arg, "-Wl,--dynamic-list")) return 1;
    if (starts_with(arg, "-Wl,-z,defs") || starts_with(arg, "-Wl,-z,nodelete")) return 1;
    if (str_eq(arg, "-Wl,--gc-sections") || str_eq(arg, "-Wl,--no-gc-sections")) return 1;
    if (starts_with(arg, "-Wl,--build-id")) return 1;
    if (str_eq(arg, "-Wl,--allow-shlib-undefined") || str_eq(arg, "-Wl,--no-allow-shlib-undefined")) return 1;
    if (str_eq(arg, "-Wl,-Bsymbolic-functions") || str_eq(arg, "-Wl,-Bsymbolic")) return 1;
    if (str_eq(arg, "-Bsymbolic-functions") || str_eq(arg, "-Bsymbolic")) return 1;
    return 0;
}

/* Bare linker args that trigger LLD (passed via -Xlinker <arg>) */
static int is_xlinker_lld_trigger(const char *arg) {
    if (starts_with(arg, "--dynamic-list") || starts_with(arg, "--version-script")) return 1;
    if (str_eq(arg, "--gc-sections") || str_eq(arg, "--no-gc-sections")) return 1;
    if (starts_with(arg, "--build-id")) return 1;
    if (str_eq(arg, "--allow-shlib-undefined") || str_eq(arg, "--no-allow-shlib-undefined")) return 1;
    if (starts_with(arg, "-exported_symbols_list") || starts_with(arg, "-unexported_symbols_list")) return 1;
    if (str_eq(arg, "-all_load") || starts_with(arg, "-force_load")) return 1;
    return 0;
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

/* --- Handle -print-search-dirs (GCC compat for flexlink/mingw_libs) ---
 * zig doesn't implement this flag. flexlink calls it to discover library
 * search paths before resolving -lXXX arguments. Without a response,
 * flexlink has no search paths and treats -lws2_32 as a literal filename.
 * We return paths to zig's pre-generated MinGW import libraries.
 */
static int handle_print_search_dirs(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (str_eq(argv[i], "-print-search-dirs")) {
            const char *conda = getenv("CONDA_PREFIX");
            if (conda && conda[0]) {
                /* lib-common: MinGW import libs (libws2_32.a, libole32.a, etc.)
                 * lib-x86_64: arch-specific import libs
                 * lib: zig compiler runtime libs */
                printf("install: %s\\Library\\lib\\zig\\\n", conda);
                printf("programs: =%s\\Library\\bin\\\n", conda);
                printf("libraries: =%s\\Library\\lib\\zig\\libc\\mingw\\lib-common;%s\\Library\\lib\\zig\\libc\\mingw\\lib-x86_64;%s\\Library\\lib\\zig\n",
                       conda, conda, conda);
            } else {
                printf("install: \nprograms: =\nlibraries: =\n");
            }
            return 1;
        }
    }
    return 0;
}

/* --- Handle -print-file-name=<name> (GCC/Clang compat) ---
 * zig doesn't support this flag. Probe zig-llvm/lib then lib under
 * CONDA_PREFIX, print the path if found (or echo back the name), and exit.
 */
static int handle_print_file_name(int argc, char *argv[]) {
    const char *prefix = "-print-file-name=";
    size_t plen = strlen(prefix);

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], prefix, plen) == 0) {
            const char *name = argv[i] + plen;
            const char *conda = getenv("CONDA_PREFIX");
            if (conda && conda[0]) {
                char probe[MAX_PATH];
                const char *dirs[] = {"Library\\lib\\zig-llvm\\lib", "Library\\lib"};
                for (int d = 0; d < 2; d++) {
                    snprintf(probe, MAX_PATH, "%s\\%s\\%s", conda, dirs[d], name);
                    if (GetFileAttributesA(probe) != INVALID_FILE_ATTRIBUTES) {
                        printf("%s\n", probe);
                        return 1;
                    }
                }
            }
            printf("%s\n", name);
            return 1;
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    /* Ensure zig can resolve its cache directory.
     * ZIG_GLOBAL_CACHE_DIR overrides zig's getAppDataDir() lookup entirely.
     * Always set it if unset: mirrors zig's resolution (APPDATA > USERPROFILE
     * > GetTempPath fallback) so the variable is always populated before exec.
     * This prevents AppDataDirUnavailable even when APPDATA is set but zig's
     * internal resolution fails for any reason. */
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

    /* Handle -print-search-dirs and -print-file-name before anything else */
    if (handle_print_search_dirs(argc, argv))
        return 0;
    if (handle_print_file_name(argc, argv))
        return 0;

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

    /* Pre-scan: detect LLD-triggering flags, user overrides, and translate targets */
    int use_lld = 0;
    int has_target = 0;
    int has_mcpu = 0;
    for (int i = 1; i < argc; i++) {
        if (is_lld_trigger(argv[i])) use_lld = 1;
        /* -Xlinker <arg>: check the following arg for bare LLD triggers */
        if (str_eq(argv[i], "-Xlinker") && i + 1 < argc) {
            if (is_xlinker_lld_trigger(argv[i + 1])) use_lld = 1;
        }
        if (str_eq(argv[i], "-target")) {
            has_target = 1;
            /* Translate the next arg (the target value) */
            if (i + 1 < argc)
                argv[i + 1] = (char *)conda_to_zig_target(argv[i + 1]);
        }
        if (starts_with(argv[i], "--target=")) {
            has_target = 1;
            /* Translate inline target value */
            const char *val = argv[i] + 9; /* strlen("--target=") */
            const char *translated = conda_to_zig_target(val);
            if (translated != val) {
                static char target_buf[280];
                snprintf(target_buf, sizeof(target_buf), "--target=%s", translated);
                argv[i] = target_buf;
            }
        }
        if (starts_with(argv[i], "-mcpu=")) has_mcpu = 1;
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

        /* -Wl,* drops -- skip if LLD promoted (LLD handles these) */
        if (!use_lld && is_wl_drop(arg))
            continue;

        /* Standalone drops */
        if (is_drop_flag(arg))
            continue;

        /* -nostdlib++: downgrade mode from c++ to cc */
        if (str_eq(arg, "-nostdlib++")) {
            saw_nostdlibxx = 1;
            continue;
        }

        /* Skip -fuse-ld=lld from filtered (we inject it ourselves) */
        if (str_eq(arg, "-fuse-ld=lld"))
            continue;

        filtered[fi++] = arg;
    }

    /* Determine final mode */
    const char *mode = ZIG_CC_MODE;
    if (saw_nostdlibxx && str_eq(mode, "c++"))
        mode = "cc";

    /* Build final argv: zig mode [-fuse-ld=lld] -target TARGET -mcpu=baseline <filtered...> */
    int max_args = fi + 10;
    const char **new_argv = malloc(sizeof(char *) * max_args);
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        free(filtered);
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;
    new_argv[ni++] = mode;
    if (use_lld)
        new_argv[ni++] = "-fuse-ld=lld";
    if (!has_target) {
        new_argv[ni++] = "-target";
        new_argv[ni++] = ZIG_TARGET;
    }
    if (!has_mcpu)
        new_argv[ni++] = "-mcpu=baseline";

    for (int i = 0; i < fi; i++)
        new_argv[ni++] = filtered[i];

    new_argv[ni] = NULL;

    /* MSYS2 strips C:\Windows\System32 from PATH, but zig-compiled binaries
     * link against UCRT (api-ms-win-crt-*.dll) which lives there. Ensure
     * System32 is in PATH so zig's linker and any child processes can find it. */
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
