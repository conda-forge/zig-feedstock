#!/usr/bin/env python3
"""Section 3 A4 resurrection — ``--zig-wrapper-self-test`` flag (should FAIL against build-28).

Build-28 has no ``--zig-wrapper-self-test`` handler in ``zig-wrapper.c``, so every
invocation with that flag will exit non-zero.  These tests will FAIL until the
handler ships.

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import platform
import re
import sys
import tempfile

from pathlib import Path

from _test_utils import (
    FAIL,
    PASS,
    SKIP,
    WARN,
    _results,
    _run,
    get_bare_zig_wrapper,
    get_zig_wrapper,
    setup_zig_global_cache_dir,
)

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
_host = os.environ.get("CONDA_ZIG_HOST", "")
_triplet = _host.removesuffix("-zig") if _host.endswith("-zig") else _host
_arch = _triplet.split("-")[0] if _triplet else platform.machine()
if _arch == "arm64":
    _arch = "aarch64"

setup_zig_global_cache_dir()

# Path to wrapper_modes.txt — set at test runtime if known
_WRAPPER_MODES_TXT_ENV = "WRAPPER_MODES_TXT"
# Fallback: resolve relative to this file's recipe/building directory
_RECIPE_DIR = Path(__file__).parent.parent  # recipe/
_DEFAULT_WRAPPER_MODES_TXT = _RECIPE_DIR / "building" / "wrapper_modes.txt"


def _wrapper_modes_txt() -> Path | None:
    """Return the wrapper_modes.txt Path from env or default location."""
    env_val = os.environ.get(_WRAPPER_MODES_TXT_ENV, "")
    if env_val:
        return Path(env_val)
    if _DEFAULT_WRAPPER_MODES_TXT.exists():
        return _DEFAULT_WRAPPER_MODES_TXT
    return None




def _read_modes_lines(path: Path) -> list[str]:
    """Read wrapper_modes.txt; return non-comment, non-blank lines."""
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            lines.append(stripped)
    return lines


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_self_test_basic_invocation() -> None:
    """``<triplet>-zig --zig-wrapper-self-test`` exits 0 and prints a summary line."""
    print("--- self-test: basic invocation ---")

    zig = get_bare_zig_wrapper(fallback_to_cc=False)
    if zig is None:
        SKIP("self-test basic", "bare wrapper <triplet>-zig not found — needs build env")
        return

    r = _run([zig, "--zig-wrapper-self-test"], timeout=15)
    if r.returncode != 0:
        FAIL(
            "self-test basic: exit 0",
            f"rc={r.returncode} stdout={r.stdout[:500]} stderr={r.stderr[:500]}",
        )
        return

    combined = r.stdout + r.stderr
    pattern = r"wrapper self-test OK: \d+ modes consistent"
    if re.search(pattern, combined):
        PASS("self-test basic: output matches 'wrapper self-test OK: N modes consistent'")
    else:
        FAIL(
            "self-test basic: output format",
            f"expected pattern {pattern!r} not found in output={combined[:500]}",
        )


def test_self_test_from_non_zig_basename() -> None:
    """``<triplet>-zig-cc --zig-wrapper-self-test`` exits 0 (any wrapper basename works)."""
    print("--- self-test: from non-zig basename (zig-cc) ---")

    cc = get_zig_wrapper("cc")
    if not cc.exists():
        SKIP("self-test non-zig basename", "wrapper cc not found — needs build env")
        return

    r = _run([str(cc), "--zig-wrapper-self-test"], timeout=15)
    if r.returncode != 0:
        FAIL(
            "self-test non-zig basename: exit 0",
            f"rc={r.returncode} stdout={r.stdout[:500]} stderr={r.stderr[:500]}",
        )
    else:
        PASS("self-test non-zig basename: exit 0 from zig-cc invocation")


def test_self_test_with_explicit_good_path() -> None:
    """``--zig-wrapper-self-test=<path>`` with a valid wrapper_modes.txt exits 0."""
    print("--- self-test: explicit good modes path ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("self-test explicit good path", "no wrapper found — needs build env")
        return

    modes_txt = _wrapper_modes_txt()
    if modes_txt is None:
        SKIP(
            "self-test explicit good path",
            f"wrapper_modes.txt not found (set {_WRAPPER_MODES_TXT_ENV} or ensure "
            f"{_DEFAULT_WRAPPER_MODES_TXT} exists)",
        )
        return

    r = _run([zig, f"--zig-wrapper-self-test={modes_txt}"], timeout=15)
    if r.returncode != 0:
        FAIL(
            "self-test explicit good path: exit 0",
            f"rc={r.returncode} stdout={r.stdout[:500]} stderr={r.stderr[:500]}",
        )
    else:
        PASS(f"self-test explicit good path: exit 0 with {modes_txt.name}")


def test_self_test_missing_entry_detected() -> None:
    """A modes file missing one real suffix causes exit != 0 and names the missing suffix."""
    print("--- self-test: missing entry detected ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("self-test missing entry", "no wrapper found — needs build env")
        return

    modes_txt = _wrapper_modes_txt()
    if modes_txt is None:
        SKIP(
            "self-test missing entry",
            f"wrapper_modes.txt not found (set {_WRAPPER_MODES_TXT_ENV})",
        )
        return

    lines = _read_modes_lines(modes_txt)
    if not lines:
        SKIP("self-test missing entry", "wrapper_modes.txt has no entries")
        return

    # Drop the last real entry (e.g. "windres" or whatever the last entry is)
    dropped = lines[-1]
    truncated_lines = lines[:-1]

    with tempfile.TemporaryDirectory() as td:
        bad_modes = Path(td) / "bad_modes.txt"
        bad_modes.write_text("\n".join(truncated_lines) + "\n", encoding="utf-8")

        r = _run([zig, f"--zig-wrapper-self-test={bad_modes}"], timeout=15)
        if r.returncode == 0:
            FAIL(
                "self-test missing entry: exit != 0",
                f"expected non-zero exit for missing {dropped!r}, got exit 0",
            )
            return

        combined = r.stdout + r.stderr
        if dropped in combined:
            PASS(f"self-test missing entry: exit != 0 and names dropped suffix {dropped!r}")
        else:
            WARN(
                "self-test missing entry: dropped suffix named in output",
                f"dropped={dropped!r} not found in output={combined[:500]}",
            )
            PASS("self-test missing entry: exit != 0 (suffix not named in output)")


def test_self_test_extra_entry_detected() -> None:
    """A modes file with an extra unknown suffix causes exit != 0 mentioning that suffix."""
    print("--- self-test: extra entry detected ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("self-test extra entry", "no wrapper found — needs build env")
        return

    modes_txt = _wrapper_modes_txt()
    if modes_txt is None:
        SKIP(
            "self-test extra entry",
            f"wrapper_modes.txt not found (set {_WRAPPER_MODES_TXT_ENV})",
        )
        return

    lines = _read_modes_lines(modes_txt)
    extra_suffix = "unknown-mode"
    augmented_lines = lines + [extra_suffix]

    with tempfile.TemporaryDirectory() as td:
        bad_modes = Path(td) / "bad_modes.txt"
        bad_modes.write_text("\n".join(augmented_lines) + "\n", encoding="utf-8")

        r = _run([zig, f"--zig-wrapper-self-test={bad_modes}"], timeout=15)
        if r.returncode == 0:
            FAIL(
                "self-test extra entry: exit != 0",
                f"expected non-zero exit for extra {extra_suffix!r}, got exit 0",
            )
            return

        combined = r.stdout + r.stderr
        if extra_suffix in combined:
            PASS(f"self-test extra entry: exit != 0 and names extra suffix {extra_suffix!r}")
        else:
            WARN(
                "self-test extra entry: extra suffix named in output",
                f"{extra_suffix!r} not found in output={combined[:500]}",
            )
            PASS("self-test extra entry: exit != 0 (suffix not named in output)")


def test_self_test_duplicate_detected() -> None:
    """A modes file with ``cc`` listed twice causes exit != 0 mentioning duplicate or 'cc'."""
    print("--- self-test: duplicate entry detected ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("self-test duplicate", "no wrapper found — needs build env")
        return

    modes_txt = _wrapper_modes_txt()
    if modes_txt is None:
        SKIP(
            "self-test duplicate",
            f"wrapper_modes.txt not found (set {_WRAPPER_MODES_TXT_ENV})",
        )
        return

    lines = _read_modes_lines(modes_txt)
    # Add "cc" a second time (it's always in the list; if not, add it anyway)
    dup_entry = "cc"
    duplicated_lines = lines + [dup_entry]

    with tempfile.TemporaryDirectory() as td:
        bad_modes = Path(td) / "bad_modes.txt"
        bad_modes.write_text("\n".join(duplicated_lines) + "\n", encoding="utf-8")

        r = _run([zig, f"--zig-wrapper-self-test={bad_modes}"], timeout=15)
        if r.returncode == 0:
            FAIL(
                "self-test duplicate: exit != 0",
                "expected non-zero exit for duplicate 'cc' entry, got exit 0",
            )
            return

        combined = (r.stdout + r.stderr).lower()
        if "duplicate" in combined or "cc" in combined:
            PASS("self-test duplicate: exit != 0 and output mentions 'duplicate' or 'cc'")
        else:
            WARN(
                "self-test duplicate: output mentions duplicate/cc",
                f"output={combined[:500]}",
            )
            PASS("self-test duplicate: exit != 0")


def test_self_test_path_not_found() -> None:
    """``--zig-wrapper-self-test=/nonexistent/path`` exits != 0 and mentions the path."""
    print("--- self-test: path not found ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("self-test path not found", "no wrapper found — needs build env")
        return

    bad_path = "/nonexistent/path"
    r = _run([zig, f"--zig-wrapper-self-test={bad_path}"], timeout=15)

    if r.returncode == 0:
        FAIL(
            "self-test path not found: exit != 0",
            f"expected non-zero exit for missing path {bad_path!r}, got exit 0",
        )
        return

    combined = r.stdout + r.stderr
    if bad_path in combined:
        PASS(f"self-test path not found: exit != 0 and mentions {bad_path!r}")
    else:
        WARN(
            "self-test path not found: path named in output",
            f"{bad_path!r} not found in output={combined[:500]}",
        )
        PASS("self-test path not found: exit != 0")


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== Wrapper Self-Test Flag Tests ===")
    print(f"  CONDA_ZIG_HOST     = {_host!r}")
    print(f"  triplet            = {_triplet!r}")
    modes_txt = _wrapper_modes_txt()
    print(f"  wrapper_modes.txt  = {modes_txt!r}")
    print()

    test_self_test_basic_invocation()
    test_self_test_from_non_zig_basename()
    test_self_test_with_explicit_good_path()
    test_self_test_missing_entry_detected()
    test_self_test_extra_entry_detected()
    test_self_test_duplicate_detected()
    test_self_test_path_not_found()

    print()
    n_pass = len(_results["PASS"])
    n_fail = len(_results["FAIL"])
    n_warn = len(_results["WARN"])
    n_skip = len(_results["SKIP"])
    print(
        f"=== Results: {n_pass} passed, {n_fail} failed, "
        f"{n_warn} warnings, {n_skip} skipped ==="
    )

    if n_fail > 0:
        print("\nFailed tests:")
        for name in _results["FAIL"]:
            print(f"  - {name}")

    if n_fail > 0:
        return 1
    if n_pass == 0 and n_skip > 0:
        print("\nFAIL: test environment not properly set up — all sub-tests skipped (likely CONDA_ZIG_HOST unset or wrapper binary not found)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
