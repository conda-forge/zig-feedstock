#!/usr/bin/env python3
"""
recipe/building/gen_translators.py

Generator: turns the pure-data manifest in flag_rules.py (RULES, PROFILES,
PROFILE_DATA) into two generated artifacts, rule-for-rule:

  - recipe/building/_translate.inc      Portable C (no windows.h; only
                                         string.h/stdlib.h/stdio.h/ctype.h)
                                         implementing zig_translate_flags(),
                                         usable by BOTH profiles at runtime
                                         via the zig_translate_profile
                                         struct (is_win selects separators/
                                         paths; is_win_target selects
                                         whether R1's -Map rewrite fires).
                                         Included directly (#include) by
                                         zig-cc-nonunix.c -- and, being
                                         portable, also compilable+runnable
                                         standalone by a Linux-hosted test
                                         harness for golden-parity checks.

  - recipe/building/_translate.gen.sh   Bash implementing
                                         _zig_translate_flags(), unix
                                         profile only (this is the only
                                         profile the bash wrapper ever
                                         runs under). Sourced by
                                         _zig-cc-common.sh.

OUT OF SCOPE (left hand-written in the real wrappers, NOT emitted here):
  sysroot detection, the general -Xlinker trigger/drop set besides
  Bsymbolic (--dynamic-list, --version-script, --gc-sections, --build-id,
  --allow-shlib-undefined), -march=/-mtune=/-fstack-protector*/-fno-plt/
  -fdebug-prefix-map=*/-stdlib=*/-lgcc_eh/-lgcc_s/-l:libpthread* drops,
  MSVC /MANIFEST* handling, -Wl,-e<sym> --entry translation, zig cache-dir
  init, MACOSX_DEPLOYMENT_TARGET override, default -target injection when
  absent, and -fuse-ld=lld prepending (the wrapper ORs this module's
  out_use_lld with its own hand-written trigger scan for the remaining
  out-of-scope LLD triggers before deciding whether to prepend
  -fuse-ld=lld).

Determinism: RULES is a fixed Python list (stable iteration order); no
timestamps, no random data, no environment-dependent values are emitted.
Running this generator twice against an unchanged flag_rules.py MUST
produce byte-identical output -- this is required for the `--check` CI
drift guard to be meaningful.

Usage:
    python gen_translators.py            # regenerate + write both files
    python gen_translators.py --check    # regenerate to temp dir, diff
                                          # against the committed files;
                                          # exit 1 on drift, 0 if identical
"""

from __future__ import annotations

import argparse
import difflib
import filecmp
import sys
import tempfile
from pathlib import Path

from flag_rules import PROFILE_DATA, RULES, rules_for_profile

_THIS_DIR = Path(__file__).resolve().parent
_C_OUT = _THIS_DIR / "_translate.inc"
_SH_OUT = _THIS_DIR / "_translate.gen.sh"

_GEN_BANNER = (
    "GENERATED FILE -- DO NOT EDIT BY HAND.\n"
    "Source of truth: recipe/building/flag_rules.py\n"
    "Regenerate:       python recipe/building/gen_translators.py\n"
    "CI drift guard:   python recipe/building/gen_translators.py --check\n"
)


def _rule(rule_id: str) -> dict:
    for r in RULES:
        if r["id"] == rule_id:
            return r
    raise KeyError(rule_id)


# ---------------------------------------------------------------------------
# C code generation
# ---------------------------------------------------------------------------
def _c_member_check(form: str, value: str, ret: str) -> str:
    if form == "prefix":
        return f'    if (zig_tr_starts_with(arg, "{value}")) return {ret};'
    if form == "exact":
        return f'    if (zig_tr_streq(arg, "{value}")) return {ret};'
    raise ValueError(f"unsupported member form for C: {form!r}")


def _c_wl_drop_gate_fn() -> str:
    r7 = _rule("R7_wl_drop_hybrid")
    lines = [
        "/* R7: per-member gated -Wl,* drop.",
        " * Returns: 0 = no match, 1 = gate=always, 2 = gate=when_not_lld. */",
        "static int zig_tr_wl_drop_gate(const char *arg) {",
    ]
    for m in r7["members"]:
        ret = "1" if m["gate"] == "always" else "2"
        lines.append(_c_member_check(m["form"], m["value"], ret))
    lines.append("    return 0;")
    lines.append("}")
    return "\n".join(lines)


