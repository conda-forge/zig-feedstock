/*
 * unix toolchain wrapper: a busybox-style multiplexer.
 *
 * ONE binary, compiled once at install time and cp -f'd to each wrapper name.
 * The tool is selected by basename(argv[0]) with @WRAPPER_PREFIX@ stripped:
 *
 *   zig-cc       -> zig cc   + full flag filtering  (see run_cc)
 *   zig-cxx      -> zig c++  + full flag filtering  (see run_cc)
 *   zig-ar       -> zig ar,     thin-archive 'T' modifier stripped
 *   zig-ranlib   -> zig ranlib, passthrough
 *   zig-rc       -> zig rc,     passthrough
 *   zig-lld      -> zig ld.lld / ld64.lld by platform
 *   zig-windres  -> zig rc,     -o/-o<x> rewritten to -fo/-fo<x>
 *   zig-asm      -> zig cc -target <t> -mcpu=baseline [-isysroot <sr>]
 *   zig-force-load-cc  -> alias of zig-cc   (see STEP 10b in run_cc)
 *   zig-force-load-cxx -> alias of zig-cxx  (see STEP 10b in run_cc)
 *
 * Replaces recipe/scripts/{zig-cc,zig-cxx,zig-ar,zig-ranlib,zig-rc,zig-lld,
 * zig-windres,zig-asm,zig-force-load-cc,zig-force-load-cxx}.sh.  Each runner
 * below cites the bash file:line it replaces so the two stay auditable until
 * the bash wrappers are retired.
 *
 * run_cc() is a port of recipe/scripts/_zig-cc-common.sh (sourced by
 * zig-cc.sh / zig-cxx.sh).  Every numbered STEP inside it cites the bash line
 * range it replaces.  The R1-R13 de-dup rules (see recipe/building/
 * flag_rules.py) are delegated to the generated, portable
 * zig_translate_flags() (_translate.inc); only the out-of-scope hand-written
 * logic (sysroot, the extra LLD-trigger scan, the -Xlinker general pre-filter,
 * the ppc64le hard error, the GCC-only post-translation drops, and the macOS
 * deployment-target rewrite) remains there.
 *
 * Placeholders replaced at install time:
 *   ZIG_BIN          - baked zig path.  NOTE: install bakes the LITERAL
 *                      "${CONDA_PREFIX}/bin/<triplet>-zig"; C cannot expand
 *                      that, so it is resolved via zig_resolve_zig_bin(),
 *                      which prefers self-location.  See unix_common.h.
 *   ZIG_TARGET       - zig target triplet (e.g. x86_64-linux-gnu)
 *   ZIG_TARGET_ARCH  - zig target arch (e.g. "x86_64", "aarch64")
 *   WRAPPER_PREFIX   - installed-name prefix (e.g. "x86_64-conda-linux-gnu-")
 *
 * Compiled during package build with zig cc.
 */

#include "unix_common.h"
#include "_translate.inc"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define ZIG_BIN "@ZIG_BIN@"
#define ZIG_TARGET "@ZIG_TARGET@"
#define ZIG_TARGET_ARCH "@ZIG_TARGET_ARCH@"
#define WRAPPER_PREFIX "@WRAPPER_PREFIX@"

/* --- small string helpers --- */
static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + (ls - lx), suffix) == 0;
}

/* -all_load applies to archives actually present on the link line; mirrors
 * bash's `[[ "$_a" == *.a ]] && [[ -f "$_a" ]]`
 * (_zig-force-load-common.sh:66). */
static int is_regular_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static int str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

/* -Wl,-O[0-9]* glob: literal "-Wl,-O" followed by at least one digit,
 * then anything. _zig-cc-common.sh:73 -- this is a shell glob, not a
 * literal string; ported the same way _translate.inc:63-75 ports the
 * sibling -Wl,-O* case for R9. */
static int is_wl_o_digit(const char *arg) {
    if (!starts_with(arg, "-Wl,-O")) return 0;
    const char *suffix = arg + 6; /* strlen("-Wl,-O") */
    return suffix[0] != '\0' && isdigit((unsigned char)suffix[0]);
}

/*
 * Raw single-token LLD-trigger scan. Mirrors the outer `case "$_a" in`
 * arms at _zig-cc-common.sh:61-82, EXCLUDING the "-Xlinker) ..." arm
 * itself (line 62, handled separately by the -Xlinker lookahead below)
 * and EXCLUDING "-fuse-ld=lld" (checked by the caller directly, same
 * as bash line 63, folded in here for a single call site).
 */
