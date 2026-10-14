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
 * The R1-R9 de-dup rules (see recipe/building/flag_rules.py) are delegated
 * to the generated, portable zig_translate_flags() (_translate.inc). Only
 * out-of-scope hand-written translations/drops remain below: -Wl,-e<sym>
 * entry-symbol translation, -l:<file> exact-filename resolution against
 * -L dirs, MSVC /MANIFEST* drops, GCC-only flag drops, the non-Bsymbolic
 * -Xlinker pair drop, and the LLD-trigger scans not owned by R8/R9
 * (--version-script/--dynamic-list/--gc-sections/--build-id/
 * --allow-shlib-undefined).
 *
 * Placeholders replaced at install time:
 *   ZIG_CC_MODE      - "cc" or "c++"
 *   ZIG_BIN_NAME     - zig binary filename (e.g. x86_64-w64-mingw32-zig.exe)
 *   ZIG_TARGET       - zig target triplet (e.g. x86_64-windows-msvc)
 *   ZIG_TARGET_ARCH  - zig target arch (e.g. "x86_64", "aarch64")
 *
 * Compiled during package build with zig cc.
 */

#include "nonunix_common.h"
#include "nonunix_spawn.h"
#include "_translate.inc"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <process.h>
#include <windows.h>

#define ZIG_CC_MODE "@ZIG_CC_MODE@"
#define ZIG_BIN_NAME "@ZIG_BIN_NAME@"
#define ZIG_TARGET "@ZIG_TARGET@"
#define ZIG_TARGET_ARCH "@ZIG_TARGET_ARCH@"
#define IS_MINGW_TARGET @IS_MINGW_TARGET@

/* --- Flag classification helpers --- */
static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

/*
 * Translate -Wl,-e<sym> and -Wl,-e,<sym> to -Wl,--entry,<sym> on mingw targets.
 * GNU long form (--entry,SYM) works on mingw via clang's GNU-emulation driver;
 * /ENTRY: (MSVC) does not. zig cc forwards -Wl,-e<sym> verbatim which clang's
 * GNU-ld arg parser rejects as "Unknown Clang option: '-eSYM'".
 *
 * Returns:
 *   NULL if the arg is not -Wl,-e<sym> or -Wl,-e,<sym>, or if not on mingw.
 *   Heap-allocated translated string (caller must NOT free; ownership transferred to argv) otherwise.
 *
 * Forms handled:
 *   -Wl,-eSYM   (concat, 7+ chars)
 *   -Wl,-e,SYM  (comma form, 8+ chars)
 * Split form (-Wl,-e in one arg, -Wl,SYM in next) is NOT handled; deferred.
 */
static char *translate_wl_entry(const char *arg)
{
    if (!IS_MINGW_TARGET) return NULL;
    if (strncmp(arg, "-Wl,-e", 6) != 0) return NULL;
    const char *sym = NULL;
    if (arg[6] == ',' && arg[7] != '\0') sym = arg + 7;
    else if (arg[6] != '\0' && arg[6] != ',') sym = arg + 6;
    else return NULL;
    size_t len = strlen("-Wl,--entry,") + strlen(sym) + 1;
    char *out = (char *)malloc(len);
    if (!out) return NULL;
    snprintf(out, len, "-Wl,--entry,%s", sym);
    return out;
}

/*
 * Collect -L search directories from argv, in order, handling both the
 * spaced (-L <dir>) and concatenated (-L<dir>) forms. Used to resolve
 * -l:<file> tokens (see resolve_l_colon). Caller owns *out_dirs (free()).
 */
static void collect_l_dirs(char *const *argv, int argc, const char ***out_dirs, int *out_n) {
    const char **dirs = (const char **)malloc(sizeof(char *) * (size_t)(argc + 1));
    int n = 0;
    if (dirs) {
        for (int i = 0; i < argc; i++) {
            const char *a = argv[i];
            if (str_eq(a, "-L")) {
                if (i + 1 < argc) dirs[n++] = argv[++i];
            } else if (starts_with(a, "-L") && a[2] != '\0') {
                dirs[n++] = a + 2;
            }
        }
    }
    *out_dirs = dirs;
    *out_n = n;
}