def _c_z_o_check_fn() -> str:
    lines = [
        "/* R9: -Wl,-z,* / -Wl,-O* family split.",
        " * Returns: 0 = no match, 1 = keep (passthrough only),",
        " *          2 = keep AND trigger use_lld. */",
        "static int zig_tr_z_o_check(const char *arg) {",
        '    if (zig_tr_starts_with(arg, "-Wl,-z,")) {',
        '        const char *suffix = arg + 7; /* strlen("-Wl,-z,") */',
    ]
    r9 = _rule("R9_z_o_passthrough")
    z_member = next(m for m in r9["members"] if m["prefix"] == "-Wl,-z,")
    conds = " || ".join(f'zig_tr_streq(suffix, "{v}")' for v in z_member["trigger_values"])
    lines.append(f"        if ({conds}) return 2;")
    lines.append("        return 1;")
    lines.append("    }")
    lines.append('    if (zig_tr_starts_with(arg, "-Wl,-O")) {')
    lines.append('        const char *suffix = arg + 6; /* strlen("-Wl,-O") */')
    lines.append("        if (suffix[0] != '\\0' && isdigit((unsigned char)suffix[0])) return 2;")
    lines.append("        return 1;")
    lines.append("    }")
    lines.append("    return 0;")
    lines.append("}")
    return "\n".join(lines)


def _c_translate_target_fn() -> str:
    r5 = _rule("R5_triplet_translate")
    lines = [
        "/* R5: conda triplet -> zig triplet. profile->is_win gates the",
        " * darwin-only families out for the win profile (the Windows shim",
        " * never targets darwin). */",
        "static const char *zig_tr_translate_target(const char *val, const zig_translate_profile *profile) {",
    ]
    for fam in r5["action"]["families"]:
        guard_open = ""
        guard_close = ""
        if fam["profiles"] == ("unix",):
            guard_open = "    if (!profile->is_win) {\n"
            guard_close = "\n    }"
        if "prefix" in fam:
            body = f'        if (zig_tr_starts_with(val, "{fam["prefix"]}")) return "{fam["replace"]}";'
        else:
            infix = fam["infix"]
            suffix = fam["replace_suffix"]
            body = (
                "        {\n"
                f'            const char *p = strstr(val, "{infix}");\n'
                "            if (p) {\n"
                "                static char buf[256];\n"
                "                size_t prefix_len = (size_t)(p - val);\n"
                "                if (prefix_len > sizeof(buf) - 32) prefix_len = sizeof(buf) - 32;\n"
                f'                snprintf(buf, sizeof(buf), "%.*s{suffix}", (int)prefix_len, val);\n'
                "                return buf;\n"
                "            }\n"
                "        }"
            )
        if guard_open:
            lines.append(guard_open + body + guard_close)
        else:
            lines.append(body)
    lines.append("    return val;")
    lines.append("}")
    return "\n".join(lines)


