/*
 * GENERATED FILE -- DO NOT EDIT BY HAND.
 * Source of truth: recipe/building/flag_rules.py
 * Regenerate:       python recipe/building/gen_translators.py
 * CI drift guard:   python recipe/building/gen_translators.py --check
 *
 * Encodes rules R1-R11 and R13 from flag_rules.py (R12 is unix-only,
 * omitted here -- see flag_rules.rules_for_profile). Pure portable C: no
 * windows.h, no spawn/exec, no platform calls beyond the fields
 * already resolved into zig_translate_profile by the caller.
 */

#ifndef ZIG_TRANSLATE_INC
#define ZIG_TRANSLATE_INC

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>

typedef struct {
    int is_win;          /* 1 on the win profile, 0 on unix */
    int is_win_target;   /* 1 if the baked-in zig target triple is
                          * windows/mingw (gates R1's -Map rewrite) */
    const char *conda_prefix;
    const char *zig_target_arch; /* e.g. "x86_64" / "aarch64" */
} zig_translate_profile;

static int zig_tr_streq(const char *a, const char *b) { return strcmp(a, b) == 0; }
static int zig_tr_starts_with(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }

/* R8: bare/-Wl,-prefixed Bsymbolic(-functions) forms. */
static int zig_tr_is_bsymbolic_flag(const char *arg) {
    return zig_tr_streq(arg, "-Wl,-Bsymbolic-functions") ||
           zig_tr_streq(arg, "-Wl,-Bsymbolic") ||
           zig_tr_streq(arg, "-Bsymbolic-functions") ||
           zig_tr_streq(arg, "-Bsymbolic");
}

/* R8: value that appears right after a literal -Xlinker token. */
static int zig_tr_is_xlinker_bsymbolic(const char *arg) {
    return zig_tr_streq(arg, "-Bsymbolic-functions") || zig_tr_streq(arg, "-Bsymbolic");
}

/* R7: per-member gated -Wl,* drop.
 * Returns: 0 = no match, 1 = gate=always, 2 = gate=when_not_lld. */
static int zig_tr_wl_drop_gate(const char *arg) {
    if (zig_tr_streq(arg, "-Wl,--color-diagnostics")) return 1;
    if (zig_tr_starts_with(arg, "-Wl,-rpath-link")) return 1;
    if (zig_tr_streq(arg, "-Wl,--disable-new-dtags")) return 1;
    return 0;
}

/* R9: -Wl,-z,* / -Wl,-O* family split.
 * Returns: 0 = no match, 1 = keep (passthrough only),
 *          2 = keep AND trigger use_lld. */
static int zig_tr_z_o_check(const char *arg) {
    if (zig_tr_starts_with(arg, "-Wl,-z,")) {
        const char *suffix = arg + 7; /* strlen("-Wl,-z,") */
        if (zig_tr_streq(suffix, "defs") || zig_tr_streq(suffix, "nodelete")) return 2;
        return 1;
    }
    if (zig_tr_starts_with(arg, "-Wl,-O")) {
        const char *suffix = arg + 6; /* strlen("-Wl,-O") */
        if (suffix[0] != '\0' && isdigit((unsigned char)suffix[0])) return 2;
        return 1;
    }
    return 0;
}

/* R5: conda triplet -> zig triplet. profile->is_win gates the
 * darwin-only families out for the win profile (the Windows shim
 * never targets darwin). */
static const char *zig_tr_translate_target(const char *val, const zig_translate_profile *profile) {
        if (zig_tr_starts_with(val, "x86_64-w64-mingw32")) return "x86_64-windows-gnu";
        if (zig_tr_starts_with(val, "aarch64-w64-mingw32")) return "aarch64-windows-gnu";
        {
            const char *p = strstr(val, "-conda-linux-gnu");
            if (p) {
                static char buf[256];
                size_t prefix_len = (size_t)(p - val);
                if (prefix_len > sizeof(buf) - 32) prefix_len = sizeof(buf) - 32;
                snprintf(buf, sizeof(buf), "%.*s-linux-gnu", (int)prefix_len, val);
                return buf;
            }
        }
    if (!profile->is_win) {
        if (zig_tr_starts_with(val, "x86_64-apple-darwin")) return "x86_64-macos-none";
    }
    if (!profile->is_win) {
        if (zig_tr_starts_with(val, "arm64-apple-darwin")) return "aarch64-macos-none";
    }
    return val;
}