static int is_lld_trigger(const char *arg) {
    if (str_eq(arg, "-fuse-ld=lld")) return 1;                                   /* :63 */
    if (str_eq(arg, "-Wl,--version-script") ||
        starts_with(arg, "-Wl,--version-script,")) return 1;                     /* :65 */
    if (str_eq(arg, "-Wl,--dynamic-list") ||
        starts_with(arg, "-Wl,--dynamic-list,") ||
        starts_with(arg, "-Wl,--dynamic-list=")) return 1;                       /* :66 */
    if (str_eq(arg, "-Wl,-z,defs") || str_eq(arg, "-Wl,-z,nodelete")) return 1;   /* :67 */
    if (str_eq(arg, "-Wl,--gc-sections") || str_eq(arg, "-Wl,--no-gc-sections")) return 1; /* :68 */
    if (str_eq(arg, "-Wl,--build-id") || starts_with(arg, "-Wl,--build-id=")) return 1;     /* :69 */
    if (str_eq(arg, "-Wl,--allow-shlib-undefined") ||
        str_eq(arg, "-Wl,--no-allow-shlib-undefined")) return 1;                 /* :70 */
    if (str_eq(arg, "-Wl,-Bsymbolic-functions") || str_eq(arg, "-Wl,-Bsymbolic")) return 1; /* :71 */
    if (str_eq(arg, "-Bsymbolic-functions") || str_eq(arg, "-Bsymbolic")) return 1;         /* :72 */
    if (is_wl_o_digit(arg)) return 1;                                            /* :73 */
    if (str_eq(arg, "-Wl,-exported_symbols_list") ||
        starts_with(arg, "-Wl,-exported_symbols_list,")) return 1;               /* :75 */
    if (str_eq(arg, "-Wl,-unexported_symbols_list") ||
        starts_with(arg, "-Wl,-unexported_symbols_list,")) return 1;             /* :76 */
    if (str_eq(arg, "-Wl,-reexported_symbols_list") ||
        starts_with(arg, "-Wl,-reexported_symbols_list,")) return 1;             /* :77 */
    if (str_eq(arg, "-Wl,-force_symbols_not_weak_list") ||
        starts_with(arg, "-Wl,-force_symbols_not_weak_list,")) return 1;         /* :78 */
    if (str_eq(arg, "-Wl,-force_symbols_weak_list") ||
        starts_with(arg, "-Wl,-force_symbols_weak_list,")) return 1;             /* :79 */
    if (str_eq(arg, "-Wl,-all_load") || starts_with(arg, "-Wl,-force_load,")) return 1;     /* :80 */
    if (str_eq(arg, "-all_load") || str_eq(arg, "-force_load")) return 1;        /* :81 */
    return 0;
}

/*
 * LLD-trigger set checked against the token immediately following a
 * literal "-Xlinker". Mirrors _zig-cc-common.sh:52-57. Note this list
 * is NOT identical to is_lld_trigger(): e.g. bare "--gc-sections" only
 * triggers here (as an -Xlinker argument), never as a standalone token.
 */
static int is_xlinker_lld_trigger(const char *arg) {
    if (str_eq(arg, "--dynamic-list") || starts_with(arg, "--dynamic-list=") ||
        str_eq(arg, "--version-script") || starts_with(arg, "--version-script=")) return 1; /* :52 */
    if (str_eq(arg, "--gc-sections") || str_eq(arg, "--no-gc-sections") ||
        str_eq(arg, "--build-id") || starts_with(arg, "--build-id=")) return 1;  /* :53 */
    if (str_eq(arg, "--allow-shlib-undefined") ||
        str_eq(arg, "--no-allow-shlib-undefined")) return 1;                     /* :54 */
    if (str_eq(arg, "-exported_symbols_list") ||
        starts_with(arg, "-exported_symbols_list,")) return 1;                   /* :55 */
    if (str_eq(arg, "-unexported_symbols_list") ||
        starts_with(arg, "-unexported_symbols_list,")) return 1;                 /* :56 */
    if (str_eq(arg, "-all_load") || str_eq(arg, "-force_load") ||
        starts_with(arg, "-force_load,")) return 1;                              /* :57 */
    return 0;
}

/* -Xlinker <arg> pairs to drop entirely (both tokens). _zig-cc-common.sh:104. */
static int is_xlinker_drop(const char *arg) {
    return str_eq(arg, "--color-diagnostics") || starts_with(arg, "--dependency-file=");
}

/* -l:libpthread.so* prefix match (GNU ld colon-exact-filename syntax). */
static int is_l_libpthread_so(const char *arg) {
    return starts_with(arg, "-l:libpthread.so");
}