/*
 * GNU ld/gcc -l:<file> means: search the -L dirs in order for a file with
 * that EXACT name and link it as an input file. Resolving it here (instead
 * of forwarding -l:<file> to zig) preserves that semantics exactly and
 * avoids zig 0.17's driver panic ("reached unreachable code") on the -l:
 * token. Returns a malloc'd resolved path (first match wins), or NULL if
 * not found in any -L dir. On malloc failure sets *oom = 1 and returns
 * NULL, distinct from the not-found case (*oom = 0).
 */
static char *resolve_l_colon(const char *filename, const char **dirs, int n_dirs, int *oom) {
    *oom = 0;
    size_t max_dir_len = 0;
    for (int i = 0; i < n_dirs; i++) {
        size_t len = strlen(dirs[i]);
        if (len > max_dir_len) max_dir_len = len;
    }
    size_t buf_size = max_dir_len + 1 + strlen(filename) + 1;
    char *scratch = (char *)malloc(buf_size);
    if (!scratch) {
        *oom = 1;
        return NULL;
    }
    char *result = NULL;
    for (int i = 0; i < n_dirs; i++) {
        snprintf(scratch, buf_size, "%s/%s", dirs[i], filename);
        FILE *f = fopen(scratch, "rb");
        if (f) {
            fclose(f);
            result = (char *)malloc(strlen(scratch) + 1);
            if (result) strcpy(result, scratch);
            else *oom = 1;
            break;
        }
    }
    free(scratch);
    return result;
}

/* -Xlinker passthrough flags to drop.
 * -Bsymbolic-functions/-Bsymbolic are intentionally NOT listed here: R8
 * inside zig_translate_flags() owns keep+use_lld handling for the -Xlinker
 * Bsymbolic pair, and this pre-filter runs BEFORE the generated call, so
 * dropping them here would silently defeat R8 (a -Xlinker -Bsymbolic pair
 * must pass through to reach zig_tr_is_xlinker_bsymbolic). */
static int is_xlinker_drop(const char *arg) {
    return str_eq(arg, "--color-diagnostics") ||
           starts_with(arg, "--dependency-file=");
}

/* -Wl,* flags to drop (entire arg) -- kept out-of-scope members only.
 * --color-diagnostics/-Wl,-rpath-link (prefix) / --disable-new-dtags (R7) and
 * -Wl,-Bsymbolic(-functions) (R8) are now handled inside
 * zig_translate_flags(). */