def _c_print_search_dirs_fn() -> str:
    # PROFILE_DATA templates already bake in the correct literal separators
    # per profile; this function branches on profile->is_win at runtime so
    # the SAME compiled zig_translate_flags supports both profiles (needed
    # for a Linux-hosted golden-parity test harness against _translate.inc).
    # NOTE (flagged in report): the literal path segments below are typed
    # to MATCH PROFILE_DATA's zig_lib/programs_dir/mingw_common/arch_dirs
    # values, not mechanically derived from them at generation time (doing
    # so would require a small template->C-printf compiler this Phase-2
    # pass does not build). Keep these in sync with PROFILE_DATA by hand
    # until a future pass closes that gap.
    return """/* R2: -print-search-dirs intercept. */
static void zig_tr_print_search_dirs(const zig_translate_profile *profile) {
    char zig_lib[512];
    char programs[512];
    char mingw_common[512];
    char mingw_arch[512];
    const char *arch_leaf = zig_tr_streq(profile->zig_target_arch, "aarch64") ? "libarm64" : "lib-x86_64";
    if (profile->is_win) {
        snprintf(zig_lib, sizeof(zig_lib), "%s\\\\Library\\\\lib\\\\zig", profile->conda_prefix);
        snprintf(programs, sizeof(programs), "%s\\\\Library\\\\bin\\\\", profile->conda_prefix);
        snprintf(mingw_common, sizeof(mingw_common), "%s\\\\libc\\\\mingw\\\\lib-common", zig_lib);
        snprintf(mingw_arch, sizeof(mingw_arch), "%s\\\\libc\\\\mingw\\\\%s", zig_lib, arch_leaf);
        printf("install: %s\\\\\\n", zig_lib);
        printf("programs: =%s\\n", programs);
        printf("libraries: =%s;%s;%s\\n", mingw_common, mingw_arch, zig_lib);
    } else {
        snprintf(zig_lib, sizeof(zig_lib), "%s/lib/zig", profile->conda_prefix);
        snprintf(programs, sizeof(programs), "%s/bin/", profile->conda_prefix);
        snprintf(mingw_common, sizeof(mingw_common), "%s/libc/mingw/lib-common", zig_lib);
        snprintf(mingw_arch, sizeof(mingw_arch), "%s/libc/mingw/%s", zig_lib, arch_leaf);
        printf("install: %s/\\n", zig_lib);
        printf("programs: =%s\\n", programs);
        printf("libraries: =%s:%s:%s\\n", mingw_common, mingw_arch, zig_lib);
    }
}"""


def _c_print_file_name_fn() -> str:
    # NOTE: the real Windows shim uses GetFileAttributesA (Windows-only) to
    # probe existence. This portable version uses fopen() instead, since
    # _translate.inc must not include windows.h. This is a deliberate,
    # flagged simplification -- see the returned report.
    # NOTE (flagged in report): dirs_unix/dirs_win below are typed to MATCH
    # PROFILE_DATA["unix"/"win"]["print_file_name_probe_dirs"], not
    # mechanically derived from them -- same gap as _c_print_search_dirs_fn.
    return """/* R3: -print-file-name=<name> intercept.
 * Uses fopen() existence probing (portable) instead of the real Windows
 * shim's GetFileAttributesA -- flagged simplification, see report. */
static void zig_tr_print_file_name(const char *name, const zig_translate_profile *profile) {
    static const char *dirs_unix[2] = {"lib/zig-llvm/lib", "lib"};
    static const char *dirs_win[2] = {"Library\\\\lib\\\\zig-llvm\\\\lib", "Library\\\\lib"};
    char probe[1024];
    int d;
    for (d = 0; d < 2; d++) {
        if (profile->is_win)
            snprintf(probe, sizeof(probe), "%s\\\\%s\\\\%s", profile->conda_prefix, dirs_win[d], name);
        else
            snprintf(probe, sizeof(probe), "%s/%s/%s", profile->conda_prefix, dirs_unix[d], name);
        FILE *f = fopen(probe, "rb");
        if (f) {
            fclose(f);
            printf("%s\\n", probe);
            return;
        }
    }
    printf("%s\\n", name);
}"""


def _c_print_multi_os_directory_fn() -> str:
    return """/* R10: -print-multi-os-directory intercept. No multilib support -- always
 * the current directory, matching standard GCC behavior. */
static void zig_tr_print_multi_os_directory(void) {
    printf(".\\n");
}"""


def _c_print_prog_name_fn() -> str:
    return """/* R11: -print-prog-name=<name> intercept. Probes profile's bin dir for
 * the named program; falls back to the bare name if not found (mirrors
 * R3's fallback). */
static void zig_tr_print_prog_name(const char *name, const zig_translate_profile *profile) {
    char probe[1024];
    if (profile->is_win)
        snprintf(probe, sizeof(probe), "%s\\\\Library\\\\bin\\\\%s", profile->conda_prefix, name);
    else
        snprintf(probe, sizeof(probe), "%s/bin/%s", profile->conda_prefix, name);
    FILE *f = fopen(probe, "rb");
    if (f) {
        fclose(f);
        printf("%s\\n", probe);
        return;
    }
    printf("%s\\n", name);
}"""


