/* zig-wrapper.c - unified wrapper for zig-feedstock
 *
 * Replaces cross-zig-shim.c and zig-cc-nonunix.c with single source.
 * Mode determined by basename(argv[0]):
 *   ${triplet}-zig              -> DISPATCH (argv[1] is subcommand)
 *   ${triplet}-zig-cc           -> CC mode  (force argv[1]="cc", filter + inject -target)
 *   ${triplet}-zig-cxx          -> CXX mode
 *   ${triplet}-zig-c++          -> CXX mode (alternate name)
 *   ${triplet}-zig-force-load-cc  -> CC mode + archive extraction for -all_load/-force_load
 *   ${triplet}-zig-force-load-cxx -> CXX mode + archive extraction for -all_load/-force_load
 *   ${triplet}-zig-ar           -> AR
 *   ${triplet}-zig-ranlib       -> RANLIB
 *   ${triplet}-zig-lld          -> LLD (lld-link on Windows, ld.lld on Unix)
 *   ${triplet}-zig-rc           -> RC
 *   ${triplet}-zig-asm          -> ASM (force "as")
 *
 * Compile-time substitutions (placeholder strings replaced at install time):
 *   @ZIG_TARGET@      target triplet for -target injection
 *   @ZIG_REAL_PATH@   absolute path to the real zig binary (e.g. PREFIX/Library/share/zig/zig-real.exe)
 *                     -- if this is "" at runtime, fall back to relative-to-self lookup
 *
 * Runtime env:
 *   ZIG_WRAPPER_DEBUG=1   emit [zig-wrapper] trace lines to stderr
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include "wrapper_utils.h"

#ifdef _WIN32
#  include <process.h>
#  include <windows.h>
#  define PATH_SEP '\\'
#  define MAX_PATH_LEN MAX_PATH
#  define LLD_SUBCOMMAND "lld-link"
#  define ASM_SUBCOMMAND "as"
#  define ZIG_REAL_DEFAULT "zig-real.exe"
#else
#  include <unistd.h>
#  include <limits.h>
#  include <sys/stat.h>
#  include <sys/types.h>
#  include <sys/wait.h>
#  include <dirent.h>
#  ifndef PATH_MAX
#    define PATH_MAX 4096
#  endif
#  define PATH_SEP '/'
#  define MAX_PATH_LEN PATH_MAX
#  define LLD_SUBCOMMAND "ld.lld"
#  define ASM_SUBCOMMAND "as"
#  define ZIG_REAL_DEFAULT "zig-real"
#endif

#ifdef _WIN32
#  include <io.h>      /* _access */
#  include <stdlib.h>  /* _fullpath */
#  define access(p, m) _access((p), (m))
#  define R_OK 4
#  define realpath(p, r) _fullpath((r), (p), PATH_MAX)
#endif

#ifdef __APPLE__
#  include <mach-o/dyld.h>
#endif

#define ZIG_TARGET      "@ZIG_TARGET@"
#define ZIG_REAL_PATH   "@ZIG_REAL_PATH@"

/* build-29 item 1: -print-search-dirs arch dispatch */
#if defined(__aarch64__) || defined(_M_ARM64)
#  define HOST_DEFAULT_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#  define HOST_DEFAULT_ARCH "x86_64"
#elif defined(__i386__) || defined(_M_IX86)
#  define HOST_DEFAULT_ARCH "i386"
#elif defined(__riscv) && (__riscv_xlen == 64)
#  define HOST_DEFAULT_ARCH "riscv64"
#else
#  define HOST_DEFAULT_ARCH "x86_64"  /* conservative fallback */
#endif

static const struct {
    const char *prefix;
    const char *arch_dir;
} TARGET_ARCH_MAP[] = {
    {"aarch64-", "aarch64"},
    {"arm64-",   "aarch64"},
    {"x86_64-",  "x86_64"},
    {"amd64-",   "x86_64"},
    {"i386-",    "i386"},
    {"i686-",    "i386"},
    {"riscv64-", "riscv64"},
    {NULL, NULL}
};

typedef enum {
    MODE_DISPATCH,
    MODE_CC,
    MODE_CXX,
    MODE_FORCE_LOAD_CC,
    MODE_FORCE_LOAD_CXX,
    MODE_AR,
    MODE_RANLIB,
    MODE_LLD,
    MODE_RC,
    MODE_ASM,
    MODE_UNKNOWN
} wrapper_mode_t;

static int debug_enabled = 0;

#define DBG(...) do { if (debug_enabled) { fprintf(stderr, "[zig-wrapper] " __VA_ARGS__); } } while (0)

/* --- string helpers --- */
static int starts_with(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }
static int ends_with(const char *s, const char *suffix) {
    size_t sl = strlen(s), pl = strlen(suffix);
    return sl >= pl && strcmp(s + sl - pl, suffix) == 0;
}

/* Build a "-Wl,<prefix><value>" string for MSVC/lld-link linker options
   (e.g. prefix="/STACK:" value="0x100000" -> "-Wl,/STACK:0x100000").
   Allocates process-lifetime memory; never freed (same idiom as P-3 -e->/ENTRY). */
static char *make_wl_msvc(const char *prefix, const char *value) {
    size_t pl = strlen(prefix), vl = strlen(value);
    char *r = (char *)malloc(4 + pl + vl + 1); /* "-Wl," + prefix + value + NUL */
    if (!r) { perror("zig-wrapper: malloc"); exit(1); }
    memcpy(r, "-Wl,", 4);
    memcpy(r + 4, prefix, pl);
    memcpy(r + 4 + pl, value, vl + 1);
    return r;
}

/* --- filter helpers (CC/CXX modes only) --- */
static int is_drop_flag(const char *arg) {
    return starts_with(arg, "-march=")
        || starts_with(arg, "-mtune=")
        || starts_with(arg, "-mcpu=")
        || str_eq(arg, "-ftree-vectorize")
        || starts_with(arg, "-fstack-protector")
        || str_eq(arg, "-fno-plt")
        || starts_with(arg, "-fdebug-prefix-map=")
        || starts_with(arg, "-stdlib=")
        || str_eq(arg, "-lgcc_eh")
        || str_eq(arg, "-lgcc_s");
}

/* -Xlinker passthrough flags to drop (bare, passed after -Xlinker <arg>).
 * NOTE: --color-diagnostics is NOT listed here; it is LLD-conditional (see
 * grab_next handler in do_filter loop) to match the -Wl,--color-diagnostics
 * behaviour in is_wl_drop (dropped only when !use_lld). */
static int is_xlinker_drop(const char *arg) {
    return str_eq(arg, "-Bsymbolic-functions")
        || str_eq(arg, "-Bsymbolic")
        || starts_with(arg, "--dependency-file=");
}