/*
 * Post-translation drop filter: unix-only drops NOT covered by the
 * generated R1-R9 manifest (GCC-specific flags Clang rejects, GCC
 * runtime libs zig doesn't ship / can't link). Mirrors the `case "$_fa"
 * in` arms at _zig-cc-common.sh:142-159; everything not matched here is
 * kept (bash's `*) _final_args+=("$_fa") ;;` at :159).
 */
static int is_post_translate_drop(const char *arg) {
    return starts_with(arg, "-march=") || starts_with(arg, "-mtune=") ||
           str_eq(arg, "-ftree-vectorize") ||                                     /* :144 */
           str_eq(arg, "-fstack-protector-strong") ||
           str_eq(arg, "-fstack-protector") || str_eq(arg, "-fno-plt") ||         /* :145 */
           str_eq(arg, "-fno-partial-inlining") ||
           str_eq(arg, "-fno-ipa-cp-clone") ||                                    /* :146 */
           starts_with(arg, "-fdebug-prefix-map=") ||                             /* :147 */
           starts_with(arg, "-stdlib=") ||                                        /* :148 */
           str_eq(arg, "-lgcc_eh") || str_eq(arg, "-lgcc_s") ||                   /* :152 */
           str_eq(arg, "-l:libpthread.a") || is_l_libpthread_so(arg);             /* :158 */
}

/* Build a malloc'd "-L<sysroot><suffix>" flag. Exits the process on OOM
 * (no graceful unwind path exists this early in main()). */
static char *build_l_flag(const char *sysroot, const char *suffix) {
    size_t len = strlen("-L") + strlen(sysroot) + strlen(suffix) + 1;
    char *buf = (char *)malloc(len);
    if (!buf) {
        fprintf(stderr, "ERROR: zig-wrapper: malloc failed\n");
        exit(1);
    }
    snprintf(buf, len, "-L%s%s", sysroot, suffix);
    return buf;
}

/* zig-cc / zig-cxx.  Port of recipe/scripts/_zig-cc-common.sh.
 * argv is the FULL argv (argv[0] is the wrapper name); raw args start at 1,
 * exactly as before the multiplexer refactor. */