def _c_print_multiarch_fn() -> str:
    # NOTE (flagged in report): the C profile struct carries only
    # zig_target_arch + is_win/is_win_target (no full conda-triplet field),
    # so the conda-style input fed to zig_tr_translate_target() is
    # synthesized from those fields (mirroring how _c_print_search_dirs_fn
    # / _c_print_file_name_fn already synthesize paths from the same
    # fields) rather than sourced from a baked ZIG_TARGET/CONDA_TRIPLET
    # constant -- see the returned report's ambiguity notes.
    return """/* R13: -print-multiarch intercept. Synthesizes this profile/arch's
 * conda-style triplet and reuses zig_tr_translate_target() (R5) so the
 * printed value matches what -target/--target= would translate to. */
static void zig_tr_print_multiarch(const zig_translate_profile *profile) {
    char synth[64];
    if (profile->is_win)
        snprintf(synth, sizeof(synth), "%s-w64-mingw32", profile->zig_target_arch);
    else
        snprintf(synth, sizeof(synth), "%s-conda-linux-gnu", profile->zig_target_arch);
    printf("%s\\n", zig_tr_translate_target(synth, profile));
}"""


# Maps action["op"] (intercept rules only) -> the C call expression used by
# _c_intercept_dispatch_fn(). Rules whose op is not listed here are not
# emitted into the C/win dispatch (currently just R12, filtered out earlier
# via rules_for_profile("win") since it is unix-only).
_C_INTERCEPT_CALL: dict[str, str] = {
    "intercept_print_search_dirs": "zig_tr_print_search_dirs(profile)",
    "intercept_print_file_name": "zig_tr_print_file_name(value, profile)",
    "intercept_print_multi_os_directory": "zig_tr_print_multi_os_directory()",
    "intercept_print_prog_name": "zig_tr_print_prog_name(value, profile)",
    "intercept_print_multiarch": "zig_tr_print_multiarch(profile)",
}


def _c_intercept_dispatch_fn() -> str:
    """Single-pass dispatch over ALL intercept rules applicable to the win
    profile (R2, R3, R10, R11, R13 -- R12 is unix-only and is filtered out
    by rules_for_profile("win"), since zig-cc-nonunix.c has no sysroot
    concept). Replaces the old one-dedicated-for-loop-per-rule shape with a
    single loop, one arg scan, table-driven from RULES.
    """
    lines = [
        "    for (i = 0; i < argc; i++) {",
        "        const char *a = argv[i];",
    ]
    for rule in rules_for_profile("win"):
        if rule["kind"] != "intercept":
            continue
        form = rule["match"]["form"]
        call_template = _C_INTERCEPT_CALL[rule["action"]["op"]]
        for value in rule["match"]["values"]:
            if form == "exact":
                lines.append(f'        if (zig_tr_streq(a, "{value}")) {{ {call_template}; return 2; }}')
            elif form == "prefix":
                value_expr = f'a + strlen("{value}")'
                call = call_template.replace("value", value_expr)
                lines.append(f'        if (zig_tr_starts_with(a, "{value}")) {{ {call}; return 2; }}')
            else:
                raise ValueError(f"unsupported intercept match form for C: {form!r}")
    lines.append("    }")
    return "\n".join(lines)