/* -Wl,* flags to drop (entire arg, when not using LLD) */
static int is_wl_drop(const char *arg) {
    if (!starts_with(arg, "-Wl,"))
        return 0;
    return starts_with(arg, "-Wl,-rpath-link")
        || str_eq(arg, "-Wl,--disable-new-dtags")
        || str_eq(arg, "-Wl,--allow-shlib-undefined")
        || str_eq(arg, "-Wl,--no-allow-shlib-undefined")
        || str_eq(arg, "-Wl,-Bsymbolic-functions")
        || str_eq(arg, "-Wl,-Bsymbolic")
        || str_eq(arg, "-Wl,--color-diagnostics")
        || starts_with(arg, "-Wl,--version-script")
        || starts_with(arg, "-Wl,-soname")
        || starts_with(arg, "-Wl,-z,")
        || starts_with(arg, "-Wl,-O")
        || str_eq(arg, "-Wl,--gc-sections")
        || str_eq(arg, "-Wl,--no-gc-sections")
        || starts_with(arg, "-Wl,--build-id");
}

/* MSVC/LLD manifest flags to drop (/MANIFEST*, -MANIFEST*).
 * CMake injects /MANIFEST:NO, /MANIFESTUAC:NO, /MANIFESTINPUT:..., etc.
 * These are PE/COFF linker flags; zig cc forwards them to lld-link which
 * may reject or misparse them when the cc wrapper re-invokes zig cc. */
static int is_manifest_flag(const char *arg) {
    if (arg[0] != '/' && arg[0] != '-') return 0;
    const char *body = arg + 1;
    if (tolower((unsigned char)body[0]) != 'm') return 0;
    if (tolower((unsigned char)body[1]) != 'a') return 0;
    if (tolower((unsigned char)body[2]) != 'n') return 0;
    if (tolower((unsigned char)body[3]) != 'i') return 0;
    if (tolower((unsigned char)body[4]) != 'f') return 0;
    if (tolower((unsigned char)body[5]) != 'e') return 0;
    if (tolower((unsigned char)body[6]) != 's') return 0;
    if (tolower((unsigned char)body[7]) != 't') return 0;
    return 1;
}

/* Flags that trigger auto-promotion to LLD (unsupported by self-hosted linker).
 * These are -Wl,* and bare flags; if detected we inject -fuse-ld=lld so that
 * LLD receives them instead of the self-hosted linker. */