/* R2: -print-search-dirs intercept. */
static void zig_tr_print_search_dirs(const zig_translate_profile *profile) {
    char zig_lib[512];
    char programs[512];
    char mingw_common[512];
    char mingw_arch[512];
    const char *arch_leaf = zig_tr_streq(profile->zig_target_arch, "aarch64") ? "libarm64" : "lib-x86_64";
    if (profile->is_win) {
        snprintf(zig_lib, sizeof(zig_lib), "%s\\Library\\lib\\zig", profile->conda_prefix);
        snprintf(programs, sizeof(programs), "%s\\Library\\bin\\", profile->conda_prefix);
        snprintf(mingw_common, sizeof(mingw_common), "%s\\libc\\mingw\\lib-common", zig_lib);
        snprintf(mingw_arch, sizeof(mingw_arch), "%s\\libc\\mingw\\%s", zig_lib, arch_leaf);
        printf("install: %s\\\n", zig_lib);
        printf("programs: =%s\n", programs);
        printf("libraries: =%s;%s;%s\n", mingw_common, mingw_arch, zig_lib);
    } else {
        snprintf(zig_lib, sizeof(zig_lib), "%s/lib/zig", profile->conda_prefix);
        snprintf(programs, sizeof(programs), "%s/bin/", profile->conda_prefix);
        snprintf(mingw_common, sizeof(mingw_common), "%s/libc/mingw/lib-common", zig_lib);
        snprintf(mingw_arch, sizeof(mingw_arch), "%s/libc/mingw/%s", zig_lib, arch_leaf);
        printf("install: %s/\n", zig_lib);
        printf("programs: =%s\n", programs);
        printf("libraries: =%s:%s:%s\n", mingw_common, mingw_arch, zig_lib);
    }
}

/* R3: -print-file-name=<name> intercept.
 * Uses fopen() existence probing (portable) instead of the real Windows
 * shim's GetFileAttributesA -- flagged simplification, see report. */
static void zig_tr_print_file_name(const char *name, const zig_translate_profile *profile) {
    static const char *dirs_unix[2] = {"lib/zig-llvm/lib", "lib"};
    static const char *dirs_win[2] = {"Library\\lib\\zig-llvm\\lib", "Library\\lib"};
    char probe[1024];
    int d;
    for (d = 0; d < 2; d++) {
        if (profile->is_win)
            snprintf(probe, sizeof(probe), "%s\\%s\\%s", profile->conda_prefix, dirs_win[d], name);
        else
            snprintf(probe, sizeof(probe), "%s/%s/%s", profile->conda_prefix, dirs_unix[d], name);
        FILE *f = fopen(probe, "rb");
        if (f) {
            fclose(f);
            printf("%s\n", probe);
            return;
        }
    }
    printf("%s\n", name);
}

/* R10: -print-multi-os-directory intercept. No multilib support -- always
 * the current directory, matching standard GCC behavior. */
static void zig_tr_print_multi_os_directory(void) {
    printf(".\n");
}

/* R11: -print-prog-name=<name> intercept. Probes profile's bin dir for
 * the named program; falls back to the bare name if not found (mirrors
 * R3's fallback). */
static void zig_tr_print_prog_name(const char *name, const zig_translate_profile *profile) {
    char probe[1024];
    if (profile->is_win)
        snprintf(probe, sizeof(probe), "%s\\Library\\bin\\%s", profile->conda_prefix, name);
    else
        snprintf(probe, sizeof(probe), "%s/bin/%s", profile->conda_prefix, name);
    FILE *f = fopen(probe, "rb");
    if (f) {
        fclose(f);
        printf("%s\n", probe);
        return;
    }
    printf("%s\n", name);
}