def generate_c() -> str:
    parts = [
        "/*",
        f" * {_GEN_BANNER}".rstrip().replace("\n", "\n * "),
        " *",
        " * Encodes rules R1-R11 and R13 from flag_rules.py (R12 is unix-only,",
        " * omitted here -- see flag_rules.rules_for_profile). Pure portable C: no",
        " * windows.h, no spawn/exec, no platform calls beyond the fields",
        " * already resolved into zig_translate_profile by the caller.",
        " */",
        "",
        "#ifndef ZIG_TRANSLATE_INC",
        "#define ZIG_TRANSLATE_INC",
        "",
        "#include <string.h>",
        "#include <stdlib.h>",
        "#include <stdio.h>",
        "#include <ctype.h>",
        "",
        "typedef struct {",
        "    int is_win;          /* 1 on the win profile, 0 on unix */",
        "    int is_win_target;   /* 1 if the baked-in zig target triple is",
        "                          * windows/mingw (gates R1's -Map rewrite) */",
        "    const char *conda_prefix;",
        "    const char *zig_target_arch; /* e.g. \"x86_64\" / \"aarch64\" */",
        "} zig_translate_profile;",
        "",
        "static int zig_tr_streq(const char *a, const char *b) { return strcmp(a, b) == 0; }",
        "static int zig_tr_starts_with(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }",
        "",
        "/* R8: bare/-Wl,-prefixed Bsymbolic(-functions) forms. */",
        "static int zig_tr_is_bsymbolic_flag(const char *arg) {",
        '    return zig_tr_streq(arg, "-Wl,-Bsymbolic-functions") ||',
        '           zig_tr_streq(arg, "-Wl,-Bsymbolic") ||',
        '           zig_tr_streq(arg, "-Bsymbolic-functions") ||',
        '           zig_tr_streq(arg, "-Bsymbolic");',
        "}",
        "",
        "/* R8: value that appears right after a literal -Xlinker token. */",
        "static int zig_tr_is_xlinker_bsymbolic(const char *arg) {",
        '    return zig_tr_streq(arg, "-Bsymbolic-functions") || zig_tr_streq(arg, "-Bsymbolic");',
        "}",
        "",
        _c_wl_drop_gate_fn(),
        "",
        _c_z_o_check_fn(),
        "",
        _c_translate_target_fn(),
        "",
        _c_print_search_dirs_fn(),
        "",
        _c_print_file_name_fn(),
        "",
        _c_print_multi_os_directory_fn(),
        "",
        _c_print_prog_name_fn(),
        "",
        _c_print_multiarch_fn(),
        "",
        """/* R1: -Map / -Map=FILE / -MapFILE -> -Wl,-Map,FILE (mingw targets only).
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
    } else if (zig_tr_starts_with(arg, "-Map=") && arg[5] != '\\0') {
        file = arg + 5;
    } else if (zig_tr_starts_with(arg, "-Map") && arg[4] != '\\0' && arg[4] != '=') {
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
}""",
        "",
        """/*
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

""" + _c_intercept_dispatch_fn() + """

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
}""",
        "",
        "#endif /* ZIG_TRANSLATE_INC */",
        "",
    ]
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Bash code generation (unix profile only)
# ---------------------------------------------------------------------------
def _sh_pattern(form: str, value: str) -> str:
    if form == "prefix":
        return f"{value}*"
    if form == "exact":
        return value
    raise ValueError(f"unsupported member form for bash: {form!r}")


def _sh_wl_drop_always_patterns() -> list[str]:
    r7 = _rule("R7_wl_drop_hybrid")
    return [_sh_pattern(m["form"], m["value"]) for m in r7["members"] if m["gate"] == "always"]


def _sh_wl_drop_when_not_lld_patterns() -> list[str]:
    r7 = _rule("R7_wl_drop_hybrid")
    return [_sh_pattern(m["form"], m["value"]) for m in r7["members"] if m["gate"] == "when_not_lld"]


def _sh_translate_target_fn() -> str:
    r5 = _rule("R5_triplet_translate")
    lines = ['_zig_tr_translate_target() {', '    case "$1" in']
    for fam in r5["action"]["families"]:
        if "prefix" in fam:
            lines.append(f'        {fam["prefix"]}*)   echo "{fam["replace"]}" ;;')
        else:
            infix = fam["infix"]
            suffix = fam["replace_suffix"]
            lines.append(f'        *{infix}*)    echo "${{1%%{infix}*}}{suffix}" ;;')
    lines.append('        *)                     echo "$1" ;;')
    lines.append("    esac")
    lines.append("}")
    return "\n".join(lines)


