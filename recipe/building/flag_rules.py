"""
recipe/building/flag_rules.py

Pure-data manifest of the SHARED (de-duplicated) flag-translation rules for
the zig cc/c++ wrapper family. This module has NO side effects and performs
NO I/O -- it only defines Python data structures. It is consumed by
gen_translators.py, which turns it into:

  - recipe/building/_translate.inc      (portable C translation function,
                                          included by zig-cc-nonunix.c /
                                          zig-tool-nonunix.c)
  - recipe/building/_translate.gen.sh   (bash translation function, sourced
                                          by _zig-cc-common.sh)

SCOPE: rules R1-R13 below are de-duplicated here. Everything else in
_zig-cc-common.sh / zig-cc-nonunix.c that is NOT one of these rules
(sysroot *detection* itself -- R12 only prints the already-computed _sr
value, -Xlinker general trigger/drop besides Bsymbolic, -march/-mtune/
-fstack-protector/... drops, MSVC /MANIFEST* handling, -Wl,-e<sym> entry
translation, cache-dir init, MACOSX_DEPLOYMENT_TARGET override) stays
hand-written in the wrappers and is intentionally left OUT of this
manifest.

Grounded against (2026-07-15):
  - recipe/scripts/_zig-cc-common.sh (removed bash original, superseded by recipe/building/zig-cc-unix.c)
  - recipe/building/zig-cc-nonunix.c
  - recipe/building/nonunix_common.h

===========================================================================
SCHEMA
===========================================================================

Each entry in RULES is a dict with this common envelope:

  id            str   stable unique identifier, e.g. "R1_map_rewrite"
  kind          str   one of RULE_KINDS below -- selects the code-generation
                       path used by gen_translators.py for this rule
  profiles      tuple[str, ...]  subset of PROFILES this rule applies to
                       (both R1-R9 apply to both profiles at the rule level;
                       individual members/families within a rule may be
                       scoped to a single profile -- see "profiles" on
                       members/families below)
  gate          str   "always" | "when_not_lld" | "per_member" | "n/a"
                       - "always": fires unconditionally
                       - "when_not_lld": only fires while use_lld is 0; once
                         use_lld becomes 1 the matched flag is left
                         untouched (falls through as kept)
                       - "per_member": this rule's gate varies per member;
                         see the "gate" key on each entry in "members"
                       - "n/a": gate concept does not apply (rewrite /
                         intercept / mode-override / translate rules)
  lld_trigger   bool  True if matching this rule sets use_lld=1 as a
                       side effect (independent of "gate")
  match         dict  top-level match-spec (only meaningful for single-
                       pattern rules; rules with "members"/"families" use
                       those instead and set match={"form": "n/a"})
  action        dict  action-spec, see ACTION KINDS below
  members       list[dict]  (R7, R9 only) per-flag sub-specs
  families      list[dict]  (R5 only) per-target-family sub-specs

---------------------------------------------------------------------------
RULE_KINDS (top-level "kind")
---------------------------------------------------------------------------
  "rewrite"           R1 -- token rewritten to a fixed-template replacement
  "intercept"         R2, R3, R10-R13 -- print profile-specific text then
                      exit 0
  "mode_override"     R4 -- strip flag, force translation mode
  "target_translate"  R5 -- rewrite -target/--target= value via "families"
  "option_preserve"   R6 -- keep user value if present, else inject default
  "wl_drop_gated"     R7 -- per-member gated drop of -Wl,* flags
  "keep_trigger"      R8 -- keep flag verbatim + force use_lld=1
  "z_o_split"         R9 -- prefix family split: trigger-subset vs
                       passthrough-rest, both kept, never dropped

---------------------------------------------------------------------------
MATCH KINDS (match["form"]) -- used by single-pattern rules (R1-R4, R6)
---------------------------------------------------------------------------
  "exact"         match["values"]: list[str] of exact tokens
  "prefix"        match["values"]: list[str] of prefixes (starts_with)
  "concat_split"  match["token"]: bare token (e.g. "-Map") that can appear
                  as: bare + separate next-arg, "TOKEN=value", or
                  "TOKENvalue" (concatenated, no separator) -- only used
                  by R1
  "target_value"  no values; R5 scans for -target <val> / --target=<val>
                  specifically (dedicated scan, not a generic prefix/exact
                  match) -- see action["families"]

---------------------------------------------------------------------------
MEMBER MATCH KINDS (per-entry "form" inside "members"/"families")
---------------------------------------------------------------------------
  "exact"          member["value"]: exact token
  "prefix"         member["value"]: prefix (starts_with)
  "xlinker_pair"   member["value"]: exact token that appears as the
                   argument immediately AFTER a literal "-Xlinker" token
                   (R8 only)

---------------------------------------------------------------------------
ACTION KINDS (action["op"])
---------------------------------------------------------------------------
  "rewrite_map"                 (R1) rewrite -Map forms to
                                 "-Wl,-Map,<file>"; only fires when
                                 profile.is_win_target is true (mingw
                                 target); non-mingw targets keep the
                                 original arg(s) unchanged
  "intercept_print_search_dirs" (R2) profile-specific install:/programs:/
                                 libraries: triplet, then exit 0
  "intercept_print_file_name"   (R3) probe profile-specific dirs for the
                                 named file, print resolved path or the
                                 bare name, then exit 0
  "intercept_print_multi_os_directory" (R10) print "." (no multilib
                                 support -- standard GCC behavior), then
                                 exit 0
  "intercept_print_prog_name"   (R11) probe profile's programs_dir (bin
                                 dir) for the named program, print
                                 resolved path or the bare name (mirrors
                                 R3's fallback), then exit 0
  "intercept_print_sysroot"     (R12, unix profile only) print the _sr
                                 shell variable that _zig-cc-common.sh's
                                 sysroot-detection block already computed
                                 (empty string if unset/empty -- mirrors
                                 that an empty _sr means no -isysroot is
                                 injected either), then exit 0
  "intercept_print_multiarch"   (R13) synthesize this profile/arch's
                                 conda-style triplet and reuse R5's
                                 target_translate function/logic to
                                 produce the Debian-style value, then
                                 exit 0
  "mode_override"               (R4) action["strip"]=True drops the flag
                                 from output; action["force_mode"] is the
                                 mode value to force (only ever downgrades,
                                 never upgrades: c++ -> cc)
  "target_translate"            (R5) rewrite the -target/--target= value
                                 using action["families"] (see below)
  "preserve_or_default"         (R6) if ANY arg in argv matches this rule's
                                 top-level match-spec, keep it verbatim and
                                 do NOT inject action["default"]; else
                                 inject action["default"] once
  "drop"                        (R7) drop the matched flag entirely,
                                 subject to each member's own "gate"
  "keep_and_trigger_lld"        (R8) keep the matched flag (and, for
                                 xlinker_pair members, the preceding
                                 "-Xlinker" token) verbatim, force
                                 use_lld=1
  "z_o_split"                   (R9) see "families"-like "members" below:
                                 each member defines a prefix + a trigger
                                 sub-match; flags matching the prefix are
                                 ALWAYS kept (never dropped); flags whose
                                 suffix also matches the trigger sub-match
                                 additionally force use_lld=1

R5 "families" entries:
  dict(prefix=str, replace=str, profiles=tuple[str,...])
      exact-prefix family: if the target value starts_with "prefix",
      replace the WHOLE value with "replace" (used for the two mingw32
      families)
  dict(infix=str, replace_suffix=str, profiles=tuple[str,...])
      infix-strip family: if "infix" occurs anywhere in the value, keep
      only the portion of the value BEFORE the first occurrence of
      "infix" and append "replace_suffix" (used for *-conda-linux-gnu*;
      any trailing suffix after the infix, e.g. a trailing version, is
      DROPPED -- this matches both the current bash %%-conda-linux-gnu*
      parameter expansion and the current C strstr+snprintf logic)
  Family list is evaluated in order; first match wins. A family's
  "profiles" tuple restricts it to that profile only (used for the two
  darwin-apple families, which are unix-profile-only: the Windows shim
  never targets darwin).

PROFILES = ("unix", "win")

PROFILE_DATA: dict[str, dict] -- literal per-profile template data needed
by R2/R3's intercept actions (path separators, directory layouts). Keys
use {conda_prefix} / {zig_lib} / {arch_dir} placeholders that the
generator substitutes with the profile's actual runtime expression (an
env-var read in C, a shell variable in bash) -- these are STRING
TEMPLATES, not literal paths.
"""