static int run_cc(const char *zig_bin, const char *prog, int mode_is_cxx,
                  int argc, char *argv[]) {
    int i;

    const char *conda_prefix = getenv("CONDA_PREFIX");

    /* ---- STEP 1 (_zig-cc-common.sh:29-38): sysroot detection ----
     * zig_resolve_sysroot() already encodes bash's `uname -s == Linux`
     * gate via #ifdef __linux__ (returns "" on other platforms), and
     * the CONDA_BUILD_SYSROOT fallback + is-a-directory probe are
     * folded into it. The returned string feeds profile.sysroot
     * REGARDLESS of whether it is a directory (R12 prints it verbatim,
     * see _translate.inc's zig_tr_print_sysroot); the -isysroot/-L
     * flag group below is gated separately on zig_sysroot_is_dir(). */
    int target_is_native = str_eq(ZIG_TARGET, "native");
    const char *sysroot = zig_resolve_sysroot(conda_prefix, ZIG_TARGET_ARCH, target_is_native);

    /* Exactly 6 slots: -isysroot, <sr>, and 4 -L flags -- a fixed,
     * known count (not a guessed bound), mirroring bash's fixed
     * 6-element _sysroot_flags group at :36. */
    const char *sysroot_flags[6];
    int n_sysroot_flags = 0;
    if (zig_sysroot_is_dir(sysroot)) {
        sysroot_flags[n_sysroot_flags++] = "-isysroot";
        sysroot_flags[n_sysroot_flags++] = sysroot;
        sysroot_flags[n_sysroot_flags++] = build_l_flag(sysroot, "/usr/lib64");
        sysroot_flags[n_sysroot_flags++] = build_l_flag(sysroot, "/usr/lib");
        sysroot_flags[n_sysroot_flags++] = build_l_flag(sysroot, "/lib64");
        sysroot_flags[n_sysroot_flags++] = build_l_flag(sysroot, "/lib");
    }

    /* ---- STEP 2+3 (_zig-cc-common.sh:45-83, :93-113): raw LLD-trigger
     * scan fused with the -Xlinker general pre-filter. Both are
     * independent passes over the SAME raw argv in bash (two separate
     * loops that don't share state), so fusing them into one loop is
     * behaviorally equivalent and mirrors zig-cc-nonunix.c's style.
     * bash's `break` on first LLD-trigger match is dropped (harmless:
     * OR-ing a boolean flag repeatedly is idempotent).
     *
     * grab_next is checked BEFORE the trigger checks (unlike
     * zig-cc-nonunix.c, which checks triggers first): bash's
     * _xlinker_next branch `continue`s immediately after matching
     * against the lookahead-only list, so a token that is itself being
     * CONSUMED as an -Xlinker value is never reprocessed as a fresh
     * "-Xlinker" trigger point even if it happens to equal the literal
     * string "-Xlinker" (e.g. pathological input "-Xlinker -Xlinker
     * foo"). This ordering is a deliberate deviation from
     * zig-cc-nonunix.c for exactness against the bash source -- see
     * report caveat (c). */
    int raw_argc = argc - 1;
    char **raw_argv = argv + 1;
    const char **pre_args = (const char **)malloc(sizeof(char *) * (size_t)(raw_argc + 1));
    if (!pre_args) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }
    int pi = 0;
    int use_lld_raw = 0;
    {
        int grab_next = 0;
        for (i = 0; i < raw_argc; i++) {
            const char *arg = raw_argv[i];

            if (grab_next) {
                grab_next = 0;
                if (is_xlinker_lld_trigger(arg)) use_lld_raw = 1;
                if (!is_xlinker_drop(arg)) {
                    pre_args[pi++] = "-Xlinker";
                    pre_args[pi++] = arg;
                }
                continue;
            }

            if (is_lld_trigger(arg)) use_lld_raw = 1;

            if (str_eq(arg, "-Xlinker")) {
                grab_next = 1;
                continue;
            }

            pre_args[pi++] = arg;
        }
        /* A trailing "-Xlinker" with no following token leaves
         * grab_next == 1 with the loop exhausted: it is simply never
         * appended, matching bash's dropped-trailing-token edge case
         * at :101 (the `if` guarding the next-token lookup fails). */
    }

    /* ---- STEP 4 (_zig-cc-common.sh:116-123): fill the translate
     * profile and delegate the R1-R9 de-dup rules to the generated
     * translator. ---- */
    zig_translate_profile profile;
    profile.is_win = 0;
    profile.is_win_target = strstr(ZIG_TARGET, "-windows-") != NULL; /* :120 */
    profile.conda_prefix = conda_prefix;
    profile.zig_target_arch = ZIG_TARGET_ARCH;
    profile.sysroot = sysroot;

    /* mode_is_cxx is the caller's parameter (:122, caller-owns-init per
     * _translate.inc); zig_translate_flags may flip it. */
    char **out_argv = NULL;
    int out_argc = 0;
    int use_lld_gen = 0;
    int tr_rc = zig_translate_flags(pi, (char *const *)pre_args, &profile,
                                     &out_argv, &out_argc, &use_lld_gen, &mode_is_cxx);
    free(pre_args);

    /* R2/R3/etc intercepts already printed to stdout; bash's
     * intercepts `exit 0`. */
    if (tr_rc == 2)
        return 0;
    if (tr_rc != 0) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }

    /* ---- STEP 5 (_zig-cc-common.sh:128): merge the generated fn's
     * own R8/R9 trigger scan with the hand-written out-of-scope scan
     * above. ---- */
    int use_lld = use_lld_raw || use_lld_gen;

    /* ---- STEP 6 (_zig-cc-common.sh:130-135): ppc64le hard error.
     * Both stderr lines below are VERBATIM from :132-133, including
     * the "zig cc:" prefix even in c++ mode -- the bash source hardcodes
     * it that way regardless of _ZIG_MODE, so it is reproduced as-is. */
    if (use_lld && str_eq(ZIG_TARGET_ARCH, "powerpc64le")) {
        fprintf(stderr, "zig cc: error: -fuse-ld=lld is not supported on ppc64le (LLD lacks ppc64le relocation support)\n");
        fprintf(stderr, "  Remove -fuse-ld=lld or any LLD-only flags (--dynamic-list, --version-script, etc.)\n");
        free(out_argv);
        return 1;
    }

    /* ---- STEP 7 (_zig-cc-common.sh:140-161): post-translation drop
     * filter over the translated args. ---- */
    const char **filtered = (const char **)malloc(sizeof(char *) * (size_t)(out_argc + 1));
    if (!filtered) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        free(out_argv);
        return 1;
    }
    int fi = 0;
    for (i = 0; i < out_argc; i++) {
        const char *arg = out_argv[i];
        if (is_post_translate_drop(arg))
            continue;
        filtered[fi++] = arg;
    }
    free(out_argv);

    /* ---- STEP 8 (_zig-cc-common.sh:163-171): final mode + macOS
     * deployment-target rewrite of the target triple. ---- */
    const char *mode = mode_is_cxx ? "c++" : "cc"; /* :163 */

    const char *macos_dep = getenv("MACOSX_DEPLOYMENT_TARGET");
    const char *zig_target_final = ZIG_TARGET;
    char rewritten_target[512];
    if (macos_dep && *macos_dep && strstr(ZIG_TARGET, "-macos") != NULL) {
        /* bash :170 -- ${_zig_target%%-macos*} removes the LONGEST
         * matching suffix of the pattern "-macos*", which (since the
         * trailing "*" matches everything to end-of-string) is
         * equivalent to truncating at the FIRST occurrence of
         * "-macos". ${_zig_target##*macos*-} removes the LONGEST
         * matching prefix of "*macos*-", i.e. everything through the
         * LAST "-" in the string (any "-" qualifies since "macos"
         * necessarily appears earlier in the string, having already
         * been gated on by the `[[ == *-macos* ]]` check above) --
         * equivalent to "everything after the last '-'". */
        const char *macos_pos = strstr(ZIG_TARGET, "-macos");
        size_t head_len = (size_t)(macos_pos - ZIG_TARGET);
        const char *last_dash = strrchr(ZIG_TARGET, '-');
        const char *tail = last_dash ? last_dash + 1 : ZIG_TARGET;
        snprintf(rewritten_target, sizeof(rewritten_target), "%.*s-macos.%s-%s",
                 (int)head_len, ZIG_TARGET, macos_dep, tail);
        zig_target_final = rewritten_target;
    }

    /* ---- STEP 9 (_zig-cc-common.sh:173-181): inject -fuse-ld=lld
     * only if promoted and not already present. ---- */
    int has_lld_flag = 0;
    for (i = 0; i < fi; i++) {
        if (str_eq(filtered[i], "-fuse-ld=lld")) { has_lld_flag = 1; break; }
    }
    int inject_lld = use_lld && !has_lld_flag;

    /* ---- STEP 10 (_zig-cc-common.sh:183-190): inject a default
     * -target only if the filtered args contain neither -target nor
     * any --target= prefixed token. ---- */
    int has_target = 0;
    for (i = 0; i < fi; i++) {
        if (str_eq(filtered[i], "-target") || starts_with(filtered[i], "--target=")) {
            has_target = 1;
            break;
        }
    }
    int inject_target = !has_target;

    /* ---- STEP 10b (replaces recipe/scripts/_zig-force-load-common.sh:29-96):
     * -all_load rewrite.
     *
     * zig's CLI already turns `-force_load <archive>` into a link input with
     * must_link = true (upstream src/main.zig, since PR #10584), and our
     * Mach-O LLD patch emits -force_load back out for must_link archives
     * (recipe/patches/Lld.zig-macho-lld-support.patch:234).  Both the bare
     * and the -Wl,-force_load,<a> spellings reach that handler, so -force_load
     * round-trips untouched and needs nothing from us.
     *
     * -all_load has no handler at all: it falls through to main.zig's terminal
     * `fatal("unsupported linker arg: {s}")` and kills the link.  It is the
     * only spelling needing a rewrite, and the rewrite is one -force_load per
     * archive on the line -- which is what -all_load means.  The bash
     * version's mktemp -d + `ar x` extraction existed only because it assumed
     * zig understood neither flag. */
    int has_all_load = 0;
    for (i = 0; i < fi; i++) {
        if (str_eq(filtered[i], "-all_load") || str_eq(filtered[i], "-Wl,-all_load")) {
            has_all_load = 1;
            break;
        }
    }

    const char **force_load_extra = NULL;
    int n_force_load_extra = 0;
    if (has_all_load) {
        force_load_extra = (const char **)malloc(sizeof(char *) * (size_t)(2 * fi + 1));
        if (!force_load_extra) {
            fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
            free(filtered);
            return 1;
        }
        /* Drop every -all_load token.  A bare one may have come from
         * `-Xlinker -all_load`, whose now-orphaned -Xlinker would otherwise
         * consume the following argument, so drop that too. */
        int wi = 0;
        for (i = 0; i < fi; i++) {
            const char *arg = filtered[i];
            if (str_eq(arg, "-Wl,-all_load"))
                continue;
            if (str_eq(arg, "-all_load")) {
                if (wi > 0 && str_eq(filtered[wi - 1], "-Xlinker"))
                    wi--;
                continue;
            }
            filtered[wi++] = arg;
        }
        fi = wi;

        /* Emit -force_load per archive, skipping any already named by an
         * explicit -force_load so the same input is not marked must_link
         * twice. */
        for (i = 0; i < fi; i++) {
            const char *arg = filtered[i];
            if (str_eq(arg, "-force_load")) { i++; continue; }
            if (starts_with(arg, "-Wl,-force_load,")) continue;
            if (!ends_with(arg, ".a") || !is_regular_file(arg)) continue;
            int dup = 0, j;
            for (j = 0; j < fi; j++) {
                if (str_eq(filtered[j], "-force_load") && j + 1 < fi
                    && str_eq(filtered[j + 1], arg)) { dup = 1; break; }
                if (starts_with(filtered[j], "-Wl,-force_load,")
                    && str_eq(filtered[j] + strlen("-Wl,-force_load,"), arg)) { dup = 1; break; }
            }
            if (dup) continue;
            force_load_extra[n_force_load_extra++] = "-force_load";
            force_load_extra[n_force_load_extra++] = arg;
        }
    }

    /* ---- STEP 11 (_zig-cc-common.sh:192): assemble the final argv
     * and exec. argv[0] is the zig binary path itself, matching
     * zig-cc.sh/zig-cxx.sh's `exec "@ZIG_BIN@" "${_exec_args[@]}"`
     * (bash sets argv[0] to the exec'd command name, here @ZIG_BIN@).
     * Order: argv0, mode, [lld], [target x2], sysroot flags, filtered
     * args, NULL -- matching bash's
     * _exec_args=("${_mode}" "${_lld_flag[@]}" "${_target_flag[@]}"
     * "${_sysroot_flags[@]}" "${_final_args[@]}"). */
    int max_args = fi + n_sysroot_flags + n_force_load_extra + 6;
    const char **new_argv = (const char **)malloc(sizeof(char *) * (size_t)max_args);
    if (!new_argv) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        free(filtered);
        free(force_load_extra);
        return 1;
    }

    int ni = 0;
    new_argv[ni++] = zig_bin;
    new_argv[ni++] = mode;
    if (inject_lld)
        new_argv[ni++] = "-fuse-ld=lld";
    if (inject_target) {
        new_argv[ni++] = "-target";
        new_argv[ni++] = zig_target_final;
    }
    for (i = 0; i < n_sysroot_flags; i++)
        new_argv[ni++] = sysroot_flags[i];
    for (i = 0; i < fi; i++)
        new_argv[ni++] = filtered[i];
    for (i = 0; i < n_force_load_extra; i++)
        new_argv[ni++] = force_load_extra[i];
    new_argv[ni] = NULL;

    /* exec_zig() replaces this process on success and returns only on
     * failure (it prints its own error). filtered/new_argv are
     * intentionally not freed on the success path -- the process image
     * is about to be replaced. */
    return exec_zig(zig_bin, (char *const *)new_argv);
}