def _sh_intercept_body(rule: dict, unix: dict) -> str:
    """Return the bash body (indented for a `case` arm) for one intercept
    rule's print-action. Each arm ends with `exit 0` -- this function is
    meant to be `source`d, so `exit` here really does exit the wrapper
    process (see _sh_intercept_dispatch_fn's docstring)."""
    op = rule["action"]["op"]
    if op == "intercept_print_search_dirs":
        zig_lib = unix["zig_lib"].format(conda_prefix="${_tr_conda_prefix}")
        programs = unix["programs_dir"].format(conda_prefix="${_tr_conda_prefix}")
        return f"""            local _zig_lib="{zig_lib}"
            local _arch_leaf="lib-x86_64"
            [[ "${{_tr_target_arch}}" == "aarch64" ]] && _arch_leaf="libarm64"
            echo "install: ${{_zig_lib}}/"
            echo "programs: ={programs}"
            echo "libraries: =${{_zig_lib}}/libc/mingw/lib-common:${{_zig_lib}}/libc/mingw/${{_arch_leaf}}:${{_zig_lib}}"
            exit 0"""
    if op == "intercept_print_file_name":
        return """            _name="${_a#-print-file-name=}"
            for _dir in "${_tr_conda_prefix}/lib/zig-llvm/lib" "${_tr_conda_prefix}/lib"; do
                if [[ -e "${_dir}/${_name}" ]]; then
                    echo "${_dir}/${_name}"
                    exit 0
                fi
            done
            echo "${_name}"
            exit 0"""
    if op == "intercept_print_multi_os_directory":
        return """            echo "."
            exit 0"""
    if op == "intercept_print_prog_name":
        return """            _name="${_a#-print-prog-name=}"
            _prog="${_tr_conda_prefix}/bin/${_name}"
            if [[ -e "${_prog}" ]]; then
                echo "${_prog}"
            else
                echo "${_name}"
            fi
            exit 0"""
    if op == "intercept_print_sysroot":
        # _sr is a global _zig-cc-common.sh's sysroot-detection block
        # computes BEFORE sourcing this fragment / calling
        # _zig_translate_flags -- empty when unset/unset-dir, mirroring
        # that an empty _sr means no -isysroot is injected either.
        return """            echo "${_sr:-}"
            exit 0"""
    if op == "intercept_print_multiarch":
        return """            if (( _tr_is_win_target )); then
                _zig_tr_translate_target "${_tr_target_arch}-w64-mingw32"
            else
                _zig_tr_translate_target "${_tr_target_arch}-conda-linux-gnu"
            fi
            exit 0"""
    raise ValueError(f"unsupported intercept op for bash: {op!r}")


def _sh_intercept_dispatch_fn() -> str:
    """Single-pass dispatch over ALL intercept rules applicable to the
    unix profile (R2, R3, R10, R11, R12, R13 -- all six, since the bash
    wrapper only ever runs on the unix profile). Replaces the old
    one-dedicated-for-loop-per-rule shape with one loop, one `case`, one
    arg scan, table-driven from RULES.
    """
    unix = PROFILE_DATA["unix"]
    arms = []
    for rule in rules_for_profile("unix"):
        if rule["kind"] != "intercept":
            continue
        pattern = " | ".join(_sh_pattern(rule["match"]["form"], v) for v in rule["match"]["values"])
        arms.append(f"        {pattern})\n{_sh_intercept_body(rule, unix)}\n            ;;")
    arms_text = "\n".join(arms)
    return f"""    # R2/R3/R10-R13: intercept rules -- single arg scan, one case dispatch.
    for _a in "${{_tr_in_args[@]}}"; do
        case "$_a" in
{arms_text}
        esac
    done"""