from __future__ import annotations

PROFILES: tuple[str, ...] = ("unix", "win")

# ---------------------------------------------------------------------------
# Per-profile literal data for the intercept rules that need per-profile
# path templates (R2, R3, R11 -- R10/R12/R13 need no PROFILE_DATA entries).
# ---------------------------------------------------------------------------
PROFILE_DATA: dict[str, dict] = {
    "unix": dict(
        path_sep=":",
        dir_sep="/",
        zig_lib="{conda_prefix}/lib/zig",
        programs_dir="{conda_prefix}/bin/",
        mingw_common="{zig_lib}/libc/mingw/lib-common",
        arch_dirs={
            "aarch64": "{zig_lib}/libc/mingw/libarm64",
            # x86/i386/i686: all three are aliases the 32-bit-x86 arch
            # normaliser can produce (mirrors _mingw.sh's own
            # `case "${_win_arch}" in x86|i386|i686)` -- see _mingw.sh).
            # Only "x86" is actually reachable today via
            # install_zig_activation.py's `zig_triplet.split("-")[0]`
            # derivation (zig_triplet == "x86-windows-msvc" for win-32),
            # but all three are added here for parity/robustness.
            "x86": "{zig_lib}/libc/mingw/lib32",
            "i386": "{zig_lib}/libc/mingw/lib32",
            "i686": "{zig_lib}/libc/mingw/lib32",
            "*": "{zig_lib}/libc/mingw/lib-x86_64",
        },
        print_file_name_probe_dirs=[
            "{conda_prefix}/lib/zig-llvm/lib",
            "{conda_prefix}/lib",
        ],
    ),
    "win": dict(
        path_sep=";",
        dir_sep="\\",
        zig_lib="{conda_prefix}\\Library\\lib\\zig",
        programs_dir="{conda_prefix}\\Library\\bin\\",
        mingw_common="{zig_lib}\\libc\\mingw\\lib-common",
        arch_dirs={
            "aarch64": "{zig_lib}\\libc\\mingw\\libarm64",
            # x86/i386/i686: see the matching comment in the "unix" profile
            # above -- same aliases, same rationale.
            "x86": "{zig_lib}\\libc\\mingw\\lib32",
            "i386": "{zig_lib}\\libc\\mingw\\lib32",
            "i686": "{zig_lib}\\libc\\mingw\\lib32",
            "*": "{zig_lib}\\libc\\mingw\\lib-x86_64",
        },
        print_file_name_probe_dirs=[
            "{conda_prefix}\\Library\\lib\\zig-llvm\\lib",
            "{conda_prefix}\\Library\\lib",
        ],
    ),
}