/* ================= simple tool runners ================= */

/* Item 14: trivial exec passthrough.  zig-ranlib.sh:4, zig-rc.sh:4.
 * Also the tail of run_ar / run_lld. */
static int run_passthrough(const char *zig_bin, const char *prog,
                           const char *subcmd, int argc, char *argv[]) {
    const char **new_argv =
        (const char **)malloc(sizeof(char *) * (size_t)(argc + 2));
    if (!new_argv) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }
    int ni = 0, i;
    new_argv[ni++] = zig_bin;
    new_argv[ni++] = subcmd;
    for (i = 1; i < argc; i++)
        new_argv[ni++] = argv[i];
    new_argv[ni] = NULL;
    return exec_zig(zig_bin, (char *const *)new_argv);
}

/* Item 10 (zig-ar.sh:6-13): strip the 'T' (thin archive) modifier.
 * zig's linker frontend cannot parse thin archives even though zig ar
 * (llvm-ar) can create them, and Meson unconditionally passes csrDT on Linux.
 *
 * Faithful to bash: the guard is `${#_args[@]} -eq 0`, and every branch
 * appends, so the rewrite applies to the FIRST argument ONLY.  The arg must
 * match ^[a-zA-Z]+$ and contain a T; ALL T's are then removed
 * (`${_a//T/}`), which can legitimately yield an empty string -- bash appends
 * that empty positional arg, so we do too. */