def generate_bash() -> str:
    always_patterns = " | ".join(_sh_wl_drop_always_patterns())
    when_not_lld_patterns = _sh_wl_drop_when_not_lld_patterns()
    # R7 may have zero gate=when_not_lld members (e.g. after the 2026-07-15
    # narrowing to the 3 always-drop flags); an empty pattern list would
    # otherwise emit a syntactically invalid bash `case "$_a" in )` block.
    if when_not_lld_patterns:
        when_not_lld_block = f"""        if (( ! _tr_use_lld )); then
            case "$_a" in
                {" | \\\n                ".join(when_not_lld_patterns)})
                    _i=$((_i + 1))
                    continue
                    ;;
            esac
        fi
"""
    else:
        when_not_lld_block = ""

    intercept_dispatch = _sh_intercept_dispatch_fn()

    header = (
        f"# {_GEN_BANNER}".rstrip().replace("\n", "\n# ")
    )

    body = f"""{header}
#
# _zig_translate_flags -- shared flag-translation rules R1-R13 (unix
# profile only -- this fragment is only ever sourced by the bash wrapper,
# which always runs on the unix profile).
#
# Contract:
#   Inputs (globals, caller sets before calling):
#     _tr_in_args       : array  - args to translate (e.g. "$@")
#     _tr_conda_prefix  : string - $CONDA_PREFIX
#     _tr_target_arch   : string - baked-in @ZIG_TARGET_ARCH@
#     _tr_is_win_target : 0|1    - whether the baked-in zig target is a
#                         windows/mingw target (drives R1's -Map rewrite)
#     _tr_mode_is_cxx   : 0|1    - 1 for c++ mode, 0 for cc mode
#   Outputs (globals, set by this function):
#     _tr_out_args : array  - translated args. Already includes any
#                    injected "-mcpu=baseline" (R6, prepended first) and
#                    translated -target/--target= values (R5); does NOT
#                    include the zig binary path, the mode token, or
#                    "-fuse-ld=lld" (those remain hand-written in the
#                    sourcing wrapper, out of scope here).
#     _tr_use_lld  : 0|1  - caller MUST OR this with its own hand-written
#                    scan for the remaining out-of-scope LLD triggers
#                    (--version-script, --dynamic-list, --gc-sections,
#                    --build-id, --allow-shlib-undefined, -fuse-ld=lld
#                    itself) before deciding whether to prepend
#                    "-fuse-ld=lld".
#     _tr_mode_out : string - possibly downgraded to "cc" by R4.
#
# May print R2/R3/R10-R13 output directly and `exit 0` -- this function is meant
# to be `source`d (not run in a subshell), so `exit` here really does
# exit the whole wrapper process, matching the pre-refactor fragment's
# behavior.
_zig_translate_flags() {{
    local _a _i _n _dir _name _prog
    local _argc=${{#_tr_in_args[@]}}

{intercept_dispatch}

    # Pre-scan: use_lld triggers (R8, R9-trigger-subset) + -mcpu= presence (R6).
    _tr_use_lld=0
    local _has_mcpu=0
    for _i in "${{!_tr_in_args[@]}}"; do
        _a="${{_tr_in_args[$_i]}}"
        case "$_a" in
            -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic|-Bsymbolic-functions|-Bsymbolic) _tr_use_lld=1 ;;
            -Wl,-z,defs|-Wl,-z,nodelete) _tr_use_lld=1 ;;
            -Wl,-O[0-9]*) _tr_use_lld=1 ;;
            -mcpu=*) _has_mcpu=1 ;;
        esac
        if [[ "$_a" == "-Xlinker" ]]; then
            _n="${{_tr_in_args[$((_i + 1))]:-}}"
            case "$_n" in
                -Bsymbolic-functions|-Bsymbolic) _tr_use_lld=1 ;;
            esac
        fi
    done

    _tr_out_args=()
    (( _has_mcpu )) || _tr_out_args+=("-mcpu=baseline")

    local _saw_nostdlibxx=0
    _i=0
    while [[ $_i -lt $_argc ]]; do
        _a="${{_tr_in_args[$_i]}}"

        # R1: -Map rewrite (mingw targets only)
        if (( _tr_is_win_target )); then
            case "$_a" in
                -Map)
                    _n="${{_tr_in_args[$((_i + 1))]:-}}"
                    if [[ -n "$_n" ]]; then
                        _tr_out_args+=("-Wl,-Map,${{_n}}")
                        _i=$((_i + 2))
                        continue
                    fi
                    ;;
                -Map=*)
                    _tr_out_args+=("-Wl,-Map,${{_a#-Map=}}")
                    _i=$((_i + 1))
                    continue
                    ;;
                -Map?*)
                    _tr_out_args+=("-Wl,-Map,${{_a#-Map}}")
                    _i=$((_i + 1))
                    continue
                    ;;
            esac
        fi

        # R4: -nostdlib++ strip + mode downgrade
        if [[ "$_a" == "-nostdlib++" ]]; then
            _saw_nostdlibxx=1
            _i=$((_i + 1))
            continue
        fi

        # R8: -Xlinker Bsymbolic(-functions) pair -- keep verbatim (already
        # counted toward use_lld in the pre-scan above).
        if [[ "$_a" == "-Xlinker" ]]; then
            _n="${{_tr_in_args[$((_i + 1))]:-}}"
            case "$_n" in
                -Bsymbolic-functions|-Bsymbolic)
                    _tr_out_args+=("$_a" "$_n")
                    _i=$((_i + 2))
                    continue
                    ;;
            esac
        fi

        # R7: hybrid-gated -Wl,* drop -- gate=always members first.
        case "$_a" in
            {always_patterns})
                _i=$((_i + 1))
                continue
                ;;
        esac
        # R7: gate=when_not_lld members -- only while use_lld is inactive.
        # (block is empty when R7 has no when_not_lld members, e.g. after
        # the 2026-07-15 narrowing to the 3 always-drop flags.)
{when_not_lld_block}
        # R9: -Wl,-z,* / -Wl,-O* -- always kept, never dropped (falls
        # through to the default keep below; the trigger subset was
        # already counted toward use_lld in the pre-scan above).

        # R5: -target / --target= translation
        if [[ "$_a" == "-target" ]]; then
            _n="${{_tr_in_args[$((_i + 1))]:-}}"
            _tr_out_args+=("$_a" "$(_zig_tr_translate_target "$_n")")
            _i=$((_i + 2))
            continue
        fi
        case "$_a" in
            --target=*)
                _tr_out_args+=("--target=$(_zig_tr_translate_target "${{_a#--target=}}")")
                _i=$((_i + 1))
                continue
                ;;
        esac

        _tr_out_args+=("$_a")
        _i=$((_i + 1))
    done

    _tr_mode_out="cc"
    (( _tr_mode_is_cxx )) && _tr_mode_out="c++"
    (( _saw_nostdlibxx )) && _tr_mode_out="cc"
}}

# R5 helper: conda triplet -> zig triplet (unix profile: includes darwin).
{_sh_translate_target_fn()}
"""
    return body