# ---------------------------------------------------------------------------
# R1 -- bare -Map / -Map=FILE / -MapFILE -> -Wl,-Map,FILE (mingw targets only)
# ---------------------------------------------------------------------------
R1_MAP_REWRITE = dict(
    id="R1_map_rewrite",
    kind="rewrite",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="concat_split", token="-Map"),
    action=dict(op="rewrite_map", template="-Wl,-Map,{value}", only_if_win_target=True),
)

# ---------------------------------------------------------------------------
# R2 -- -print-search-dirs intercept + exit 0
# ---------------------------------------------------------------------------
R2_PRINT_SEARCH_DIRS = dict(
    id="R2_print_search_dirs",
    kind="intercept",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="exact", values=["-print-search-dirs"]),
    action=dict(op="intercept_print_search_dirs"),
)

# ---------------------------------------------------------------------------
# R3 -- -print-file-name=<name> intercept + exit 0
# ---------------------------------------------------------------------------
R3_PRINT_FILE_NAME = dict(
    id="R3_print_file_name",
    kind="intercept",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="prefix", values=["-print-file-name="]),
    action=dict(op="intercept_print_file_name"),
)

# ---------------------------------------------------------------------------
# R4 -- -nostdlib++ downgrades mode c++ -> cc, flag itself is stripped
# ---------------------------------------------------------------------------
R4_NOSTDLIBXX = dict(
    id="R4_nostdlibxx",
    kind="mode_override",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="exact", values=["-nostdlib++"]),
    action=dict(op="mode_override", strip=True, force_mode="cc"),
)

# ---------------------------------------------------------------------------
# R5 -- conda triplet -> zig triplet translation for -target/--target=
# ---------------------------------------------------------------------------
R5_TRIPLET_TRANSLATE = dict(
    id="R5_triplet_translate",
    kind="target_translate",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="target_value"),
    action=dict(
        op="target_translate",
        families=[
            dict(prefix="x86_64-w64-mingw32", replace="x86_64-windows-gnu", profiles=PROFILES),
            dict(prefix="aarch64-w64-mingw32", replace="aarch64-windows-gnu", profiles=PROFILES),
            dict(infix="-conda-linux-gnu", replace_suffix="-linux-gnu", profiles=PROFILES),
            # unix-profile-only: the Windows shim never targets darwin.
            dict(prefix="x86_64-apple-darwin", replace="x86_64-macos-none", profiles=("unix",)),
            dict(prefix="arm64-apple-darwin", replace="aarch64-macos-none", profiles=("unix",)),
        ],
    ),
)