/* R13: -print-multiarch intercept. Synthesizes this profile/arch's
 * conda-style triplet and reuses zig_tr_translate_target() (R5) so the
 * printed value matches what -target/--target= would translate to. */
static void zig_tr_print_multiarch(const zig_translate_profile *profile) {
    char synth[64];
    if (profile->is_win)
        snprintf(synth, sizeof(synth), "%s-w64-mingw32", profile->zig_target_arch);
    else
        snprintf(synth, sizeof(synth), "%s-conda-linux-gnu", profile->zig_target_arch);
    printf("%s\n", zig_tr_translate_target(synth, profile));
}

/* R1: -Map / -Map=FILE / -MapFILE -> -Wl,-Map,FILE (mingw targets only).
 * Returns 1 if handled: *out is a malloc'd replacement (ownership
 * transferred to the caller's out_argv, do not free here); *consumed_next
 * is set to 1 if the following argv slot (the bare "-Map FILE" two-token
 * form) was also consumed. */
static int zig_tr_rewrite_map(const char *arg, const char *next_arg, int has_next,
                               const zig_translate_profile *profile,
                               char **out, int *consumed_next) {
    const char *file = NULL;
    *consumed_next = 0;
    if (!profile->is_win_target) return 0;
    if (zig_tr_streq(arg, "-Map")) {
        if (!has_next) return 0;
        file = next_arg;
        *consumed_next = 1;
    } else if (zig_tr_starts_with(arg, "-Map=") && arg[5] != '\0') {
        file = arg + 5;
    } else if (zig_tr_starts_with(arg, "-Map") && arg[4] != '\0' && arg[4] != '=') {
        file = arg + 4;
    } else {
        return 0;
    }
    {
        size_t len = strlen("-Wl,-Map,") + strlen(file) + 1;
        char *buf = (char *)malloc(len);
        if (!buf) return 0;
        snprintf(buf, len, "-Wl,-Map,%s", file);
        *out = buf;
    }
    return 1;
}

/*
 * zig_translate_flags -- pure argv -> argv string transform (R1-R9 only;
 * see the module header for what stays out of scope / hand-written).
 *
 * Contract:
 *   in:  argc/argv       - argv[0] (program name) EXCLUDED by convention;
 *                          pass argv+1, argc-1 from main().
 *        profile          - resolved profile fields (see struct above).
 *        *out_mode_is_cxx - caller sets to 1 for "c++" mode, 0 for "cc"
 *                          mode BEFORE calling.
 *   out: *out_argv        - malloc'd NULL-terminated array of string
 *                          pointers; caller owns the ARRAY (free()) but
 *                          individual elements may alias the input argv
 *                          strings -- do not free elements. Already
 *                          includes any injected "-mcpu=baseline"
 *                          (R6) and translated -target/--target= (R5);
 *                          does NOT include the zig binary path, the
 *                          mode token, "-fuse-ld=lld", or a default
 *                          -target (those remain hand-written prepends
 *                          in the wrapper, out of scope here).
 *        *out_argc        - number of entries in *out_argv (excludes the
 *                          NULL terminator).
 *        *out_use_lld     - 1 if any in-scope LLD-trigger rule matched
 *                          (R8, R9-trigger-subset). The wrapper MUST OR
 *                          this with its own hand-written scan for the
 *                          remaining out-of-scope LLD triggers
 *                          (--version-script, --dynamic-list,
 *                          --gc-sections, --build-id,
 *                          --allow-shlib-undefined, -fuse-ld=lld itself)
 *                          before deciding whether to prepend
 *                          "-fuse-ld=lld".
 *        *out_mode_is_cxx - possibly downgraded by R4 (c++ -> cc); never
 *                          upgraded.
 *
 * Return value: 0 on success (*out_argv populated). 2 if any intercept
 * rule matched (R2, R3, R10, R11, R13 -- see zig_tr_streq/starts_with
 * dispatch below): output was already printed to stdout and the caller
 * must exit(0) immediately WITHOUT touching *out_argv (left unset). 1 on
 * allocation failure.
 *
 * No spawn, no platform calls beyond the fields already resolved into
 * profile by the caller.
 */
