#!/usr/bin/env python3
"""
Parity + syntax-gate tests for the zig-cc/zig-cxx flag-translation logic
driven by the shared manifest (recipe/building/flag_rules.py), which is
generated into recipe/building/_translate.gen.sh (bash) and
recipe/building/_translate.inc (C, included by zig-cc-unix.c), plus the
Windows compiled shim (recipe/building/zig-cc-nonunix.c).

recipe/scripts/_zig-cc-common.sh (the former hand-written bash fragment that
this suite used to golden-test directly) has been DELETED: its logic is now
compiled into zig-cc-unix.c via _translate.inc. This module therefore has
two legs left, both fragment-independent:
  - Leg (A)/(B): GEN_CASES -- token-predicate assertions run against the
    GENERATED translators directly (_translate.inc via a small C harness,
    and _translate.gen.sh sourced in bash), proving the manifest-driven
    unix and win profiles agree.
  - Leg (C): run_unix_shim_compile_leg -- `-fsyntax-only` compiles
    zig-cc-unix.c (the live runtime path) to keep it warning-clean.

Not pytest: matches the custom PASS/FAIL/WARN/SKIP harness used by
test_zig_toolchain.py (see _test_utils.py) so this runs standalone with
just bash + python -- no zig install, no $ZIG_CC required.

Exit codes:
  0 = no FAILs
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from _test_utils import PASS, FAIL, WARN, SKIP, _results

# Anchor: __file__ is <base>/testing/<thisfile>. At local-dev time <base> is
# recipe/; at rattler-build test time the `files: recipe:` entries (recipe.yaml)
# stage under the test-step dir with the SAME scripts/ building/ testing/ layout,
# so <base> is the step dir. parents[1] is correct for BOTH layouts; do NOT
# prepend a "recipe" segment (it only exists in the local checkout, and adding
# it makes the path resolve one level too deep at rattler test time, which is
# the FileNotFoundError seen across all CI columns in PR #115).
_RECIPE_DIR = Path(__file__).resolve().parents[1]

_BASH = shutil.which("bash")

# ---------------------------------------------------------------------------
# GENERATED-leg constants (recipe/building/_translate.inc, _translate.gen.sh)
# ---------------------------------------------------------------------------
_BUILDING_DIR = _RECIPE_DIR / "building"
_TRANSLATE_GEN_SH = _BUILDING_DIR / "_translate.gen.sh"
_HARNESS_C = _RECIPE_DIR / "testing" / "_translate_harness.c"
_UNIX_SHIM_C = _BUILDING_DIR / "zig-cc-unix.c"


# ---------------------------------------------------------------------------
# Shared bash `declare -p` array parser (used by the generated-bash leg)
# ---------------------------------------------------------------------------
def _parse_declare_p_array(output: str, varname: str) -> list[str] | None:
    """Parse `declare -p <varname>` bash output for an indexed array.

    Tolerates both serializations: GNU bash 4+ emits
    `declare -a NAME=([0]="a" [1]="b")`, while macOS bash 3.2 wraps the
    whole RHS in an extra outer pair of single quotes:
    `declare -a NAME='([0]="a" [1]="b")'`. The optional `'?` around the
    parens absorbs the bash-3.2 form so osx (bash 3.2) parses the same as
    linux/win (bash 4+). Without it, osx sourced fine but exec_args came
    back None (PR #115 build 1554311 osx FAILs, generated-C leg green).
    """
    m = re.search(
        rf"declare -a {re.escape(varname)}='?\((.*)\)'?\s*$",
        output, re.DOTALL | re.MULTILINE
    )
    if not m:
        return None
    items = re.findall(r'\[\d+\]="((?:[^"\\]|\\.)*)"', m.group(1))
    return [re.sub(r'\\(.)', r'\1', item) for item in items]


# ===================================================================
# GENERATED-leg golden table
#
# These two legs assert that the GENERATED translators
# (recipe/building/_translate.inc / _translate.gen.sh) implement the
# WINNER behavior directly, independent of any hand-written bash fragment.
#
# Assertions are RULE-RELEVANT TOKEN predicates, not full-array equality:
# the generated function's *out_argv is a PARTIAL argv that excludes
# wrapper plumbing (zig binary path, mode token, "-fuse-ld=lld", a
# default -target) which stays hand-written in the sourcing/calling
# wrapper -- see the _translate.inc module header.
# ===================================================================


@dataclass(frozen=True)
class GenResult:
    """Normalized result shape shared by both the C harness and the bash
    _zig_translate_flags() capture, so assertions can be leg-agnostic."""

    returncode: int
    tokens: list[str]
    use_lld: int
    is_cxx: int
    stdout: str


def _gen_both(pred: Callable[[GenResult], bool]) -> Callable[[GenResult, GenResult], tuple[bool, str]]:
    """Wrap a single-result predicate into an assertion checked against
    BOTH the unix and win profile runs (used for rules that do not depend
    on is_win/is_win_target)."""

    def _check(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
        ok = (
            unix_res.returncode == 0
            and pred(unix_res)
            and win_res.returncode == 0
            and pred(win_res)
        )
        detail = (
            f"unix.rc={unix_res.returncode} unix.tokens={unix_res.tokens!r} "
            f"unix.use_lld={unix_res.use_lld} | win.rc={win_res.returncode} "
            f"win.tokens={win_res.tokens!r} win.use_lld={win_res.use_lld}"
        )
        return ok, detail

    return _check


def _gen_map_assert(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
    # R1's -Map rewrite is gated on is_win_target, which only the "win"
    # profile sets in this harness -- see _translate_harness.c / the win
    # branch of _bash_gen_capture's is_win_target derivation.
    ok = win_res.returncode == 0 and "-Wl,-Map,foo.map" in win_res.tokens
    return ok, f"win.rc={win_res.returncode} win.tokens={win_res.tokens!r}"


def _gen_intercept_assert(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
    def _intercepted(r: GenResult) -> bool:
        if r.returncode == 2:  # C harness convention
            return True
        # bash convention: `exit 0` after printing the triplet directly
        return r.returncode == 0 and all(
            k in r.stdout for k in ("install:", "programs:", "libraries:")
        )

    ok = _intercepted(unix_res) and _intercepted(win_res)
    return ok, (
        f"unix.rc={unix_res.returncode} unix.stdout={unix_res.stdout[:200]!r} | "
        f"win.rc={win_res.returncode} win.stdout={win_res.stdout[:200]!r}"
    )


def _gen_sysroot_assert(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
    # R12 is unix-only. Asserted on the unix result ONLY, deliberately:
    # the generated-BASH dispatch is built from rules_for_profile("unix")
    # unconditionally (the bash wrapper never runs the win profile), so its
    # win leg also intercepts -- while generated-C's win profile passes
    # -print-sysroot through. That divergence is by design and the assertion
    # cannot tell the two legs apart, so win_res is not constrained here.
    # Mirror-image of _gen_map_assert, which asserts on win_res only.
    def _intercepted_empty(r: GenResult) -> bool:
        if r.returncode == 2:            # C harness convention
            return r.stdout.strip() == ""
        # bash convention: `exit 0` after echoing "${_sr:-}" (empty here)
        return r.returncode == 0 and r.stdout.strip() == ""

    ok = _intercepted_empty(unix_res)
    return ok, f"unix.rc={unix_res.returncode} unix.stdout={unix_res.stdout[:200]!r}"


def _gen_mode_downgrade_assert(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
    ok = (
        unix_res.returncode == 0
        and unix_res.is_cxx == 0
        and win_res.returncode == 0
        and win_res.is_cxx == 0
    )
    return ok, f"unix.is_cxx={unix_res.is_cxx} win.is_cxx={win_res.is_cxx}"


def _gen_target_assert(unix_res: GenResult, win_res: GenResult) -> tuple[bool, str]:
    def _ok(r: GenResult) -> bool:
        return "x86_64-linux-gnu" in r.tokens and not any("conda-" in t for t in r.tokens)

    ok = unix_res.returncode == 0 and _ok(unix_res) and win_res.returncode == 0 and _ok(win_res)
    return ok, f"unix.tokens={unix_res.tokens!r} win.tokens={win_res.tokens!r}"


@dataclass(frozen=True)
class GenCase:
    id: int
    desc: str
    mode: str  # "cc" | "cxx"
    argv: list[str]
    assertion: Callable[[GenResult, GenResult], tuple[bool, str]]


GEN_CASES: list[GenCase] = [
    GenCase(
        1, "bare -Map rewritten to -Wl,-Map,FILE (win profile / is_win_target)",
        "cc", ["-Map", "foo.map"], _gen_map_assert,
    ),
    GenCase(
        2, "-Map=foo.map rewritten to -Wl,-Map,FILE (win profile / is_win_target)",
        "cc", ["-Map=foo.map"], _gen_map_assert,
    ),
    GenCase(
        3, "-print-search-dirs intercepted (exit 2 / install:+programs:+libraries:)",
        "cc", ["-print-search-dirs"], _gen_intercept_assert,
    ),
    GenCase(
        4, "-nostdlib++ downgrades cxx mode to cc",
        "cxx", ["-nostdlib++"], _gen_mode_downgrade_assert,
    ),
    GenCase(
        5, "-target x86_64-conda-linux-gnu strips conda- infix",
        "cc", ["-target", "x86_64-conda-linux-gnu"], _gen_target_assert,
    ),
    GenCase(
        6, "-mcpu=native kept verbatim, no -mcpu=baseline injected",
        "cc", ["-mcpu=native"],
        _gen_both(lambda r: "-mcpu=native" in r.tokens and "-mcpu=baseline" not in r.tokens),
    ),
    GenCase(
        7, "-Wl,--color-diagnostics always dropped",
        "cc", ["-Wl,--color-diagnostics"],
        _gen_both(lambda r: "-Wl,--color-diagnostics" not in r.tokens),
    ),
    GenCase(
        8, "-Wl,-z,now kept (passthrough)",
        "cc", ["-Wl,-z,now"],
        _gen_both(lambda r: "-Wl,-z,now" in r.tokens),
    ),
    GenCase(
        9, "-Wl,-z,defs kept AND activates use_lld",
        "cc", ["-Wl,-z,defs"],
        _gen_both(lambda r: "-Wl,-z,defs" in r.tokens and r.use_lld == 1),
    ),
    GenCase(
        10, "-Wl,-O2 kept AND activates use_lld",
        "cc", ["-Wl,-O2"],
        _gen_both(lambda r: "-Wl,-O2" in r.tokens and r.use_lld == 1),
    ),
    GenCase(
        11, "-Xlinker -Bsymbolic-functions kept AND activates use_lld",
        "cc", ["-Xlinker", "-Bsymbolic-functions"],
        _gen_both(lambda r: "-Bsymbolic-functions" in r.tokens and r.use_lld == 1),
    ),
    GenCase(
        12, "combo: -z,defs kept+lld active, --color-diagnostics still dropped",
        "cc", ["-Wl,-z,defs", "-Wl,--color-diagnostics"],
        _gen_both(
            lambda r: "-Wl,-z,defs" in r.tokens
            and r.use_lld == 1
            and "-Wl,--color-diagnostics" not in r.tokens
        ),
    ),
    GenCase(
        13, "combo: -O2 kept+lld active, -rpath-link still dropped",
        "cc", ["-Wl,-rpath-link,/x", "-Wl,-O2"],
        _gen_both(
            lambda r: "-Wl,-O2" in r.tokens
            and r.use_lld == 1
            and not any(t.startswith("-Wl,-rpath-link") for t in r.tokens)
        ),
    ),
    GenCase(
        14, "-print-sysroot intercepted on unix profile, prints empty _sr",
        "cc", ["-print-sysroot"], _gen_sysroot_assert,
    ),
]


# ---------------------------------------------------------------------------
# Leg (A): generated-C (_translate.inc via the compiled _translate_harness.c)
# ---------------------------------------------------------------------------
def _compile_c_harness() -> Path | None:
    """Compile _translate_harness.c against the GENERATED _translate.inc.
    Returns the binary path, or None if no C compiler is on PATH (the leg
    SKIPs gracefully in that case)."""
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc:
        return None
    tmpdir = Path(tempfile.mkdtemp(prefix="zig_translate_harness_"))
    binpath = tmpdir / "_translate_harness"
    proc = subprocess.run(
        [cc, "-I", str(_BUILDING_DIR), str(_HARNESS_C), "-o", str(binpath)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0 or not binpath.exists():
        return None
    return binpath


def _c_harness_capture(
    harness: Path, profile: str, mode: str, argv: list[str], *, conda_prefix: str
) -> GenResult:
    env = dict(os.environ)
    env["CONDA_PREFIX"] = conda_prefix
    try:
        proc = subprocess.run(
            [str(harness), profile, mode, *argv],
            capture_output=True, text=True, timeout=15, env=env,
        )
    except subprocess.TimeoutExpired:
        return GenResult(returncode=-1, tokens=[], use_lld=-1, is_cxx=-1, stdout="TIMEOUT")

    if proc.returncode in (1, 2):
        return GenResult(returncode=proc.returncode, tokens=[], use_lld=-1, is_cxx=-1, stdout=proc.stdout)

    lines = proc.stdout.splitlines()
    use_lld = -1
    is_cxx = -1
    tokens: list[str] = []
    for line in lines:
        if line.startswith("USE_LLD="):
            use_lld = int(line[len("USE_LLD="):])
        elif line.startswith("MODE_CXX="):
            is_cxx = int(line[len("MODE_CXX="):])
        else:
            tokens.append(line)
    return GenResult(returncode=proc.returncode, tokens=tokens, use_lld=use_lld, is_cxx=is_cxx, stdout=proc.stdout)


def run_generated_c_leg() -> None:
    """Leg (A): assert the GENERATED C translator (_translate.inc) matches
    the golden table's token-based predicates."""
    print("--- Generated-C leg (_translate.inc via _translate_harness.c) ---")
    harness = _compile_c_harness()
    if harness is None:
        SKIP("generated-C leg (genC)", "no C compiler found on PATH")
        return

    conda_prefix = tempfile.mkdtemp(prefix="zig_translate_conda_")
    for gcase in GEN_CASES:
        name = f"[{gcase.id:02d}-genC] {gcase.desc}"
        unix_res = _c_harness_capture(harness, "unix", gcase.mode, gcase.argv, conda_prefix=conda_prefix)
        win_res = _c_harness_capture(harness, "win", gcase.mode, gcase.argv, conda_prefix=conda_prefix)
        ok, detail = gcase.assertion(unix_res, win_res)
        PASS(name) if ok else FAIL(name, detail)


# ---------------------------------------------------------------------------
# Leg (B): generated-bash (_translate.gen.sh, sourced -- _zig_translate_flags)
# ---------------------------------------------------------------------------
def _bash_gen_capture(
    profile: str, mode: str, argv: list[str], *, conda_prefix: str, arch: str = "x86_64"
) -> GenResult:
    if not _BASH:
        return GenResult(returncode=-1, tokens=[], use_lld=-1, is_cxx=-1, stdout="")

    is_win_target = 1 if profile == "win" else 0
    mode_is_cxx = 1 if mode == "cxx" else 0
    quoted_argv = " ".join(shlex.quote(a) for a in argv)
    script = (
        f"_tr_in_args=({quoted_argv})\n"
        f"_tr_conda_prefix={shlex.quote(conda_prefix)}\n"
        f"_tr_target_arch={shlex.quote(arch)}\n"
        f"_tr_is_win_target={is_win_target}\n"
        f"_tr_mode_is_cxx={mode_is_cxx}\n"
        f"source {shlex.quote(str(_TRANSLATE_GEN_SH))}\n"
        f"_zig_translate_flags\n"
        f"declare -p _tr_out_args\n"
        f'echo "$_tr_use_lld"\n'
        f'echo "$_tr_mode_out"\n'
    )
    try:
        proc = subprocess.run([_BASH, "-c", script], capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        return GenResult(returncode=-1, tokens=[], use_lld=-1, is_cxx=-1, stdout="TIMEOUT")

    tokens = _parse_declare_p_array(proc.stdout, "_tr_out_args") or []
    lines = proc.stdout.splitlines()
    use_lld = -1
    mode_out = ""
    if len(lines) >= 2:
        try:
            use_lld = int(lines[-2])
        except ValueError:
            use_lld = -1
        mode_out = lines[-1]
    is_cxx = 1 if mode_out == "c++" else 0
    return GenResult(returncode=proc.returncode, tokens=tokens, use_lld=use_lld, is_cxx=is_cxx, stdout=proc.stdout)


def run_generated_bash_leg() -> None:
    """Leg (B): assert the GENERATED bash translator (_translate.gen.sh)
    matches the golden table's token-based predicates."""
    print("--- Generated-bash leg (_translate.gen.sh, sourced) ---")
    if not _BASH:
        SKIP("generated-bash leg (genB)", "bash unavailable")
        return

    conda_prefix = tempfile.mkdtemp(prefix="zig_translate_conda_")
    for gcase in GEN_CASES:
        name = f"[{gcase.id:02d}-genB] {gcase.desc}"
        unix_res = _bash_gen_capture("unix", gcase.mode, gcase.argv, conda_prefix=conda_prefix)
        win_res = _bash_gen_capture("win", gcase.mode, gcase.argv, conda_prefix=conda_prefix)
        ok, detail = gcase.assertion(unix_res, win_res)
        PASS(name) if ok else FAIL(name, detail)


# ---------------------------------------------------------------------------
# Leg (C): the unix shim must COMPILE (zig-cc-unix.c + unix_common.h)
# ---------------------------------------------------------------------------
def run_unix_shim_compile_leg() -> None:
    """Leg (C): syntax-check the unix C shim sources.

    zig-cc-unix.c IS now compiled by install_zig_activation.py (the unix
    multiplexer), but only on unix build hosts; this leg is the strict
    syntax gate that keeps it warning-clean everywhere else.
    Syntax-only: nothing is linked and no artifact is produced.

    -std=c11 is deliberately STRICTER than production, which passes no -std=
    at all (_compile_c_shim in install_zig_activation.py).  Strict mode forces
    the POSIX feature-test-macro question, which is exactly how the setenv()
    implicit-declaration bug was caught; keeping it strict here keeps that
    class of bug visible instead of depending on a gnu-dialect default.

    Any diagnostic at all is a FAIL: the sources are currently warning-clean,
    and -Wimplicit-function-declaration is a hard error on clang >= 16 (which
    zig cc is built on), so warnings here are not cosmetic.
    """
    print("--- Unix shim compile leg (zig-cc-unix.c + unix_common.h) ---")
    name = "[unix-shim] zig-cc-unix.c syntax-clean (-std=c11 -Wall -Wextra)"

    if not _UNIX_SHIM_C.exists():
        SKIP(name, f"{_UNIX_SHIM_C.name} not staged in this environment")
        return

    # POSIX-only sources (unix_common.h pulls errno.h/unistd.h), and this recipe
    # installs only triplet-prefixed compilers -- so on a Windows host the bare
    # which() below can only find an unrelated runner-image binary whose headers
    # will not resolve. Nothing to syntax-check here.
    if sys.platform == "win32":
        SKIP(name, "unix shim sources are POSIX-only (Windows host)")
        return

    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc:
        SKIP(name, "no C compiler on PATH")
        return

    proc = subprocess.run(
        [cc, "-std=c11", "-Wall", "-Wextra", "-fsyntax-only", str(_UNIX_SHIM_C)],
        capture_output=True,
        text=True,
    )
    diagnostics = proc.stderr.strip()
    if proc.returncode != 0:
        FAIL(name, f"compile FAILED (cc={cc}, rc={proc.returncode}):\n{diagnostics}")
    elif diagnostics:
        FAIL(name, f"compiled but emitted diagnostics (cc={cc}):\n{diagnostics}")
    else:
        PASS(name)


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== Flag Translation Parity (generated-translator + shim-compile legs) ===")
    print(f"  bash            = {_BASH!r}")
    print()

    if not _BASH:
        print("  [skip-all] bash not found on PATH -- generated-bash leg cases will SKIP")

    run_generated_c_leg()

    print()
    run_generated_bash_leg()

    print()
    run_unix_shim_compile_leg()

    print()
    n_pass = len(_results["PASS"])
    n_fail = len(_results["FAIL"])
    n_warn = len(_results["WARN"])
    n_skip = len(_results["SKIP"])
    print(
        f"=== Results: {n_pass} passed, {n_fail} failed, "
        f"{n_warn} warnings, {n_skip} skipped ==="
    )

    def _leg_counts(tag: str) -> tuple[int, int, int, int]:
        return tuple(
            sum(1 for n in _results[status] if tag in n) for status in ("PASS", "FAIL", "WARN", "SKIP")
        )

    genc_counts = _leg_counts("genC")
    genb_counts = _leg_counts("genB")
    shim_counts = _leg_counts("unix-shim")

    print()
    print("=== Per-leg breakdown (pass/fail/warn/skip) ===")
    print(f"  generated-C    : {genc_counts}")
    print(f"  generated-bash : {genb_counts}")
    print(f"  unix-shim      : {shim_counts}")

    if n_fail:
        print("\nFailed tests (clean-lock regressions or capture errors):")
        for name in _results["FAIL"]:
            print(f"  - {name}")

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