# ---------------------------------------------------------------------------
# R6 -- [WINNER] preserve user -mcpu=<val>; inject -mcpu=baseline only if
# absent. NOTE: bash currently has a pre-existing BUG this rule fixes -- see
# the returned report's ambiguity/grounding notes.
# ---------------------------------------------------------------------------
R6_MCPU_PRESERVE = dict(
    id="R6_mcpu_preserve",
    kind="option_preserve",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="prefix", values=["-mcpu="]),
    action=dict(op="preserve_or_default", default="-mcpu=baseline"),
)

# ---------------------------------------------------------------------------
# R7 -- [NARROWED 2026-07-15] wl_drop_hybrid is restricted to the 3 flags
# that are GENUINELY SHARED between the C wrapper's is_wl_drop() and the
# bash wrapper's unconditional drop set, all gate=always:
#   -Wl,--color-diagnostics, -Wl,-rpath-link*, -Wl,--disable-new-dtags
#
# The other historical C is_wl_drop() members (--allow-shlib-undefined,
# --no-allow-shlib-undefined, --version-script*, -soname*, --gc-sections,
# --no-gc-sections, --build-id*, --as-needed, --no-as-needed) are C-ONLY
# (bash never dropped them) and REMAIN hand-written in zig-cc-nonunix.c
# unchanged (block-gated by !use_lld); they are out of the shared de-dup
# scope. -soname is win-only. Trigger-overlap members (-Bsymbolic* -> R8,
# -Wl,-z,*/-Wl,-O* -> R9) keep+trigger via the caller's out-of-scope
# trigger scan, same as before this narrowing.
# ---------------------------------------------------------------------------
R7_WL_DROP_HYBRID = dict(
    id="R7_wl_drop_hybrid",
    kind="wl_drop_gated",
    profiles=PROFILES,
    gate="per_member",
    lld_trigger=False,
    match=dict(form="n/a"),
    action=dict(op="drop"),
    members=[
        # gate=always: unconditionally dropped regardless of use_lld. This
        # is now the ONLY gate value present in R7 -- the "gate" key is
        # retained per-member (and at the schema level) for extensibility,
        # not because a second value is currently in use.
        dict(form="exact", value="-Wl,--color-diagnostics", gate="always"),
        dict(form="prefix", value="-Wl,-rpath-link", gate="always"),
        dict(form="exact", value="-Wl,--disable-new-dtags", gate="always"),
    ],
)

# ---------------------------------------------------------------------------
# R8 -- [WINNER] -Bsymbolic(-functions) in ANY form (bare, -Wl,-prefixed, or
# -Xlinker-passed) is kept verbatim and forces use_lld=1. Current wrappers
# already do this for the bare and -Wl, forms; the fix is adding the
# -Xlinker pair form to the trigger set (currently C silently DROPS
# "-Xlinker -Bsymbolic(-functions)" via is_xlinker_drop() without
# triggering LLD -- that special-case drop must be removed in favor of
# this rule).
# ---------------------------------------------------------------------------
R8_BSYMBOLIC_LLD_TRIGGER = dict(
    id="R8_bsymbolic_lld_trigger",
    kind="keep_trigger",
    profiles=PROFILES,
    gate="always",
    lld_trigger=True,
    match=dict(
        form="multi",
        members=[
            dict(form="xlinker_pair", value="-Bsymbolic-functions"),
            dict(form="xlinker_pair", value="-Bsymbolic"),
            dict(form="exact", value="-Wl,-Bsymbolic-functions"),
            dict(form="exact", value="-Wl,-Bsymbolic"),
            dict(form="exact", value="-Bsymbolic-functions"),
            dict(form="exact", value="-Bsymbolic"),
        ],
    ),
    action=dict(op="keep_and_trigger_lld"),
)

