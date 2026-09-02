/*
 * Hand-written test harness for recipe/building/_translate.inc (the
 * GENERATED flag translators). NOT itself generated -- part of the
 * test_flag_translation_parity.py "generated-C leg" (recipe/testing/).
 *
 * Compiled by the test script via:
 *   cc -I recipe/building recipe/testing/_translate_harness.c -o <tmp>
 *
 * Usage:
 *   _translate_harness <unix|win> <cc|cxx> [flags...]
 *
 * Behavior mirrors the zig_translate_flags() contract documented in
 * _translate.inc:
 *   - profile "unix" -> is_win=0, is_win_target=0
 *   - profile "win"  -> is_win=1, is_win_target=1
 *   - conda_prefix   -> $CONDA_PREFIX if set, else "/opt/conda"
 *   - zig_target_arch -> "x86_64" (fixed; not exercised by the golden table)
 *   - sysroot        -> "" (fixed; mirrors the empty _sr the bash leg
 *                       resolves in the parity test's tmpdir env -- see the
 *                       comment at the profile.sysroot assignment below)
 *   - *out_mode_is_cxx is initialized to 1 for "cxx" mode, 0 for "cc" mode
 *     BEFORE calling zig_translate_flags, per the caller-owns-init
 *     convention documented in _translate.inc (R4 only ever downgrades
 *     cxx->cc, never upgrades).
 *
 * Output on success (return 0):
 *   one translated out_argv token per line, followed by:
 *     USE_LLD=<0|1>
 *     MODE_CXX=<0|1>
 *
 * On R2/R3 intercept (return 2): zig_translate_flags() already printed
 * the intercept output to stdout itself -- this harness adds nothing and
 * exits with status 2 so the caller can distinguish the intercept path
 * from a normal translation.
 *
 * On allocation failure (return 1): harness exits with status 1.
 */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include "_translate.inc"

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <unix|win> <cc|cxx> [flags...]\n", argv[0]);
        return 1;
    }

    const char *profile_name = argv[1];
    const char *mode_name = argv[2];

    const char *conda_prefix = getenv("CONDA_PREFIX");
    if (!conda_prefix || conda_prefix[0] == '\0') conda_prefix = "/opt/conda";

    zig_translate_profile profile;
    if (strcmp(profile_name, "win") == 0) {
        profile.is_win = 1;
        profile.is_win_target = 1;
    } else {
        profile.is_win = 0;
        profile.is_win_target = 0;
    }
    profile.conda_prefix = conda_prefix;
    profile.zig_target_arch = "x86_64";
    /* The parity env yields an empty _sr on the bash leg: CONDA_PREFIX is a
     * tmpdir with no <arch>-conda-linux-gnu/sysroot, and CONDA_BUILD_SYSROOT is
     * popped by the test (test_flag_translation_parity.py:161). "" is the
     * faithful mirror. Real sysroot resolution belongs to the Phase 3a shim. */
    profile.sysroot = "";

    /* Caller-owned init per _translate.inc contract: 1 for "cxx", 0 for "cc". */
    int out_mode_is_cxx = (strcmp(mode_name, "cxx") == 0) ? 1 : 0;

    char **out_argv = NULL;
    int out_argc = 0;
    int out_use_lld = 0;

    /* argv[0] excluded by convention; argv[1]/argv[2] are harness-only
     * (profile/mode), so the translated flags start at argv[3]. */
    int in_argc = argc - 3;
    char *const *in_argv = (char *const *)(argv + 3);

    int rc = zig_translate_flags(in_argc, in_argv, &profile,
                                  &out_argv, &out_argc, &out_use_lld, &out_mode_is_cxx);

    if (rc == 2) {
        /* R2/R3 intercept already printed to stdout by zig_translate_flags. */
        return 2;
    }
    if (rc == 1) {
        return 1;
    }

    for (int i = 0; i < out_argc; i++) {
        printf("%s\n", out_argv[i]);
    }
    printf("USE_LLD=%d\n", out_use_lld);
    printf("MODE_CXX=%d\n", out_mode_is_cxx);

    return 0;
}