static int is_wl_drop(const char *arg) {
    if (!starts_with(arg, "-Wl,"))
        return 0;
    return str_eq(arg, "-Wl,--allow-shlib-undefined") ||
           str_eq(arg, "-Wl,--no-allow-shlib-undefined") ||
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

/* MSVC/LLD manifest flags to drop (/MANIFEST*, -MANIFEST*).
 * CMake injects /MANIFEST:NO, /MANIFESTUAC:NO, /MANIFESTINPUT:..., etc.
 * These are PE/COFF linker flags; zig cc forwards them to lld-link which
 * may reject or misparse them when the cc wrapper re-invokes zig cc. */
static int is_manifest_flag(const char *arg) {
    if (arg[0] != '/' && arg[0] != '-')
        return 0;
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

/* Flags that trigger auto-promotion to LLD (unsupported by self-hosted
 * linker) -- kept out-of-scope members only. -Wl,-Bsymbolic(-functions)/
 * bare -Bsymbolic(-functions) (R8) and -Wl,-z,defs|nodelete (R9) are now
 * handled inside zig_translate_flags(); its out_use_lld must be OR'd with
 * this scan's result by the caller. */
static int is_lld_trigger(const char *arg) {
    if (str_eq(arg, "-fuse-ld=lld")) return 1;
    /* ELF flags (-Wl, prefixed) */
    if (starts_with(arg, "-Wl,--version-script")) return 1;
    if (starts_with(arg, "-Wl,--dynamic-list")) return 1;
    if (str_eq(arg, "-Wl,--gc-sections") || str_eq(arg, "-Wl,--no-gc-sections")) return 1;
    if (starts_with(arg, "-Wl,--build-id")) return 1;
    if (str_eq(arg, "-Wl,--allow-shlib-undefined") || str_eq(arg, "-Wl,--no-allow-shlib-undefined")) return 1;
    return 0;
}

/* Bare linker args that trigger LLD (passed via -Xlinker <arg>) */
static int is_xlinker_lld_trigger(const char *arg) {
    if (starts_with(arg, "--dynamic-list") || starts_with(arg, "--version-script")) return 1;
    if (str_eq(arg, "--gc-sections") || str_eq(arg, "--no-gc-sections")) return 1;
    if (starts_with(arg, "--build-id")) return 1;
    if (str_eq(arg, "--allow-shlib-undefined") || str_eq(arg, "--no-allow-shlib-undefined")) return 1;
    return 0;
}

/* --- Find zig binary --- */
static int find_zig(char *out, size_t out_size) {
    return zig_find_in_prefixes(out, out_size, ZIG_BIN_NAME) != NULL;
}

/* --- x86_64 mingw C++ runtime: conda-forge GCC libstdc++, not zig libc++ --- */

#define CXX_PATH_MAX 1024
#define GCC_TRIPLET "x86_64-w64-mingw32"

static int cxx_runtime_optout(int argc, char **argv) {
    const char *rt = getenv("ZIG_CXX_RUNTIME");
    if (rt && str_eq(rt, "zig"))
        return 1;
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (str_eq(a, "-nostdlib++") || str_eq(a, "-nostdlib") ||
            str_eq(a, "-nodefaultlibs") || starts_with(a, "-stdlib=") ||
            str_eq(a, "-nostdinc++") || str_eq(a, "-nostdinc") ||
            str_eq(a, "-static") || str_eq(a, "-static-libstdc++"))
            return 1;
    }
    return 0;
}

static int path_is_dir(const char *p) {
    DWORD a = GetFileAttributesA(p);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

static int path_is_file(const char *p) {
    DWORD a = GetFileAttributesA(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

/* 1 if the invocation links: no compile-only/query flag and at least one
 * existing input file (or @response file). */
static int invocation_links(const char **args, int n) {
    int has_input = 0;
    for (int i = 0; i < n; i++) {
        const char *a = args[i];
        if (str_eq(a, "-c") || str_eq(a, "-S") || str_eq(a, "-E") ||
            str_eq(a, "-M") || str_eq(a, "-MM") || str_eq(a, "-fsyntax-only") ||
            str_eq(a, "-###") || str_eq(a, "--version") || str_eq(a, "--help") ||
            starts_with(a, "-print-") || starts_with(a, "-dump"))
            return 0;
        if (a[0] == '@' ? path_is_file(a + 1) : (a[0] != '-' && path_is_file(a)))
            has_input = 1;
    }
    return has_input;
}

/* Numeric compare of dotted version strings (digits and dots only). */
static int version_cmp(const char *a, const char *b) {
    while (*a || *b) {
        char *ea, *eb;
        long x = strtol(a, &ea, 10), y = strtol(b, &eb, 10);
        if (x != y)
            return x < y ? -1 : 1;
        a = *ea == '.' ? ea + 1 : ea;
        b = *eb == '.' ? eb + 1 : eb;
    }
    return 0;
}

/* <prefix>\Library\lib\gcc\<triplet>\<highest version with include\c++>. */
static int find_gcc_dir(const char *prefix, char *out, size_t outsz) {
    char base[CXX_PATH_MAX], pat[CXX_PATH_MAX], probe[CXX_PATH_MAX], best[64] = "";
    int n = snprintf(base, sizeof base, "%s\\Library\\lib\\gcc\\" GCC_TRIPLET, prefix);
    if (n <= 0 || (size_t)n >= sizeof base)
        return -1;
    snprintf(pat, sizeof pat, "%s\\*", base);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE)
        return -1;
    do {
        const char *v = fd.cFileName;
        size_t vl = strlen(v);
        if (!vl || v[0] == '.' || strspn(v, "0123456789.") != vl || vl >= sizeof best)
            continue;
        n = snprintf(probe, sizeof probe, "%s\\%s\\include\\c++", base, v);
        if (n <= 0 || (size_t)n >= sizeof probe || !path_is_dir(probe))
            continue;
        if (!best[0] || version_cmp(v, best) > 0)
            memcpy(best, v, vl + 1);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    if (!best[0])
        return -1;
    n = snprintf(out, outsz, "%s\\%s", base, best);
    return (n > 0 && (size_t)n < outsz) ? 0 : -1;
}

static char cxx_slots[6][CXX_PATH_MAX];

__attribute__((format(printf, 2, 3)))
static const char *cxx_fmt(int slot, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(cxx_slots[slot], CXX_PATH_MAX, fmt, ap);
    va_end(ap);
    return (n > 0 && n < CXX_PATH_MAX) ? cxx_slots[slot] : NULL;
}

/* Fill pre (before user args, at most 1) and post (after, at most 7) with the
 * flags that build C++ against the GCC libstdc++ under <prefix>; returns 0
 * (zig libc++ kept) if it is not found.  reset_x: user args set -x, so end it
 * before the appended libs.  Full paths, never -l: _mingw.sh ships empty
 * libstdc++.a/libgcc stubs a -l lookup could hit. */
static int mingw_libstdcxx_args(const char *prefix, int links, int reset_x,
                                const char **pre, int *n_pre,
                                const char **post, int *n_post) {
    char gcc[CXX_PATH_MAX];
    const char *dbg = getenv("DEBUG_ZIG_BUILD");
    const char *i1 = NULL, *i2 = NULL, *l1 = NULL, *l2 = NULL, *l3 = NULL;
    if (prefix && find_gcc_dir(prefix, gcc, sizeof gcc) == 0) {
        i1 = cxx_fmt(0, "-isystem%s\\include\\c++", gcc);
        i2 = cxx_fmt(1, "-isystem%s\\include\\c++\\" GCC_TRIPLET, gcc);
        l1 = cxx_fmt(2, "%s\\libstdc++.dll.a", gcc);
        l2 = cxx_fmt(3, "%s\\libgcc_s.a", gcc);
        l3 = cxx_fmt(4, "%s\\Library\\lib\\libwinpthread.dll.a", prefix);
    }
    if (!i1 || !i2 || !l1 || !path_is_file(l1)) {
        if (dbg && str_eq(dbg, "1"))
            fprintf(stderr, "zig-wrapper: no GCC libstdc++ for " GCC_TRIPLET
                            " under '%s'; using zig libc++\n", prefix ? prefix : "");
        return 0;
    }
    pre[(*n_pre)++] = "-nostdlib++";
    post[(*n_post)++] = i1;
    post[(*n_post)++] = i2;
    if (links) {
        if (reset_x) {
            post[(*n_post)++] = "-x";
            post[(*n_post)++] = "none";
        }
        post[(*n_post)++] = l1;
        if (l2 && path_is_file(l2))
            post[(*n_post)++] = l2;
        if (l3 && path_is_file(l3))
            post[(*n_post)++] = l3;
    }
    return 1;
}

int main(int argc, char *argv[]) {
    init_zig_global_cache_dir();

    /* Translate profile's prefix, resolved PREFIX-first against the
     * `Library\lib\zig` marker -- same approach find_zig() uses for the binary. */
    const char *conda_prefix = zig_prefix_with_subpath("Library\\lib\\zig");

    /* Pre-filter over the raw args (argv[0] excluded):
     *  - drop -Xlinker <arg> pairs not owned by the generated translator
     *    (--color-diagnostics / --dependency-file=*; Bsymbolic pairs are
     *    intentionally excluded here, see is_xlinker_drop doc comment)
     *  - scan for the LLD triggers that stay out of R8/R9 scope
     *    (-Wl,--version-script/-Wl,--dynamic-list/-Wl,--gc-sections/
     *    -Wl,--build-id/-Wl,--allow-shlib-undefined and their bare
     *    -Xlinker <arg> equivalents)
     */
    const char **pre_argv = malloc(sizeof(char *) * (size_t)(argc + 1));
    if (!pre_argv) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        return 1;
    }
    int pi = 0;
    int use_lld_extra = 0;
    {
        int grab_next = 0;
        for (int i = 1; i < argc; i++) {
            const char *arg = argv[i];

            if (is_lld_trigger(arg)) use_lld_extra = 1;
            if (str_eq(arg, "-Xlinker") && i + 1 < argc && is_xlinker_lld_trigger(argv[i + 1]))
                use_lld_extra = 1;

            if (grab_next) {
                grab_next = 0;
                if (!is_xlinker_drop(arg)) {
                    pre_argv[pi++] = "-Xlinker";
                    pre_argv[pi++] = arg;
                }
                continue;
            }

            if (str_eq(arg, "-Xlinker")) {
                grab_next = 1;
                continue;
            }

            pre_argv[pi++] = arg;
        }
    }

    /* --- Delegate the 9 de-dup rules (R1-R9) to the generated translator --- */
    zig_translate_profile profile;
    profile.is_win = 1;
    profile.is_win_target = IS_MINGW_TARGET;
    profile.conda_prefix = conda_prefix;
    profile.zig_target_arch = ZIG_TARGET_ARCH;

    int mode_is_cxx = str_eq(ZIG_CC_MODE, "c++");
    int cxx_gcc_wanted = mode_is_cxx && IS_MINGW_TARGET &&
                         str_eq(ZIG_TARGET_ARCH, "x86_64") &&
                         !cxx_runtime_optout(argc - 1, argv + 1);
    char **out_argv = NULL;
    int out_argc = 0;
    int use_lld_from_gen = 0;
    int tr_rc = zig_translate_flags(pi, (char *const *)pre_argv, &profile,
                                     &out_argv, &out_argc, &use_lld_from_gen,
                                     &mode_is_cxx);
    free(pre_argv);

    /* R2/R3 (-print-search-dirs / -print-file-name=) already printed to
     * stdout inside zig_translate_flags(); exit immediately. */
    if (tr_rc == 2)
        return 0;
    if (tr_rc != 0) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        return 1;
    }

    /* Merge the generated fn's own R8/R9 trigger scan with the hand-written
     * out-of-scope scan above. */
    int use_lld = use_lld_from_gen || use_lld_extra;

    /* Default -target injection later must only fire if the generated
     * out_argv (R5) has no -target/--target= of its own. */
    int has_target = 0;
    for (int i = 0; i < out_argc; i++) {
        if (str_eq(out_argv[i], "-target") || starts_with(out_argv[i], "--target=")) {
            has_target = 1;
            break;
        }
    }

    /* Find zig binary */
    char zig_path[MAX_PATH];
    if (!find_zig(zig_path, MAX_PATH)) {
        fprintf(stderr, "ERROR: zig-%s: zig binary not found (%s)\n",
                ZIG_CC_MODE, ZIG_BIN_NAME);
        fprintf(stderr, "  PREFIX=%s\n",
                getenv("PREFIX") ? getenv("PREFIX") : "(unset)");
        fprintf(stderr, "  CONDA_PREFIX=%s\n",
                conda_prefix ? conda_prefix : "(unset)");
        free(out_argv);
        return 1;
    }

    /* -L search dirs for -l:<file> resolution below, collected from the
     * same argv the second pass iterates (order preserved through
     * zig_translate_flags, which does not touch -L). */
    const char **l_dirs = NULL;
    int n_l_dirs = 0;
    collect_l_dirs(out_argv, out_argc, &l_dirs, &n_l_dirs);

    /* Second pass over the generated output: hand-written translations and
     * drops that stay out of R1-R9 scope (-Wl,-e<sym> entry rewrite, -l:<file>
     * exact-filename resolution, the 11 out-of-scope -Wl,* drops, GCC-only
     * drops, MSVC manifest drops, and the self-injected -fuse-ld=lld). */
    const char **filtered = malloc(sizeof(char *) * (size_t)(out_argc + 1));
    if (!filtered) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        free(out_argv);
        free(l_dirs);
        return 1;
    }
    int fi = 0;
    for (int i = 0; i < out_argc; i++) {
        const char *arg = out_argv[i];

        /* -Wl,-e<sym> translation: rewrite to -Wl,--entry,<sym> on mingw */
        {
            char *translated = translate_wl_entry(arg);
            if (translated) {
                filtered[fi++] = translated;
                continue;
            }
        }

        /* -l:<file> resolution: zig's driver panics ("reached unreachable
         * code") on this GNU exact-filename token. Resolve it against the
         * -L dirs ourselves and pass the resolved path instead; a token
         * that resolves nowhere is a hard error, not a silent passthrough
         * into the panic. */
        if (starts_with(arg, "-l:") && arg[3] != '\0') {
            const char *filename = arg + 3;
            int oom = 0;
            char *resolved = resolve_l_colon(filename, l_dirs, n_l_dirs, &oom);
            if (!resolved) {
                if (oom) {
                    fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
                } else if (n_l_dirs == 0) {
                    fprintf(stderr,
                            "ERROR: zig-%s: -l:%s not found: no -L directories were given "
                            "on the command line, so the exact-filename token could not be "
                            "resolved.\n",
                            ZIG_CC_MODE, filename);
                } else {
                    fprintf(stderr,
                            "ERROR: zig-%s: -l:%s not found. Searched %d -L directories:\n",
                            ZIG_CC_MODE, filename, n_l_dirs);
                    for (int di = 0; di < n_l_dirs; di++)
                        fprintf(stderr, "  %s\n", l_dirs[di]);
                }
                free(filtered);
                free(out_argv);
                free(l_dirs);
                return 1;
            }
            filtered[fi++] = resolved;
            continue;
        }

        /* -Wl,* drops -- skip if LLD promoted (LLD handles these) */
        if (!use_lld && is_wl_drop(arg))
            continue;

        /* Standalone drops */
        if (is_drop_flag(arg))
            continue;

        /* MSVC manifest flags -- drop silently (PE/COFF linker flags that
         * lld-link does not accept when forwarded through zig cc) */
        if (is_manifest_flag(arg))
            continue;

        /* Skip -fuse-ld=lld from filtered (we inject it ourselves) */
        if (str_eq(arg, "-fuse-ld=lld"))
            continue;

        filtered[fi++] = arg;
    }
    free(out_argv);
    free(l_dirs);

    /* Determine final mode (R4 -nostdlib++ downgrade already applied
     * inside zig_translate_flags()) */
    const char *mode = mode_is_cxx ? "c++" : "cc";

    /* x86_64 mingw c++ builds against conda-forge's GCC libstdc++ via
     * `zig cc -nostdlib++`; ZIG_CXX_RUNTIME=zig keeps zig's libc++. */
    const char *cxx_pre[1];
    const char *cxx_post[7];
    int n_cxx_pre = 0, n_cxx_post = 0;
    if (cxx_gcc_wanted && !has_target) {
        int reset_x = 0;
        for (int i = 0; i < fi; i++)
            if (starts_with(filtered[i], "-x")) { reset_x = 1; break; }
        if (mingw_libstdcxx_args(conda_prefix, invocation_links(filtered, fi), reset_x,
                                 cxx_pre, &n_cxx_pre, cxx_post, &n_cxx_post))
            mode = "cc";
    }

    /* Build final argv: zig mode [-nostdlib++] [-fuse-ld=lld] [-target TARGET]
     * <filtered...> [libstdc++ flags] */
    int max_args = fi + 8 + n_cxx_pre + n_cxx_post;
    const char **new_argv = malloc(sizeof(char *) * max_args);
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        free(filtered);
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_path;
    new_argv[ni++] = mode;
    for (int i = 0; i < n_cxx_pre; i++)
        new_argv[ni++] = cxx_pre[i];
    if (use_lld)
        new_argv[ni++] = "-fuse-ld=lld";
    if (!has_target) {
        new_argv[ni++] = "-target";
        new_argv[ni++] = ZIG_TARGET;
    }

    for (int i = 0; i < fi; i++)
        new_argv[ni++] = filtered[i];
    for (int i = 0; i < n_cxx_post; i++)
        new_argv[ni++] = cxx_post[i];

    new_argv[ni] = NULL;

    restore_msys2_system32_path();

    /* Test-observability hook: print the final argv instead of spawning. */
    const char *print_argv = getenv("ZIG_WRAPPER_PRINT_ARGV");
    if (print_argv && *print_argv && strcmp(print_argv, "0") != 0) {
        for (int i = 0; new_argv[i]; i++)
            printf("%s\n", new_argv[i]);
        fflush(stdout);
        free(filtered);
        free(new_argv);
        return 0;
    }

    /* Execute zig */
    int ret = zig_spawn_wait(zig_path, (const char *const *)new_argv);
    free(filtered);
    free(new_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: zig-%s: failed to exec %s: %s\n",
                ZIG_CC_MODE, zig_path, strerror(errno));
        return 1;
    }
    return ret;
}