static int is_ar_modifier_with_T(const char *a) {
    int has_T = 0;
    const char *p;
    if (!*a) return 0;
    for (p = a; *p; p++) {
        if (!isalpha((unsigned char)*p)) return 0;
        if (*p == 'T') has_T = 1;
    }
    return has_T;
}

static int run_ar(const char *zig_bin, const char *prog, int argc, char *argv[]) {
    const char **new_argv =
        (const char **)malloc(sizeof(char *) * (size_t)(argc + 2));
    if (!new_argv) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }
    int ni = 0, i;
    new_argv[ni++] = zig_bin;
    new_argv[ni++] = "ar";
    for (i = 1; i < argc; i++) {
        if (i == 1 && is_ar_modifier_with_T(argv[i])) {
            char *stripped = (char *)malloc(strlen(argv[i]) + 1);
            if (!stripped) {
                fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
                free(new_argv);
                return 1;
            }
            char *w = stripped;
            const char *r;
            for (r = argv[i]; *r; r++)
                if (*r != 'T') *w++ = *r;
            *w = '\0';
            new_argv[ni++] = stripped;
        } else {
            new_argv[ni++] = argv[i];
        }
    }
    new_argv[ni] = NULL;
    return exec_zig(zig_bin, (char *const *)new_argv);
}