# ---------------------------------------------------------------------------
# Main / --check
# ---------------------------------------------------------------------------
def _write(path: Path, content: str) -> None:
    path.write_text(content)


def _regenerate_into(dest_dir: Path) -> tuple[Path, Path]:
    c_path = dest_dir / "_translate.inc"
    sh_path = dest_dir / "_translate.gen.sh"
    _write(c_path, generate_c())
    _write(sh_path, generate_bash())
    return c_path, sh_path


def _check() -> int:
    with tempfile.TemporaryDirectory() as td:
        tmp_c, tmp_sh = _regenerate_into(Path(td))
        drift = False
        for committed, fresh in ((_C_OUT, tmp_c), (_SH_OUT, tmp_sh)):
            if not committed.exists():
                print(f"DRIFT: {committed} does not exist yet (run without --check first)")
                drift = True
                continue
            if not filecmp.cmp(committed, fresh, shallow=False):
                print(f"DRIFT: {committed} differs from regenerated output")
                a = committed.read_text().splitlines(keepends=True)
                b = fresh.read_text().splitlines(keepends=True)
                diff = difflib.unified_diff(a, b, fromfile=str(committed), tofile="regenerated")
                sys.stdout.writelines(diff)
                drift = True
        if drift:
            return 1
        print("OK: _translate.inc and _translate.gen.sh match the manifest.")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate to a temp dir and diff against the committed files; exit 1 on drift",
    )
    args = parser.parse_args()

    if args.check:
        return _check()

    _regenerate_into(_THIS_DIR)
    print(f"wrote {_C_OUT}")
    print(f"wrote {_SH_OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