# ---------------------------------------------------------------------------
# R9 -- [WINNER] -Wl,-z,* / -Wl,-O* family split. NEVER dropped (fixes a
# real bug in the current C is_wl_drop(), which blanket-drops the entire
# -Wl,-z,* / -Wl,-O* prefix families when use_lld is 0 -- e.g. -Wl,-z,now
# is currently silently dropped in C, which is wrong: bash's current
# filter loop never drops these at all). The trigger subset additionally
# forces use_lld=1; everything else in the same prefix family is a plain
# keep/passthrough.
# ---------------------------------------------------------------------------
R9_Z_O_PASSTHROUGH = dict(
    id="R9_z_o_passthrough",
    kind="z_o_split",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,  # per-member trigger below
    match=dict(form="n/a"),
    action=dict(op="z_o_split"),
    members=[
        # -Wl,-z,defs / -Wl,-z,nodelete trigger LLD; all other -Wl,-z,*
        # (now, relro, noexecstack, ...) are kept, passthrough only.
        dict(prefix="-Wl,-z,", trigger_values=["defs", "nodelete"]),
        # -Wl,-O<digits> (numeric optimization level) triggers LLD; any
        # other -Wl,-O* (non-numeric suffix) is kept, passthrough only.
        dict(prefix="-Wl,-O", trigger_numeric_suffix=True),
    ],
)

# ---------------------------------------------------------------------------
# R10 -- -print-multi-os-directory intercept + exit 0 (no multilib support,
# standard GCC behavior: always print the current directory).
# ---------------------------------------------------------------------------
R10_PRINT_MULTI_OS_DIRECTORY = dict(
    id="R10_print_multi_os_directory",
    kind="intercept",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="exact", values=["-print-multi-os-directory"]),
    action=dict(op="intercept_print_multi_os_directory"),
)

# ---------------------------------------------------------------------------
# R11 -- -print-prog-name=<name> intercept + exit 0. Same "resolve or
# fallback to bare name" shape as R3, but probes PROFILE_DATA's
# programs_dir (bin dir) instead of R3's lib-dir probe set.
# ---------------------------------------------------------------------------
R11_PRINT_PROG_NAME = dict(
    id="R11_print_prog_name",
    kind="intercept",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="prefix", values=["-print-prog-name="]),
    action=dict(op="intercept_print_prog_name"),
)

# ---------------------------------------------------------------------------
# R12 -- -print-sysroot intercept + exit 0. UNIX PROFILE ONLY: the Windows
# shim (zig-cc-nonunix.c) has no sysroot concept (confirmed via grep), so
# there is nothing to mirror on the win profile -- gen_translators.py must
# filter this rule out of its C/win output via rules_for_profile("win").
# Prints the _sr shell variable _zig-cc-common.sh's sysroot-detection
# block already computes (empty string if unset/empty).
# ---------------------------------------------------------------------------
R12_PRINT_SYSROOT = dict(
    id="R12_print_sysroot",
    kind="intercept",
    profiles=("unix",),
    gate="n/a",
    lld_trigger=False,
    match=dict(form="exact", values=["-print-sysroot"]),
    action=dict(op="intercept_print_sysroot"),
)

# ---------------------------------------------------------------------------
# R13 -- -print-multiarch intercept + exit 0. Reuses R5's target_translate
# families: synthesizes this profile/arch's conda-style triplet (the same
# pre-translation form R5 expects for -target/--target=) and feeds it
# through the SAME translation function/logic R5 uses, so R13 prints
# exactly what R5 would translate that value to -- not a hand-invented
# string.
# ---------------------------------------------------------------------------
R13_PRINT_MULTIARCH = dict(
    id="R13_print_multiarch",
    kind="intercept",
    profiles=PROFILES,
    gate="n/a",
    lld_trigger=False,
    match=dict(form="exact", values=["-print-multiarch"]),
    action=dict(op="intercept_print_multiarch"),
)

RULES: list[dict] = [
    R1_MAP_REWRITE,
    R2_PRINT_SEARCH_DIRS,
    R3_PRINT_FILE_NAME,
    R4_NOSTDLIBXX,
    R5_TRIPLET_TRANSLATE,
    R6_MCPU_PRESERVE,
    R7_WL_DROP_HYBRID,
    R8_BSYMBOLIC_LLD_TRIGGER,
    R9_Z_O_PASSTHROUGH,
    R10_PRINT_MULTI_OS_DIRECTORY,
    R11_PRINT_PROG_NAME,
    R12_PRINT_SYSROOT,
    R13_PRINT_MULTIARCH,
]


def rules_for_profile(profile: str) -> list[dict]:
    """Return RULES applicable to a given profile, in stable manifest order.

    A rule is applicable if the profile is in its top-level "profiles"
    tuple. Per-member/per-family profile scoping (e.g. R5's darwin
    families) is NOT filtered here -- the generator must additionally
    check member/family-level "profiles" when emitting.
    """
    if profile not in PROFILES:
        raise ValueError(f"unknown profile: {profile!r} (expected one of {PROFILES})")
    return [r for r in RULES if profile in r["profiles"]]