/* Item 11 (zig-lld.sh:6-9): ld.lld for ELF, ld64.lld for Mach-O.
 * bash branches on `uname -s` at RUNTIME; this branches at COMPILE time.
 * Equivalent here because the shim is compiled for the machine it will run on
 * (natively, or with -target for an unhosted cross), which is the same
 * assumption zig_resolve_sysroot's #ifdef __linux__ already makes. */
static int run_lld(const char *zig_bin, const char *prog, int argc, char *argv[]) {
#if defined(__APPLE__)
    const char *lld = "ld64.lld";
#else
    const char *lld = "ld.lld";
#endif
    return run_passthrough(zig_bin, prog, lld, argc, argv);
}

/* Item 12 (zig-windres.sh:7-13): rewrite -o <out> to -fo <out> and -o<out>
 * to -fo<out>, then hand off to zig rc.
 *
 * The exact "-o" arm is checked before the "-o*" prefix arm, matching bash's
 * case-order.  A trailing bare "-o" makes bash's `shift 2` fail under
 * `set -e`, exiting non-zero WITHOUT exec'ing; we mirror that with an explicit
 * error rather than silently forwarding a dangling flag. */
static int run_windres(const char *zig_bin, const char *prog, int argc, char *argv[]) {
    const char **new_argv =
        (const char **)malloc(sizeof(char *) * (size_t)(2 * argc + 2));
    if (!new_argv) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }
    int ni = 0, i;
    new_argv[ni++] = zig_bin;
    new_argv[ni++] = "rc";
    for (i = 1; i < argc; i++) {
        if (str_eq(argv[i], "-o")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s: -o requires an argument\n", prog);
                free(new_argv);
                return 1;
            }
            new_argv[ni++] = "-fo";
            new_argv[ni++] = argv[++i];
        } else if (starts_with(argv[i], "-o")) {
            const char *tail = argv[i] + 2;
            size_t len = strlen("-fo") + strlen(tail) + 1;
            char *buf = (char *)malloc(len);
            if (!buf) {
                fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
                free(new_argv);
                return 1;
            }
            snprintf(buf, len, "-fo%s", tail);
            new_argv[ni++] = buf;
        } else {
            new_argv[ni++] = argv[i];
        }
    }
    new_argv[ni] = NULL;
    return exec_zig(zig_bin, (char *const *)new_argv);
}

/* zig-asm.sh:5-14.  Note this is inventory item 2's DUPLICATED sysroot block:
 * unlike run_cc it injects -isysroot ONLY (no -L group).  Preserved as-is --
 * unifying it is a behavior change and belongs in its own commit. */
static int run_asm(const char *zig_bin, const char *prog, int argc, char *argv[]) {
    int target_is_native = str_eq(ZIG_TARGET, "native");
    const char *sysroot = zig_resolve_sysroot(getenv("CONDA_PREFIX"),
                                              ZIG_TARGET_ARCH, target_is_native);
    int have_sysroot = zig_sysroot_is_dir(sysroot);

    /* zig_bin, "cc", "-target", <t>, "-mcpu=baseline", [-isysroot, <sr>],
     * args..., NULL */
    const char **new_argv =
        (const char **)malloc(sizeof(char *) * (size_t)(argc + 8));
    if (!new_argv) {
        fprintf(stderr, "ERROR: %s: malloc failed\n", prog);
        return 1;
    }
    int ni = 0, i;
    new_argv[ni++] = zig_bin;
    new_argv[ni++] = "cc";
    new_argv[ni++] = "-target";
    new_argv[ni++] = ZIG_TARGET;
    new_argv[ni++] = "-mcpu=baseline";
    if (have_sysroot) {
        new_argv[ni++] = "-isysroot";
        new_argv[ni++] = sysroot;
    }
    for (i = 1; i < argc; i++)
        new_argv[ni++] = argv[i];
    new_argv[ni] = NULL;
    return exec_zig(zig_bin, (char *const *)new_argv);
}