int zig_translate_flags(int argc, char *const argv[], const zig_translate_profile *profile,
                         char ***out_argv, int *out_argc, int *out_use_lld, int *out_mode_is_cxx) {
    int i;

    for (i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (zig_tr_streq(a, "-print-search-dirs")) { zig_tr_print_search_dirs(profile); return 2; }
        if (zig_tr_starts_with(a, "-print-file-name=")) { zig_tr_print_file_name(a + strlen("-print-file-name="), profile); return 2; }
        if (zig_tr_streq(a, "-print-multi-os-directory")) { zig_tr_print_multi_os_directory(); return 2; }
        if (zig_tr_starts_with(a, "-print-prog-name=")) { zig_tr_print_prog_name(a + strlen("-print-prog-name="), profile); return 2; }
        if (zig_tr_streq(a, "-print-multiarch")) { zig_tr_print_multiarch(profile); return 2; }
    }

    {
        int use_lld = 0;
        int has_mcpu = 0;
        char **out;
        int oi = 0;
        int saw_nostdlibxx = 0;

        for (i = 0; i < argc; i++) {
            const char *a = argv[i];
            if (zig_tr_is_bsymbolic_flag(a)) use_lld = 1;
            if (zig_tr_streq(a, "-Xlinker") && i + 1 < argc && zig_tr_is_xlinker_bsymbolic(argv[i + 1]))
                use_lld = 1;
            if (zig_tr_starts_with(a, "-mcpu=")) has_mcpu = 1;
            if (zig_tr_z_o_check(a) == 2) use_lld = 1;
        }

        out = (char **)malloc(sizeof(char *) * (size_t)(argc + 2));
        if (!out) return 1;

        if (!has_mcpu)
            out[oi++] = (char *)"-mcpu=baseline";

        for (i = 0; i < argc; i++) {
            const char *a = argv[i];

            {
                int consumed_next = 0;
                char *rewritten = NULL;
                int has_next = (i + 1 < argc);
                const char *next = has_next ? argv[i + 1] : NULL;
                if (zig_tr_rewrite_map(a, next, has_next, profile, &rewritten, &consumed_next)) {
                    out[oi++] = rewritten;
                    if (consumed_next) i++;
                    continue;
                }
            }

            if (zig_tr_streq(a, "-nostdlib++")) {
                saw_nostdlibxx = 1;
                continue;
            }

            if (zig_tr_streq(a, "-Xlinker") && i + 1 < argc && zig_tr_is_xlinker_bsymbolic(argv[i + 1])) {
                out[oi++] = (char *)a;
                out[oi++] = (char *)argv[i + 1];
                i++;
                continue;
            }

            {
                int gate = zig_tr_wl_drop_gate(a);
                if (gate == 1) continue;
                if (gate == 2 && !use_lld) continue;
            }

            /* R9 passthrough: no drop action -- falls through to the
             * default keep below (zig_tr_z_o_check is only consulted in
             * the pre-scan above, to decide use_lld). */

            if (zig_tr_streq(a, "-target") && i + 1 < argc) {
                out[oi++] = (char *)a;
                out[oi++] = (char *)zig_tr_translate_target(argv[i + 1], profile);
                i++;
                continue;
            }
            if (zig_tr_starts_with(a, "--target=")) {
                const char *val = a + strlen("--target=");
                const char *translated = zig_tr_translate_target(val, profile);
                if (translated != val) {
                    size_t len = strlen("--target=") + strlen(translated) + 1;
                    char *buf = (char *)malloc(len);
                    if (buf) {
                        snprintf(buf, len, "--target=%s", translated);
                        out[oi++] = buf;
                        continue;
                    }
                }
                out[oi++] = (char *)a;
                continue;
            }

            out[oi++] = (char *)a;
        }

        if (saw_nostdlibxx && *out_mode_is_cxx)
            *out_mode_is_cxx = 0;

        out[oi] = NULL;
        *out_argv = out;
        *out_argc = oi;
        *out_use_lld = use_lld;
    }
    return 0;
}

#endif /* ZIG_TRANSLATE_INC */