static int is_lld_trigger(const char *arg) {
    if (str_eq(arg, "-fuse-ld=lld")) return 1;
    /* ELF flags unsupported by self-hosted linker */
    if (starts_with(arg, "-Wl,--version-script")) return 1;
    if (starts_with(arg, "-Wl,--dynamic-list")) return 1;
    if (starts_with(arg, "-Wl,-z,defs") || starts_with(arg, "-Wl,-z,nodelete")) return 1;
    if (str_eq(arg, "-Wl,--gc-sections") || str_eq(arg, "-Wl,--no-gc-sections")) return 1;
    if (starts_with(arg, "-Wl,--build-id")) return 1;
    if (str_eq(arg, "-Wl,--allow-shlib-undefined") || str_eq(arg, "-Wl,--no-allow-shlib-undefined")) return 1;
    if (str_eq(arg, "-Wl,-Bsymbolic-functions") || str_eq(arg, "-Wl,-Bsymbolic")) return 1;
    if (str_eq(arg, "-Bsymbolic-functions") || str_eq(arg, "-Bsymbolic")) return 1;
    if (starts_with(arg, "-Wl,-O")) return 1;
    /* macOS Mach-O flags */
    if (starts_with(arg, "-Wl,-exported_symbols_list")) return 1;
    if (starts_with(arg, "-Wl,-unexported_symbols_list")) return 1;
    if (starts_with(arg, "-Wl,-reexported_symbols_list")) return 1;
    if (starts_with(arg, "-Wl,-force_symbols_not_weak_list")) return 1;
    if (starts_with(arg, "-Wl,-force_symbols_weak_list")) return 1;
    if (starts_with(arg, "-Wl,-all_load") || starts_with(arg, "-Wl,-force_load,")) return 1;
    if (str_eq(arg, "-all_load") || str_eq(arg, "-force_load")) return 1;
    if (starts_with(arg, "-Wl,-syslibroot")) return 1;
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

/* Returns 1 if the target triple names a Windows target. */
static int is_windows_triple(const char *t) {
    return t != NULL && strstr(t, "windows") != NULL;
}

/* --- subcommand whitelist for -target injection (DISPATCH mode) --- */
static int subcommand_accepts_target(const char *cmd) {
    if (!cmd) return 0;
    return str_eq(cmd, "cc") || str_eq(cmd, "c++")
        || str_eq(cmd, "build-exe") || str_eq(cmd, "build-lib") || str_eq(cmd, "build-obj")
        || str_eq(cmd, "test") || str_eq(cmd, "run") || str_eq(cmd, "translate-c");
}

/* --- check if user already supplied -target or --target= --- */
static int user_has_target(int argc, char *argv[], int start) {
    for (int i = start; i < argc; i++) {
        if (str_eq(argv[i], "-target")) return 1;
        if (starts_with(argv[i], "--target=")) return 1;
    }
    return 0;
}

/* --- mode detection from basename(argv[0]) --- */
static const char *basename_of(const char *path) {
    const char *slash = strrchr(path, PATH_SEP);
#ifdef _WIN32
    /* Windows: also accept forward slashes */
    const char *fwd = strrchr(path, '/');
    if (fwd > slash) slash = fwd;
#endif
    return slash ? slash + 1 : path;
}

static wrapper_mode_t detect_mode(const char *arg0) {
    const char *bn = basename_of(arg0);
    /* Copy basename, strip .exe suffix on Windows */
    static char buf[256];
    snprintf(buf, sizeof(buf), "%s", bn);
    size_t len = strlen(buf);
#ifdef _WIN32
    if (len > 4 && (str_eq(buf + len - 4, ".exe") || str_eq(buf + len - 4, ".EXE"))) {
        buf[len - 4] = '\0';
        len -= 4;
    }
#endif
    /* Suffix dispatch. Canonical list at recipe/building/wrapper_modes.txt
     * is consumed by build.sh + install_zig_activation.py. detect_mode here
     * is hand-maintained; A2 (MODE_UNKNOWN fall-through) ensures missing
     * entries here degrade gracefully instead of exit 1. */
    /* Match longest suffix first */
    if (ends_with(buf, "-zig-ranlib")) return MODE_RANLIB;
    if (ends_with(buf, "-zig-force-load-cxx")) return MODE_FORCE_LOAD_CXX;
    if (ends_with(buf, "-zig-force-load-cc"))  return MODE_FORCE_LOAD_CC;
    if (ends_with(buf, "-zig-cxx") || ends_with(buf, "-zig-c++")) return MODE_CXX;
    if (ends_with(buf, "-zig-asm")) return MODE_ASM;
    if (ends_with(buf, "-zig-lld")) return MODE_LLD;
    if (ends_with(buf, "-zig-cc")) return MODE_CC;
    if (ends_with(buf, "-zig-ar")) return MODE_AR;
    if (ends_with(buf, "-zig-rc")) return MODE_RC;
    if (ends_with(buf, "-zig")) return MODE_DISPATCH;
    if (str_eq(buf, "zig") || str_eq(buf, "zig.exe")) return MODE_DISPATCH;
    return MODE_UNKNOWN;
}

/* --- resolve path to real zig binary --- */
static int resolve_real_zig(char *out, size_t out_size) {
    /* First: if @ZIG_REAL_PATH@ substituted to a non-empty value AND the file
     * exists there, use it. On Windows conda's PE prefix replacement does not
     * reliably rewrite this baked-in absolute path, so verify existence before
     * trusting it; otherwise fall through to runtime-relative resolution. */
    if (ZIG_REAL_PATH[0] != '\0' && ZIG_REAL_PATH[0] != '@') {
        FILE *probe = fopen(ZIG_REAL_PATH, "rb");
        if (probe) {
            fclose(probe);
            snprintf(out, out_size, "%s", ZIG_REAL_PATH);
            return 0;
        }
    }

    /* Fallback: resolve ../share/zig/zig-real(.exe) relative to this exe's own
     * directory. The wrapper lives in <prefix>/bin (or <prefix>/Library/bin on
     * Windows) and the real zig in <prefix>/share/zig (or
     * <prefix>/Library/share/zig), so the navigation is relocation-independent. */
    char self_path[MAX_PATH_LEN];
#ifdef _WIN32
    DWORD n = GetModuleFileNameA(NULL, self_path, (DWORD)sizeof(self_path));
    if (n == 0 || n >= sizeof(self_path)) return -1;
#elif defined(__APPLE__)
    uint32_t size = (uint32_t)sizeof(self_path);
    if (_NSGetExecutablePath(self_path, &size) != 0) return -1;
#else
    ssize_t n = readlink("/proc/self/exe", self_path, sizeof(self_path) - 1);
    if (n < 0) return -1;
    self_path[n] = '\0';
#endif
    char *slash = strrchr(self_path, PATH_SEP);
#ifdef _WIN32
    {
        char *fwd = strrchr(self_path, '/');
        if (fwd > slash) slash = fwd;
    }
#endif
    if (!slash) return -1;
    *(slash + 1) = '\0';  /* directory including trailing separator */
    snprintf(out, out_size, "%s..%cshare%czig%c%s",
             self_path, PATH_SEP, PATH_SEP, PATH_SEP, ZIG_REAL_DEFAULT);
    return 0;
}

/* A4: --zig-wrapper-self-test flag for drift detection between wrapper_modes.txt
 * and the canonical KNOWN list embedded in this binary. Self-test reads the
 * modes file at runtime, parses suffix entries, and reports any missing/extra/
 * duplicate suffixes vs the KNOWN list.
 */

static int find_modes_txt(const char *argv0, char *buf, size_t bufsize) {
    const char *env = getenv("WRAPPER_MODES_TXT");
    if (env && env[0]) {
        snprintf(buf, bufsize, "%s", env);
        return access(buf, R_OK) == 0 ? 0 : -1;
    }
    char real[PATH_MAX];
    if (realpath(argv0, real)) {
        char *slash = strrchr(real, PATH_SEP);
        if (slash) {
            *slash = 0;
            snprintf(buf, bufsize, "%s%c..%cshare%czig-wrapper%cwrapper_modes.txt",
                     real, PATH_SEP, PATH_SEP, PATH_SEP, PATH_SEP);
            if (access(buf, R_OK) == 0) return 0;
        }
    }
    const char *recipe_dir = getenv("RECIPE_DIR");
    if (recipe_dir && recipe_dir[0]) {
        snprintf(buf, bufsize, "%s%cbuilding%cwrapper_modes.txt",
                 recipe_dir, PATH_SEP, PATH_SEP);
        if (access(buf, R_OK) == 0) return 0;
    }
    return -1;
}

static int run_self_test(const char *argv0, const char *explicit_path) {
    char path_buf[PATH_MAX];
    const char *modes_path;

    if (explicit_path && explicit_path[0]) {
        modes_path = explicit_path;
        if (access(modes_path, R_OK) != 0) {
            fprintf(stderr, "wrapper self-test FAIL: cannot read %s\n", modes_path);
            return 1;
        }
    } else {
        if (find_modes_txt(argv0, path_buf, sizeof(path_buf)) != 0) {
            fprintf(stderr, "wrapper self-test FAIL: wrapper_modes.txt not found in default locations\n");
            return 1;
        }
        modes_path = path_buf;
    }

    FILE *f = fopen(modes_path, "r");
    if (!f) {
        fprintf(stderr, "wrapper self-test FAIL: cannot open %s\n", modes_path);
        return 1;
    }

    char line[256];
    char *modes[64];
    int n_modes = 0;
    while (fgets(line, sizeof(line), f) && n_modes < 64) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#' || *p == '\n' || *p == '\r') continue;
        char *e = p + strlen(p);
        while (e > p && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) e--;
        *e = 0;
        if (!*p) continue;

        for (int i = 0; i < n_modes; i++) {
            if (str_eq(modes[i], p)) {
                fprintf(stderr, "wrapper self-test FAIL: duplicate mode %s\n", p);
                fclose(f);
                for (int j = 0; j < n_modes; j++) free(modes[j]);
                return 1;
            }
        }
        modes[n_modes++] = strdup(p);
    }
    fclose(f);

    static const char *KNOWN[] = {
        "cc", "cxx", "ar", "ranlib", "lld", "rc", "asm",
        "force-load-cc", "force-load-cxx"
    };
    const int N_KNOWN = (int)(sizeof(KNOWN) / sizeof(KNOWN[0]));

    for (int i = 0; i < N_KNOWN; i++) {
        int found = 0;
        for (int j = 0; j < n_modes; j++) {
            if (str_eq(modes[j], KNOWN[i])) { found = 1; break; }
        }
        if (!found) {
            fprintf(stderr, "wrapper self-test FAIL: missing mode %s\n", KNOWN[i]);
            for (int k = 0; k < n_modes; k++) free(modes[k]);
            return 1;
        }
    }

    for (int i = 0; i < n_modes; i++) {
        int known = 0;
        for (int j = 0; j < N_KNOWN; j++) {
            if (str_eq(modes[i], KNOWN[j])) { known = 1; break; }
        }
        if (!known) {
            fprintf(stderr, "wrapper self-test FAIL: extra mode %s\n", modes[i]);
            for (int k = 0; k < n_modes; k++) free(modes[k]);
            return 1;
        }
    }

    printf("wrapper self-test OK: %d modes consistent\n", n_modes);
    for (int k = 0; k < n_modes; k++) free(modes[k]);
    return 0;
}

/* --- Windows: set ZIG_GLOBAL_CACHE_DIR if unset ---
 * Mirrors zig's own resolution: APPDATA > USERPROFILE > GetTempPath.
 * Prevents AppDataDirUnavailable panic even when APPDATA is set but
 * zig's internal resolution fails. */