/* ================= dispatch ================= */

typedef enum {
    MODE_UNKNOWN = 0,
    MODE_CC, MODE_CXX, MODE_AR, MODE_RANLIB,
    MODE_ASM, MODE_RC, MODE_LLD, MODE_WINDRES,
    MODE_FORCE_LOAD_CC, MODE_FORCE_LOAD_CXX
} zig_mode;

/* Hand-rolled rather than <libgen.h> basename(): the POSIX version may modify
 * its argument and the GNU version has different semantics for trailing
 * slashes.  argv[0] never has a trailing slash in practice, and this keeps the
 * behavior identical on both. */
static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static zig_mode mode_from_argv0(const char *argv0, const char **out_prog) {
    const char *base = base_name(argv0);
    *out_prog = base;

    /* Item 13: self-location is moot under dispatch -- the wrapper no longer
     * needs to find a sibling helper script, it IS the helper. */
    size_t plen = strlen(WRAPPER_PREFIX);
    if (plen && strncmp(base, WRAPPER_PREFIX, plen) == 0)
        base += plen;

    if (str_eq(base, "zig-cc"))      return MODE_CC;
    if (str_eq(base, "zig-cxx"))     return MODE_CXX;
    if (str_eq(base, "zig-ar"))      return MODE_AR;
    if (str_eq(base, "zig-ranlib"))  return MODE_RANLIB;
    if (str_eq(base, "zig-asm"))     return MODE_ASM;
    if (str_eq(base, "zig-rc"))      return MODE_RC;
    if (str_eq(base, "zig-lld"))     return MODE_LLD;
    if (str_eq(base, "zig-windres")) return MODE_WINDRES;
    /* Aliases of cc/c++: zig honours -force_load itself and STEP 10b rewrites
     * -all_load, so these need no distinct runner.  The names are kept because
     * build systems invoke them by name. */
    if (str_eq(base, "zig-force-load-cc"))  return MODE_FORCE_LOAD_CC;
    if (str_eq(base, "zig-force-load-cxx")) return MODE_FORCE_LOAD_CXX;
    return MODE_UNKNOWN;
}

int main(int argc, char *argv[]) {
    /* Uniform across every tool -- this is the Phase 0 cache-dir fix that the
     * bash side achieves by having all ten wrappers source
     * _zig-cache-common.sh. */
    init_zig_global_cache_dir();

    const char *prog = NULL;
    zig_mode mode = mode_from_argv0(argv[0] ? argv[0] : "zig-cc", &prog);
    if (mode == MODE_UNKNOWN) {
        fprintf(stderr,
                "%s: not a recognized zig wrapper name.\n"
                "  Expected " WRAPPER_PREFIX "zig-{cc,cxx,ar,ranlib,asm,rc,lld,windres,"
                "force-load-cc,force-load-cxx}.\n",
                prog);
        return 127;
    }

    const char *zig_bin = zig_resolve_zig_bin(ZIG_BIN, WRAPPER_PREFIX);

    switch (mode) {
    case MODE_CC:      return run_cc(zig_bin, prog, 0, argc, argv);
    case MODE_CXX:     return run_cc(zig_bin, prog, 1, argc, argv);
    case MODE_AR:      return run_ar(zig_bin, prog, argc, argv);
    case MODE_RANLIB:  return run_passthrough(zig_bin, prog, "ranlib", argc, argv);
    case MODE_RC:      return run_passthrough(zig_bin, prog, "rc", argc, argv);
    case MODE_LLD:     return run_lld(zig_bin, prog, argc, argv);
    case MODE_WINDRES: return run_windres(zig_bin, prog, argc, argv);
    case MODE_ASM:     return run_asm(zig_bin, prog, argc, argv);
    case MODE_FORCE_LOAD_CC:  return run_cc(zig_bin, prog, 0, argc, argv);
    case MODE_FORCE_LOAD_CXX: return run_cc(zig_bin, prog, 1, argc, argv);
    default:           return 127;   /* unreachable; silences -Wswitch */
    }
}
