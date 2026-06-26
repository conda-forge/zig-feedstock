#!/usr/bin/env python3
"""Section 1 — RC mode passthrough tests (should PASS against build-28 code).

Tests for the inline ``-o`` → ``-fo`` rewrite shipped in build-28 at
``recipe/building/zig-wrapper.c:946-962`` when the wrapper is invoked as
``<triplet>-zig-rc``.

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import platform
import sys
import tempfile

from pathlib import Path

from _test_utils import (
    COFF_MACHINE_AARCH64,
    COFF_MACHINE_I386,
    COFF_MACHINE_X86_64,
    FAIL,
    PASS,
    SKIP,
    WARN,
    _build_is_win,
    _results,
    _run,
    coff_machine_type,
    compile_minimal_rc,
    get_zig_wrapper,
    setup_zig_global_cache_dir,
)

# ---------------------------------------------------------------------------
# Platform detection (mirrors test_zig_toolchain.py conventions)
# ---------------------------------------------------------------------------
_host = os.environ.get("CONDA_ZIG_HOST", "")
_triplet = _host.removesuffix("-zig") if _host.endswith("-zig") else _host
_arch = _triplet.split("-")[0] if _triplet else platform.machine()
if _arch == "arm64":
    _arch = "aarch64"

_ARCH_TO_MACHINE: dict[str, int] = {
    "x86_64": COFF_MACHINE_X86_64,
    "aarch64": COFF_MACHINE_AARCH64,
    "i686": COFF_MACHINE_I386,
    "i386": COFF_MACHINE_I386,
}

setup_zig_global_cache_dir()


def _rc_wrapper() -> str | None:
    """Return the rc wrapper path string, or None if not present."""
    p = get_zig_wrapper("rc")
    if not p.exists():
        return None
    return str(p)


def test_rc_dash_o_standalone_form_translates_to_fo() -> None:
    """``-o out.res`` (space-separated) is rewritten to ``-fo out.res``."""
    print("--- RC: -o standalone form translates to -fo ---")

    rc = _rc_wrapper()
    if rc is None:
        SKIP("rc -o standalone", "wrapper rc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("rc -o standalone", "RC compilation only meaningful for Windows targets")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        rc_file = compile_minimal_rc(td_path)
        out_file = td_path / "out.res"

        cmd = [rc, "-i", str(rc_file), "-o", str(out_file), "-O", "coff"]
        r = _run(cmd, cwd=td, timeout=30)
        if r.returncode != 0:
            FAIL("rc -o standalone: exit 0", f"rc={r.returncode} stderr={r.stderr[:2000]}")
            return
        if not out_file.exists():
            FAIL("rc -o standalone: output exists", str(out_file))
            return
        if out_file.stat().st_size == 0:
            FAIL("rc -o standalone: output non-empty", "file is 0 bytes")
            return
        machine = coff_machine_type(out_file)
        expected = _ARCH_TO_MACHINE.get(_arch, 0)
        if expected != 0 and machine != expected:
            WARN(
                "rc -o standalone: machine type",
                f"got 0x{machine:04X}, expected 0x{expected:04X} for arch {_arch!r}",
            )
        else:
            PASS("rc -o standalone: output COFF created", f"machine=0x{machine:04X}")


def test_rc_dash_o_concatenated_form_translates_to_fo() -> None:
    """``-o<path>`` (concatenated) is rewritten to ``-fo<path>``."""
    print("--- RC: -o concatenated form translates to -fo ---")

    rc = _rc_wrapper()
    if rc is None:
        SKIP("rc -o concatenated", "wrapper rc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("rc -o concatenated", "RC compilation only meaningful for Windows targets")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        rc_file = compile_minimal_rc(td_path)
        out_file = td_path / "out.res"

        # Concatenated form: -o/path/to/out.res  (no space)
        cmd = [rc, "-i", str(rc_file), f"-o{out_file}", "-O", "coff"]
        r = _run(cmd, cwd=td, timeout=30)
        if r.returncode != 0:
            FAIL("rc -o concatenated: exit 0", f"rc={r.returncode} stderr={r.stderr[:2000]}")
            return
        if not out_file.exists():
            FAIL("rc -o concatenated: output exists", str(out_file))
            return
        if out_file.stat().st_size == 0:
            FAIL("rc -o concatenated: output non-empty", "file is 0 bytes")
            return
        PASS("rc -o concatenated: output COFF created")


def test_rc_passes_through_d_and_i_flags() -> None:
    """``-DFOO=1 -I/tmp`` pass through without breaking RC compilation."""
    print("--- RC: -D and -I flags pass through ---")

    rc = _rc_wrapper()
    if rc is None:
        SKIP("rc -D/-I passthrough", "wrapper rc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("rc -D/-I passthrough", "RC compilation only meaningful for Windows targets")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        rc_file = compile_minimal_rc(td_path)
        out_file = td_path / "out.res"

        cmd = [rc, "-DFOO=1", "-I/tmp", "-i", str(rc_file), "-o", str(out_file)]
        r = _run(cmd, cwd=td, timeout=30)
        if r.returncode != 0:
            FAIL("rc -D/-I passthrough: exit 0", f"rc={r.returncode} stderr={r.stderr[:2000]}")
        else:
            PASS("rc -D/-I passthrough: exit 0")


def test_rc_version_probe_still_works() -> None:
    """``<triplet>-zig-rc --version`` exits 0 and mentions version info."""
    print("--- RC: --version probe still works ---")

    rc = _rc_wrapper()
    if rc is None:
        SKIP("rc --version", "wrapper rc not found — needs build env")
        return

    r = _run([rc, "--version"], timeout=15)
    if r.returncode != 0:
        FAIL("rc --version: exit 0", f"rc={r.returncode} stderr={r.stderr[:500]}")
        return

    combined = r.stdout + r.stderr
    if not combined.strip():
        WARN("rc --version: output non-empty", "stdout and stderr were both empty")
    else:
        PASS("rc --version: exit 0 with output")


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== RC Mode Passthrough Tests ===")
    print(f"  CONDA_ZIG_HOST = {_host!r}")
    print(f"  triplet        = {_triplet!r}")
    print(f"  arch           = {_arch!r}")
    print()

    test_rc_dash_o_standalone_form_translates_to_fo()
    test_rc_dash_o_concatenated_form_translates_to_fo()
    test_rc_passes_through_d_and_i_flags()
    test_rc_version_probe_still_works()

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

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