#ifdef _WIN32
static void ensure_zig_cache_dir(void) {
    if (getenv("ZIG_GLOBAL_CACHE_DIR")) return;
    char base[MAX_PATH];
    const char *appdata = getenv("APPDATA");
    const char *userprofile = getenv("USERPROFILE");
    if (appdata && appdata[0]) {
        snprintf(base, MAX_PATH, "%s\\zig\\zig-cache", appdata);
    } else if (userprofile && userprofile[0]) {
        snprintf(base, MAX_PATH, "%s\\AppData\\Roaming\\zig\\zig-cache", userprofile);
    } else {
        DWORD tmp_len = GetTempPathA(MAX_PATH, base);
        if (tmp_len > 0)
            snprintf(base + tmp_len - 1, MAX_PATH - (int)tmp_len, "\\zig-cache");
    }
    char *env_val = malloc(strlen("ZIG_GLOBAL_CACHE_DIR=") + strlen(base) + 2);
    if (env_val) {
        sprintf(env_val, "ZIG_GLOBAL_CACHE_DIR=%s", base);
        _putenv(env_val);
        free(env_val);
    }
}

/* Windows: ensure C:\Windows\System32 is in PATH so UCRT DLLs are found.
 * MSYS2 strips System32 from PATH, breaking zig-compiled binaries that
 * link against UCRT (api-ms-win-crt-*.dll). */
static void ensure_system32_in_path(void) {
    if (!getenv("MSYSTEM")) return;
    const char *path = getenv("PATH");
    const char *sys32 = "C:\\Windows\\System32";
    if (!path || strstr(path, sys32)) return;
    char *new_path = malloc(strlen(path) + strlen(sys32) + 7);
    if (!new_path) return;
    sprintf(new_path, "PATH=%s;%s", sys32, path);
    _putenv(new_path);
    free(new_path);
}

/* Scan argv for -target X / -target=X / --target=X (last-wins per zig convention).
 * Returns the lib-<arch> suffix for the recognized arch, or NULL if no -target
 * was found OR if the value is unrecognized (in which case a warning is
 * emitted to stderr matching the A2 warn-and-fall-through philosophy).
 * Caller falls back to HOST_DEFAULT_ARCH on NULL return.
 */
static const char *extract_target_arch_from_argv(int argc, char **argv) {
    const char *last_target = NULL;
    for (int i = 1; i < argc; i++) {
        const char *val = NULL;
        if (strcmp(argv[i], "-target") == 0 && i + 1 < argc) {
            val = argv[i + 1];
        } else if (strncmp(argv[i], "-target=", 8) == 0) {
            val = argv[i] + 8;
        } else if (strncmp(argv[i], "--target=", 9) == 0) {
            val = argv[i] + 9;
        }
        if (val != NULL) last_target = val;
    }
    if (last_target == NULL) return NULL;
    for (int j = 0; TARGET_ARCH_MAP[j].prefix != NULL; j++) {
        size_t plen = strlen(TARGET_ARCH_MAP[j].prefix);
        if (strncmp(last_target, TARGET_ARCH_MAP[j].prefix, plen) == 0) {
            return TARGET_ARCH_MAP[j].arch_dir;
        }
    }
    fprintf(stderr,
            "zig-wrapper: unrecognized -target arch '%s' for -print-search-dirs, "
            "falling back to host arch '%s'\n",
            last_target, HOST_DEFAULT_ARCH);
    return NULL;
}

/* --- Handle -print-search-dirs (Windows, GCC compat for flexlink/mingw_libs) ---
 * zig doesn't implement this flag. flexlink calls it to discover library
 * search paths before resolving -lXXX arguments. Without a response,
 * flexlink has no search paths and treats -lws2_32 as a literal filename.
 * We return paths to zig's pre-generated MinGW import libraries. */
static int handle_print_search_dirs(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (!str_eq(argv[i], "-print-search-dirs")) continue;
        const char *conda = getenv("CONDA_PREFIX");
        if (conda && conda[0]) {
            const char *arch = extract_target_arch_from_argv(argc, argv);
            if (arch == NULL) arch = HOST_DEFAULT_ARCH;
            printf("install: %s\\Library\\lib\\zig\\\n", conda);
            printf("programs: =%s\\Library\\bin\\\n", conda);
            printf("libraries: =%s\\Library\\lib\\zig\\libc\\mingw\\lib-common;"
                   "%s\\Library\\lib\\zig\\libc\\mingw\\lib-%s;"
                   "%s\\Library\\lib\\zig\n",
                   conda, conda, arch, conda);
        } else {
            printf("install: \nprograms: =\nlibraries: =\n");
        }
        return 1;
    }
    return 0;
}

/* --- Handle -print-file-name=<name> (Windows, GCC/Clang compat) ---
 * zig doesn't support this flag. Probe known lib dirs and echo back
 * the path if found, or the name unchanged if not (GCC behaviour). */
static int handle_print_file_name(int argc, char *argv[]) {
    const char *prefix = "-print-file-name=";
    size_t plen = strlen(prefix);
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], prefix, plen) != 0) continue;
        const char *name = argv[i] + plen;
        const char *conda = getenv("CONDA_PREFIX");
        if (conda && conda[0]) {
            char probe[MAX_PATH];
            const char *dirs[] = {
                "Library\\lib\\zig-llvm\\lib",
                "Library\\lib"
            };
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
    return 0;
}
#endif /* _WIN32 */

