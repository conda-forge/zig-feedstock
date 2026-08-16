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
 * entry-symbol translation, MSVC /MANIFEST* drops, GCC-only flag drops,
 * the non-Bsymbolic -Xlinker pair drop, and the LLD-trigger scans not
 * owned by R8/R9 (--version-script/--dynamic-list/--gc-sections/
 * --build-id/--allow-shlib-undefined).
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
#include "_translate.inc"
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

    /* One CONDA_PREFIX getenv() call for the translate profile; the
     * pre-existing getenv("CONDA_PREFIX") calls inside find_zig() are left
     * untouched. */
    const char *conda_prefix = getenv("CONDA_PREFIX");

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
    profile.sysroot = NULL;  /* R12 is unix-only; the win shim has no sysroot concept. */

    int mode_is_cxx = str_eq(ZIG_CC_MODE, "c++");
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
        fprintf(stderr, "  CONDA_PREFIX=%s\n",
                conda_prefix ? conda_prefix : "(unset)");
        free(out_argv);
        return 1;
    }

    /* Second pass over the generated output: hand-written translations and
     * drops that stay out of R1-R9 scope (-Wl,-e<sym> entry rewrite, the
     * 11 out-of-scope -Wl,* drops, GCC-only drops, MSVC manifest drops,
     * and the self-injected -fuse-ld=lld). */
    const char **filtered = malloc(sizeof(char *) * (size_t)(out_argc + 1));
    if (!filtered) {
        fprintf(stderr, "ERROR: zig-%s: malloc failed\n", ZIG_CC_MODE);
        free(out_argv);
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

    /* Determine final mode (R4 -nostdlib++ downgrade already applied
     * inside zig_translate_flags()) */
    const char *mode = mode_is_cxx ? "c++" : "cc";

    /* Build final argv: zig mode [-fuse-ld=lld] [-target TARGET] <filtered...> */
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
    if (use_lld)
        new_argv[ni++] = "-fuse-ld=lld";
    if (!has_target) {
        new_argv[ni++] = "-target";
        new_argv[ni++] = ZIG_TARGET;
    }

    for (int i = 0; i < fi; i++)
        new_argv[ni++] = filtered[i];

    new_argv[ni] = NULL;

    restore_msys2_system32_path();

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