/* --- main --- */
int main(int argc, char *argv[]) {
    const char *dbg_env = getenv("ZIG_WRAPPER_DEBUG");
    debug_enabled = (dbg_env && dbg_env[0] != '\0');

    /* A3: Probe-flag short-circuit. Tooling probes (--version, --help, etc.)
     * want the underlying compiler to identify itself; they don't care about
     * wrapper mode dispatch. Short-circuit before detect_mode() so:
     *   1. Unknown basenames can still respond to --version (composes with A2).
     *   2. Probe latency is reduced (no filter-loop overhead).
     *   3. Probe flags can't be mangled by mode-specific arg filtering.
     *
     * -v is intentionally excluded: lowercase -v is overloaded (clang verbose,
     * zig treats it differently from --version). The unambiguous flags suffice.
     *
     * -dumpversion / -dumpmachine are GCC/clang compat probes; zig may not
     * understand them, but the caller then gets a clear "unknown option" from
     * zig itself rather than a silent wrapper failure. */
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--version") == 0
         || strcmp(a, "-V") == 0
         || strcmp(a, "--help") == 0
         || strcmp(a, "-dumpversion") == 0
         || strcmp(a, "-dumpmachine") == 0) {
            char zig_path_probe[MAX_PATH_LEN];
            if (resolve_real_zig(zig_path_probe, sizeof(zig_path_probe)) != 0) {
                fprintf(stderr, "zig-wrapper: cannot resolve real zig binary\n");
                return 1;
            }
#ifdef _WIN32
            int rc = (int)_spawnv(_P_WAIT, zig_path_probe, (const char *const *)argv);
            if (rc < 0) { perror("zig-wrapper: spawn zig-real"); return 127; }
            return rc;
#else
            execv(zig_path_probe, argv);
            perror("zig-wrapper: exec zig-real");
            return 127;
#endif
        }
    }

    /* A4: self-test early-exit before any mode dispatch */
    for (int _i = 1; _i < argc; _i++) {
        const char *_arg = argv[_i];
        if (str_eq(_arg, "--zig-wrapper-self-test")) {
            return run_self_test(argv[0], NULL);
        }
        if (starts_with(_arg, "--zig-wrapper-self-test=")) {
            return run_self_test(argv[0], _arg + sizeof("--zig-wrapper-self-test=") - 1);
        }
    }

    wrapper_mode_t mode = detect_mode(argv[0]);

    DBG("argv[0]=%s mode=%d\n", argv[0], (int)mode);
    for (int i = 1; i < argc; i++) DBG("  in argv[%d]=%s\n", i, argv[i]);

    if (mode == MODE_UNKNOWN) {
        /* A2: warn and fall through to zig-real with original argv intact.
         * This prevents build aborts when a new wrapper variant is installed
         * but detect_mode() hasn't been updated yet (or a typo in CC=/CXX=).
         * Add new variants to recipe/building/wrapper_modes.txt and update
         * detect_mode() above to promote them to a proper mode. */
        fprintf(stderr,
            "zig-wrapper: WARNING: unknown basename '%s' — falling through to zig-real.\n"
            "  If this is a new wrapper variant, add it to recipe/building/wrapper_modes.txt\n"
            "  and recipe/building/zig-wrapper.c detect_mode().\n",
            argv[0]);
        char zig_path_fb[MAX_PATH_LEN];
        if (resolve_real_zig(zig_path_fb, sizeof(zig_path_fb)) != 0) {
            fprintf(stderr, "zig-wrapper: cannot resolve real zig binary\n");
            return 1;
        }
#ifdef _WIN32
        int rc = (int)_spawnv(_P_WAIT, zig_path_fb, (const char *const *)argv);
        if (rc < 0) { perror("zig-wrapper: spawn zig-real"); return 127; }
        return rc;
#else
        execv(zig_path_fb, argv);
        perror("zig-wrapper: exec zig-real");
        return 127;
#endif
    }

#ifdef _WIN32
    ensure_zig_cache_dir();
    ensure_system32_in_path();

    /* GCC compat queries: answer and exit before any zig invocation */
    if (handle_print_search_dirs(argc, argv)) return 0;
    if (handle_print_file_name(argc, argv)) return 0;
#endif

    char zig_path[MAX_PATH_LEN];
    if (resolve_real_zig(zig_path, sizeof(zig_path)) != 0) {
        fprintf(stderr, "zig-wrapper: cannot resolve real zig binary\n");
        return 1;
    }
    DBG("real zig: %s\n", zig_path);

    /* Verify real zig exists before attempting exec; better error than execv ENOENT */
    {
        FILE *fp = fopen(zig_path, "rb");
        if (!fp) {
            fprintf(stderr, "zig-wrapper: real zig not found at '%s' (errno=%d)\n", zig_path, errno);
            perror("zig-wrapper: fopen");
            return 1;
        }
        fclose(fp);
    }

    /* Allocate generously: original args + up to ~10 injected args + NULL */
    char **new_argv = (char **)calloc((size_t)(argc + 12), sizeof(char *));
    if (!new_argv) {
        fprintf(stderr, "zig-wrapper: malloc failed\n");
        return 1;
    }

    /* Filtered arg staging buffer (CC/CXX pre-filter) */
    const char **filtered = (const char **)malloc(sizeof(char *) * (size_t)(argc + 1));
    if (!filtered) {
        fprintf(stderr, "zig-wrapper: malloc failed\n");
        free(new_argv);
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;

    const char *subcommand = NULL;
    int user_args_start = 1;
    int do_filter = 0;
    int allow_target = 0;
    int is_force_load_mode = 0;

    switch (mode) {
        case MODE_DISPATCH:
            if (argc >= 2) {
                subcommand = argv[1];
                new_argv[ni++] = argv[1];
                user_args_start = 2;
                allow_target = subcommand_accepts_target(subcommand);
                /* dispatch "zig cc"/"zig c++" must filter MSVC-only flags (e.g. /MANIFEST*)
                   exactly like the -zig-cc/-zig-cxx entrypoints; only tool/passthrough
                   subcommands skip filtering. */
                if (str_eq(subcommand, "cc") || str_eq(subcommand, "c++"))
                    do_filter = 1;
            }
            break;
        case MODE_CC:
            subcommand = "cc";  new_argv[ni++] = "cc";  do_filter = 1; allow_target = 1; break;
        case MODE_CXX:
            subcommand = "c++"; new_argv[ni++] = "c++"; do_filter = 1; allow_target = 1; break;
        case MODE_FORCE_LOAD_CC:
            subcommand = "cc";  new_argv[ni++] = "cc";  do_filter = 1; allow_target = 1;
            is_force_load_mode = 1; break;
        case MODE_FORCE_LOAD_CXX:
            subcommand = "c++"; new_argv[ni++] = "c++"; do_filter = 1; allow_target = 1;
            is_force_load_mode = 1; break;
        case MODE_AR:
            subcommand = "ar"; new_argv[ni++] = "ar"; break;
        case MODE_RANLIB:
            subcommand = "ranlib"; new_argv[ni++] = "ranlib"; break;
        case MODE_LLD:
            subcommand = LLD_SUBCOMMAND; new_argv[ni++] = (char *)LLD_SUBCOMMAND; break;
        case MODE_RC:
            subcommand = "rc"; new_argv[ni++] = "rc"; break;
        case MODE_ASM:
            /* zig has no `as` subcommand (error: unknown command: as). Assemble
             * .S files through the cc driver (clang infers assembly from the .S
             * extension). Mirror MODE_CC so cross-target .S files get -target
             * injection and flag filtering. */
            subcommand = "cc";  new_argv[ni++] = "cc";  do_filter = 1; allow_target = 1; break;
        case MODE_UNKNOWN:
            break; /* unreachable: checked above */
    }
    (void)subcommand; /* used only for DBG */

    /* P-Force-Load: scan argv for force-load triggers and extract archives.
     * Ports zig-gcc's _zig-force-load-common.sh to C (Unix-only; on Windows
     * force-load modes fall through to plain CC/CXX behaviour because macOS
     * Mach-O force-load is not a conda-forge Windows concern). */
    char **extracted_objects = NULL;
    int n_extracted = 0;
    int extracted_cap = 0;

#ifndef _WIN32
    if (is_force_load_mode) {
        /* First pass: identify force-load triggers */
        int all_load_mode = 0;
        const char **force_archives = NULL;
        int n_force_archives = 0;
        int force_archives_cap = 0;

        for (int i = user_args_start; i < argc; i++) {
            const char *a = argv[i];
            if (str_eq(a, "-Wl,-all_load") || str_eq(a, "-all_load")) {
                all_load_mode = 1;
            } else if (starts_with(a, "-Wl,-force_load,")) {
                const char *path = a + 16; /* skip "-Wl,-force_load," */
                if (path[0] != '\0') {
                    if (n_force_archives >= force_archives_cap) {
                        force_archives_cap = force_archives_cap ? force_archives_cap * 2 : 8;
                        force_archives = (const char **)realloc(force_archives,
                            force_archives_cap * sizeof(char *));
                        if (!force_archives) { perror("zig-wrapper: realloc"); exit(1); }
                    }
                    force_archives[n_force_archives++] = path;
                }
            } else if (str_eq(a, "-force_load") && i + 1 < argc) {
                const char *path = argv[i + 1];
                if (n_force_archives >= force_archives_cap) {
                    force_archives_cap = force_archives_cap ? force_archives_cap * 2 : 8;
                    force_archives = (const char **)realloc(force_archives,
                        force_archives_cap * sizeof(char *));
                    if (!force_archives) { perror("zig-wrapper: realloc"); exit(1); }
                }
                force_archives[n_force_archives++] = path;
                i++; /* consume the path arg */
            }
        }

        if (all_load_mode || n_force_archives > 0) {
            /* Collect archives to extract */
            const char **to_extract = NULL;
            int n_to_extract = 0;
            int to_extract_cap = 0;

            if (all_load_mode) {
                /* Every existing .a file in argv */
                for (int i = user_args_start; i < argc; i++) {
                    const char *a = argv[i];
                    size_t alen = strlen(a);
                    if (alen > 2 && a[alen - 2] == '.' && a[alen - 1] == 'a') {
                        struct stat st;
                        if (stat(a, &st) == 0 && S_ISREG(st.st_mode)) {
                            if (n_to_extract >= to_extract_cap) {
                                to_extract_cap = to_extract_cap ? to_extract_cap * 2 : 8;
                                to_extract = (const char **)realloc(to_extract,
                                    to_extract_cap * sizeof(char *));
                                if (!to_extract) { perror("zig-wrapper: realloc"); exit(1); }
                            }
                            to_extract[n_to_extract++] = a;
                        }
                    }
                }
            }
            /* Always add explicitly requested force_archives */
            for (int i = 0; i < n_force_archives; i++) {
                struct stat st;
                if (stat(force_archives[i], &st) == 0 && S_ISREG(st.st_mode)) {
                    if (n_to_extract >= to_extract_cap) {
                        to_extract_cap = to_extract_cap ? to_extract_cap * 2 : 8;
                        to_extract = (const char **)realloc(to_extract,
                            to_extract_cap * sizeof(char *));
                        if (!to_extract) { perror("zig-wrapper: realloc"); exit(1); }
                    }
                    to_extract[n_to_extract++] = force_archives[i];
                } else {
                    fprintf(stderr, "zig-wrapper: force-load: archive not found: %s\n",
                            force_archives[i]);
                }
            }

            if (n_to_extract > 0) {
                /* Create master tmpdir (leaked on exit — matches bash behaviour) */
                char tmpl[PATH_MAX];
                const char *tmpdir_env = getenv("TMPDIR");
                if (!tmpdir_env || !tmpdir_env[0]) tmpdir_env = "/tmp";
                snprintf(tmpl, sizeof(tmpl), "%s/zig-force-load-XXXXXX", tmpdir_env);
                char *master_tmp = mkdtemp(tmpl);
                if (!master_tmp) { perror("zig-wrapper: mkdtemp"); exit(1); }
                /* TODO: rm -rf master_tmp after zig exits; for now leak (see Step 7 rationale) */

                DBG("force-load: master_tmp=%s n_to_extract=%d\n", master_tmp, n_to_extract);

                for (int i = 0; i < n_to_extract; i++) {
                    /* Resolve archive to absolute path before chdir */
                    char abs_archive[PATH_MAX];
                    if (realpath(to_extract[i], abs_archive) == NULL)
                        snprintf(abs_archive, sizeof(abs_archive), "%s", to_extract[i]);

                    /* Per-archive subdir prevents object-basename collisions */
                    char subdir[PATH_MAX];
                    snprintf(subdir, sizeof(subdir), "%s/%d", master_tmp, i);
                    if (mkdir(subdir, 0700) != 0) { perror("zig-wrapper: mkdir"); exit(1); }

                    DBG("force-load: extracting %s -> %s\n", abs_archive, subdir);

                    pid_t pid = fork();
                    if (pid < 0) { perror("zig-wrapper: fork"); exit(1); }
                    if (pid == 0) {
                        if (chdir(subdir) != 0) { perror("zig-wrapper: chdir"); _exit(1); }
                        char *ar_argv[] = { zig_path, "ar", "x", abs_archive, NULL };
                        execv(zig_path, ar_argv);
                        perror("zig-wrapper: execv ar");
                        _exit(127);
                    }
                    int ar_status;
                    if (waitpid(pid, &ar_status, 0) < 0) { perror("zig-wrapper: waitpid"); exit(1); }
                    if (!WIFEXITED(ar_status) || WEXITSTATUS(ar_status) != 0) {
                        fprintf(stderr, "zig-wrapper: ar x failed on %s\n", to_extract[i]);
                        exit(1);
                    }

                    /* Collect *.o files from subdir */
                    DIR *d = opendir(subdir);
                    if (!d) { perror("zig-wrapper: opendir"); exit(1); }
                    struct dirent *de;
                    while ((de = readdir(d)) != NULL) {
                        const char *name = de->d_name;
                        size_t nlen = strlen(name);
                        if (nlen > 2 && name[nlen - 2] == '.' && name[nlen - 1] == 'o') {
                            size_t plen = strlen(subdir) + 1 + nlen + 1;
                            char *full = (char *)malloc(plen);
                            if (!full) { perror("zig-wrapper: malloc"); exit(1); }
                            snprintf(full, plen, "%s/%s", subdir, name);
                            if (n_extracted >= extracted_cap) {
                                extracted_cap = extracted_cap ? extracted_cap * 2 : 16;
                                extracted_objects = (char **)realloc(extracted_objects,
                                    extracted_cap * sizeof(char *));
                                if (!extracted_objects) {
                                    perror("zig-wrapper: realloc"); exit(1);
                                }
                            }
                            extracted_objects[n_extracted++] = full;
                            DBG("force-load: extracted .o: %s\n", full);
                        }
                    }
                    closedir(d);
                }
            }
            free(to_extract);
        }
        free(force_archives);
    }
#endif /* !_WIN32 */

    if (do_filter) {
        /* --- CC/CXX mode: pre-scan + filter, then assemble new_argv --- */

        /* Pre-scan: detect LLD-triggering flags, user target overrides, -mcpu */
        /* zig cc defaults to LLD on Linux/ELF and Windows/COFF; macOS guard below clears for ld64 */
        int use_lld = 1;
        int has_target = user_has_target(argc, argv, user_args_start);
        int has_mcpu = 0;

        for (int i = user_args_start; i < argc; i++) {
            if (is_lld_trigger(argv[i])) use_lld = 1;
            if (str_eq(argv[i], "-Xlinker") && i + 1 < argc) {
                if (is_xlinker_lld_trigger(argv[i + 1])) use_lld = 1;
            }
            if (starts_with(argv[i], "-mcpu=")) has_mcpu = 1;
        }

        DBG("CC/CXX prescan: use_lld=%d has_target=%d has_mcpu=%d\n",
            use_lld, has_target, has_mcpu);

        /* macOS: ld64.lld cannot resolve -lSystem in conda envs (no SDK shipped).
         * Match recipe/scripts/_zig-cc-common.sh:160-162 by clearing use_lld for
         * Mach-O targets — zig's self-hosted Mach-O linker handles common flags
         * (-exported_symbols_list, -Wl,-rpath, etc.) and finds libSystem via
         * bundled stubs. */
        if (strstr(ZIG_TARGET, "-macos") || strstr(ZIG_TARGET, "-darwin")) {
            use_lld = 0;
            DBG("macOS target detected; cleared use_lld\n");
        }

        /* P-3: determine effective Windows target for -Wl,-e translation.
         * Compile-time default from ZIG_TARGET; runtime -target overrides it. */
        int is_windows_target = is_windows_triple(ZIG_TARGET);
        for (int i = user_args_start; i < argc; i++) {
            if (str_eq(argv[i], "-target") && i + 1 < argc) {
                is_windows_target = is_windows_triple(argv[i + 1]);
                break;
            }
            if (starts_with(argv[i], "-target=")) {
                is_windows_target = is_windows_triple(argv[i] + 8);
                break;
            }
        }
        DBG("CC/CXX prescan: is_windows_target=%d\n", is_windows_target);

        /* Filter args into staging buffer */
        int fi = 0;
        int grab_next = 0;
        int saw_nostdlibxx = 0;

        for (int i = user_args_start; i < argc; i++) {
            const char *a = argv[i];

            /* -Xlinker <arg>: grab next arg for individual inspection */
            if (grab_next) {
                grab_next = 0;
                /* --color-diagnostics: drop when !use_lld, pass through when use_lld.
                 * Mirrors -Wl,--color-diagnostics in is_wl_drop (LLD handles it natively;
                 * self-hosted linker does not recognize it). */
                if (!use_lld && str_eq(a, "--color-diagnostics")) {
                    DBG("DROPPED (xlinker --color-diagnostics, !use_lld): %s\n", a);
                } else if (!is_xlinker_drop(a)) {
                    filtered[fi++] = "-Xlinker";
                    filtered[fi++] = a;
                } else {
                    DBG("DROPPED (xlinker_drop): %s\n", a);
                }
                continue;
            }
            if (str_eq(a, "-Xlinker")) {
                grab_next = 1;
                continue;
            }

            /* /clang:* prefix: strip and forward bare flag */
            if (starts_with(a, "/clang:")) {
                DBG("REWROTE (/clang:): %s -> %s\n", a, a + 7);
                filtered[fi++] = a + 7;
                continue;
            }

            /* /Xclang <flag>: two-arg clang-cl form; forward bare flag */
            if (str_eq(a, "/Xclang")) {
                if (i + 1 < argc) {
                    filtered[fi++] = argv[++i];
                }
                continue;
            }

            /* P-3: translate -Wl,-e<sym> -> -Wl,/ENTRY:<sym> on Windows targets.
             * lld-link rejects unix-style -e<sym>; consumers (flexlink, etc.) emit
             * -Wl,-e and expect zig cc to handle it. zig cc passes through verbatim,
             * so we translate at the wrapper. Concatenated form only; long form
             * (-Wl,--entry=<sym>) and separated form (-Wl,-e,<sym>) not handled. */
            if (is_windows_target && starts_with(a, "-Wl,-e")) {
                const char *sym = a + 6;  /* skip "-Wl,-e" */
                if (sym[0] != '\0') {
                    size_t sym_len = strlen(sym);
                    /* Build "-Wl,/ENTRY:" + sym + NUL = 11 + sym_len + 1 bytes */
                    char *rewritten = (char *)malloc(sym_len + 12);
                    if (!rewritten) { perror("zig-wrapper: malloc"); exit(1); }
                    memcpy(rewritten, "-Wl,/ENTRY:", 11);
                    memcpy(rewritten + 11, sym, sym_len + 1);
                    DBG("REWROTE (-Wl,-e): %s -> %s\n", a, rewritten);
                    filtered[fi++] = rewritten;
                    continue;
                }
                /* "-Wl,-e" with no symbol — fall through; clang will reject */
            }

            /* P-4: -Wl,--stack,SIZE (or =SIZE) -> -Wl,/STACK:SIZE.
             * GNU ld comma form; mingw-ld honors --stack, lld-link needs /STACK:.
             * Build-29+ wishlist item 1 (ocaml-feedstock PR #97 W5M). */
            if (is_windows_target &&
                (starts_with(a, "-Wl,--stack,") || starts_with(a, "-Wl,--stack="))) {
                const char *size = a + 12; /* skip "-Wl,--stack," / "-Wl,--stack=" (both 12) */
                if (size[0] != '\0') {
                    char *rewritten = make_wl_msvc("/STACK:", size);
                    DBG("REWROTE (-Wl,--stack): %s -> %s\n", a, rewritten);
                    filtered[fi++] = rewritten;
                    continue;
                }
                /* "-Wl,--stack," with no size -- fall through */
            }

            /* P-5a: -Wl,-Map,FILE (or =FILE) -> -Wl,/MAP:FILE (lld-link COFF map).
             * Build-29+ wishlist item 2. */
            if (is_windows_target &&
                (starts_with(a, "-Wl,-Map,") || starts_with(a, "-Wl,-Map="))) {
                const char *file = a + 9; /* skip "-Wl,-Map," / "-Wl,-Map=" (both 9) */
                if (file[0] != '\0') {
                    char *rewritten = make_wl_msvc("/MAP:", file);
                    DBG("REWROTE (-Wl,-Map): %s -> %s\n", a, rewritten);
                    filtered[fi++] = rewritten;
                    continue;
                }
                /* "-Wl,-Map," with no file -- fall through */
            }

            /* P-5b: bare -Map=FILE (flexlink strips the -Wl, prefix) -> -Wl,/MAP:FILE.
             * zig cc rejects bare -Map ("Unknown Clang option: '-Map'"). Build-29+ wishlist item 2. */
            if (is_windows_target && starts_with(a, "-Map=")) {
                const char *file = a + 5; /* skip "-Map=" */
                if (file[0] != '\0') {
                    char *rewritten = make_wl_msvc("/MAP:", file);
                    DBG("REWROTE (bare -Map=): %s -> %s\n", a, rewritten);
                    filtered[fi++] = rewritten;
                    continue;
                }
            }

            /* P-5c: bare two-token "-Map FILE" (flexlink) -> -Wl,/MAP:FILE. Consume the next argv token. */
            if (is_windows_target && str_eq(a, "-Map") && i + 1 < argc) {
                const char *file = argv[++i]; /* consume FILE token */
                char *rewritten = make_wl_msvc("/MAP:", file);
                DBG("REWROTE (bare -Map): %s %s -> %s\n", a, file, rewritten);
                filtered[fi++] = rewritten;
                continue;
            }

            /* -Wl,* drops: only when not using LLD (LLD handles them natively) */
            if (!use_lld && is_wl_drop(a)) {
                DBG("DROPPED (wl_drop): %s\n", a);
                continue;
            }

            /* Standalone drops */
            if (is_drop_flag(a)) {
                DBG("DROPPED (drop_flag): %s\n", a);
                continue;
            }

            /* MSVC manifest flags */
            if (is_manifest_flag(a)) {
                DBG("DROPPED (manifest): %s\n", a);
                continue;
            }

            /* -nostdlib++: downgrade c++ -> cc */
            if (str_eq(a, "-nostdlib++")) {
                saw_nostdlibxx = 1;
                continue;
            }

            /* -fuse-ld=lld: strip from user args; re-inject below if use_lld */
            if (str_eq(a, "-fuse-ld=lld")) {
                DBG("STRIPPED (fuse-ld): will re-inject if use_lld\n");
                continue;
            }

            /* P-Force-Load: strip force-load flags (archives already extracted above).
             * Flag stripping compiles on all platforms; stat-based .a dropping is
             * Unix-only (S_ISREG not available on MSVC). On Windows is_force_load_mode
             * is always 0 so this whole block is dead code anyway. */
            if (is_force_load_mode) {
                if (str_eq(a, "-Wl,-all_load") || str_eq(a, "-all_load")) {
                    DBG("DROPPED (force-load flag): %s\n", a);
                    continue;
                }
                if (starts_with(a, "-Wl,-force_load,")) {
                    DBG("DROPPED (force-load flag): %s\n", a);
                    continue;
                }
                if (str_eq(a, "-force_load")) {
                    /* Two-arg form: skip this arg and the following path */
                    DBG("DROPPED (force-load flag): %s\n", a);
                    if (i + 1 < argc) i++; /* consume path arg */
                    continue;
                }
#ifndef _WIN32
                /* In all_load mode, drop bare .a positional args that were extracted */
                if (n_extracted > 0) {
                    size_t alen = strlen(a);
                    if (alen > 2 && a[alen - 2] == '.' && a[alen - 1] == 'a') {
                        struct stat st;
                        if (stat(a, &st) == 0 && S_ISREG(st.st_mode)) {
                            DBG("DROPPED (all_load .a): %s\n", a);
                            continue;
                        }
                    }
                }
#endif /* !_WIN32 */
            }

            filtered[fi++] = a;
        }

        /* Downgrade mode when -nostdlib++ seen */
        if (saw_nostdlibxx && mode == MODE_CXX) {
            /* Overwrite the subcommand we already pushed */
            new_argv[ni - 1] = "cc";
        }

        /* Inject -fuse-ld=lld if LLD-triggering flags were found */
        if (use_lld) {
            new_argv[ni++] = "-fuse-ld=lld";
            DBG("injected -fuse-ld=lld\n");
        }

        /* Inject -target if not supplied by user */
        if (!has_target && ZIG_TARGET[0] != '\0' && ZIG_TARGET[0] != '@') {
            new_argv[ni++] = "-target";
            new_argv[ni++] = ZIG_TARGET;
            DBG("injected -target %s\n", ZIG_TARGET);
        }

        /* Inject -mcpu=baseline if not overridden */
        if (!has_mcpu) {
            new_argv[ni++] = "-mcpu=baseline";
            DBG("injected -mcpu=baseline\n");
        }

        /* Append filtered args */
        for (int i = 0; i < fi; i++) {
            new_argv[ni++] = (char *)filtered[i];
        }

        /* Append extracted .o files from force-load (Unix only) */
        if (n_extracted > 0) {
            /* Grow new_argv to accommodate extracted objects + NULL sentinel */
            char **bigger = (char **)realloc(new_argv,
                (size_t)(ni + n_extracted + 1) * sizeof(char *));
            if (!bigger) { perror("zig-wrapper: realloc"); exit(1); }
            new_argv = bigger;
            for (int i = 0; i < n_extracted; i++) {
                new_argv[ni++] = extracted_objects[i];
                DBG("appended extracted: %s\n", extracted_objects[i]);
            }
        }

    } else {
        /* --- DISPATCH / tool modes: inject -target if applicable, pass args through --- */

        if (allow_target && !user_has_target(argc, argv, user_args_start)
                && ZIG_TARGET[0] != '\0' && ZIG_TARGET[0] != '@') {
            new_argv[ni++] = "-target";
            new_argv[ni++] = ZIG_TARGET;
            DBG("injected -target %s\n", ZIG_TARGET);
        }

        for (int i = user_args_start; i < argc; i++) {
            const char *a = argv[i];

            /* P-1: windres compat: zig rc requires -fo, not -o */
            if (mode == MODE_RC) {
                if (strcmp(a, "-o") == 0) {
                    new_argv[ni++] = (char *)"-fo";
                    continue;
                }
                if (a[0] == '-' && a[1] == 'o' && a[2] != '\0') {
                    /* -o<path> form: rewrite to -fo<path> */
                    size_t rest_len = strlen(a + 2);
                    char *rewritten = (char *)malloc(rest_len + 4);
                    if (!rewritten) { perror("malloc"); exit(1); }
                    memcpy(rewritten, "-fo", 3);
                    memcpy(rewritten + 3, a + 2, rest_len + 1);
                    new_argv[ni++] = rewritten;
                    continue;
                }
            }

            new_argv[ni++] = (char *)a;
        }
    }

    new_argv[ni] = NULL;
    free(filtered);
    free(extracted_objects); /* strings themselves are owned by new_argv / exec */

    if (debug_enabled) {
        DBG("exec: %s\n", zig_path);
        for (int i = 0; i < ni; i++) DBG("  out argv[%d]=%s\n", i, new_argv[i]);
    }

#ifdef _WIN32
    int rc = (int)_spawnv(_P_WAIT, zig_path, (const char *const *)new_argv);
    free(new_argv);
    if (rc < 0) {
        fprintf(stderr, "zig-wrapper: failed to spawn '%s' (errno=%d)\n", zig_path, errno);
        perror("zig-wrapper: _spawnv");
        return 1;
    }
    return rc;
#else
    execv(zig_path, new_argv);
    fprintf(stderr, "zig-wrapper: failed to exec '%s' (errno=%d)\n", zig_path, errno);
    perror("zig-wrapper: execv");
    free(new_argv);
    return 1;
#endif
}
