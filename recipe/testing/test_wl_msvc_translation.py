#!/usr/bin/env python3
"""Build-29 wishlist items 1+2 -- -Wl,--stack and -Wl,-Map/-Map translation to MSVC linker flags.

Asserts that the zig cc wrapper rewrites GNU-ld-style linker flags to lld-link
MSVC equivalents before they reach exec:
  item 1: -Wl,--stack,SIZE              ->  -Wl,/STACK:SIZE
  item 2: -Wl,-Map,FILE / bare -Map FILE  ->  -Wl,/MAP:FILE

Both rewritten tokens must appear in the wrapper's ZIG_WRAPPER_DEBUG argv dump
(the "out argv[N]=" lines), confirming they reach the zig cc exec call (lld-link).

Exit codes:
  0 = all passed (or all skipped)
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from _test_utils import (
    FAIL,
    PASS,
    SKIP,
    WARN,
    _results,
    _run,
    get_zig_wrapper,
)


def _cc_wrapper_str():
    """Return the cc wrapper path string, or None if not found."""
    p = get_zig_wrapper("cc")
    if not p.exists():
        return None
    return str(p)


def _zig_real_exists():
    """Return True if share/zig/zig-real(.exe) is present under CONDA_PREFIX.

    The wrapper calls fopen(zig_real_path) before entering the filter loop.
    If zig-real is absent the wrapper exits early and no REWROTE/out-argv DBG
    lines are emitted, which would make the assertions vacuously false.
    """
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if sys.platform == "win32":
        candidates = [
            prefix / "Library" / "share" / "zig" / "zig-real.exe",
            prefix / "Library" / "share" / "zig" / "zig-real",
        ]
    else:
        candidates = [prefix / "share" / "zig" / "zig-real"]
    return any(c.exists() for c in candidates)


def _invoke_wrapper_debug(wrapper, extra_args):
    """Set ZIG_WRAPPER_DEBUG=1, run wrapper with extra_args + -###, return combined output.

    -### makes the real zig cc exit immediately after printing its planned
    command, without compiling; the wrapper's own DBG output is written to
    stderr before exec, so it is captured regardless. Returns None on
    NOTFOUND/TIMEOUT.
    """
    old_dbg = os.environ.get("ZIG_WRAPPER_DEBUG")
    os.environ["ZIG_WRAPPER_DEBUG"] = "1"
    try:
        cmd = [wrapper] + extra_args + ["-###"]
        r = _run(cmd, timeout=30)
    finally:
        if old_dbg is None:
            os.environ.pop("ZIG_WRAPPER_DEBUG", None)
        else:
            os.environ["ZIG_WRAPPER_DEBUG"] = old_dbg
    if r.stderr in ("NOTFOUND", "TIMEOUT"):
        return None
    return r.stderr + r.stdout


def _require_env(label):
    """Return cc wrapper path str if env is usable, else SKIP and return None."""
    wrapper = _cc_wrapper_str()
    if wrapper is None:
        SKIP(label + ": wrapper present", "cc wrapper not found -- needs build env")
        return None
    if not _zig_real_exists():
        SKIP(label + ": zig-real present", "share/zig/zig-real absent -- wrapper exits before filter loop")
        return None
    return wrapper


def test_stack_flag_translated():
    """item 1: -Wl,--stack,0x200000 -> -Wl,/STACK:0x200000 for a Windows target."""
    print("--- wl-msvc: --stack translation (item 1) ---")
    wrapper = _require_env("wl-msvc --stack")
    if wrapper is None:
        return
    out = _invoke_wrapper_debug(wrapper, ["-target", "x86_64-windows-gnu", "-Wl,--stack,0x200000"])
    if out is None:
        WARN("wl-msvc --stack: invoke wrapper", "wrapper did not respond (NOTFOUND or TIMEOUT)")
        return
    if "/STACK:0x200000" in out:
        PASS("wl-msvc --stack: /STACK:0x200000 in out-argv")
    else:
        FAIL("wl-msvc --stack: /STACK:0x200000 in out-argv", "-Wl,/STACK:0x200000 not found in wrapper DBG dump")


def test_wl_map_flag_translated():
    """item 2a: -Wl,-Map,outmap.map -> -Wl,/MAP:outmap.map for a Windows target."""
    print("--- wl-msvc: -Wl,-Map translation (item 2a) ---")
    wrapper = _require_env("wl-msvc -Wl,-Map")
    if wrapper is None:
        return
    out = _invoke_wrapper_debug(wrapper, ["-target", "x86_64-windows-gnu", "-Wl,-Map,outmap.map"])
    if out is None:
        WARN("wl-msvc -Wl,-Map: invoke wrapper", "wrapper did not respond (NOTFOUND or TIMEOUT)")
        return
    if "/MAP:outmap.map" in out:
        PASS("wl-msvc -Wl,-Map: /MAP:outmap.map in out-argv")
    else:
        FAIL("wl-msvc -Wl,-Map: /MAP:outmap.map in out-argv", "-Wl,/MAP:outmap.map not found in wrapper DBG dump")


def test_bare_map_two_token_translated():
    """item 2b: bare two-token -Map baremap.map -> -Wl,/MAP:baremap.map."""
    print("--- wl-msvc: bare -Map FILE translation (item 2b) ---")
    wrapper = _require_env("wl-msvc bare -Map")
    if wrapper is None:
        return
    out = _invoke_wrapper_debug(wrapper, ["-target", "x86_64-windows-gnu", "-Map", "baremap.map"])
    if out is None:
        WARN("wl-msvc bare -Map: invoke wrapper", "wrapper did not respond (NOTFOUND or TIMEOUT)")
        return
    if "/MAP:baremap.map" in out:
        PASS("wl-msvc bare -Map: /MAP:baremap.map in out-argv")
    else:
        FAIL("wl-msvc bare -Map: /MAP:baremap.map in out-argv", "-Wl,/MAP:baremap.map not found in wrapper DBG dump")


def test_stack_not_translated_for_linux_target():
    """Negative control: -Wl,--stack is NOT translated for a Linux target (Windows guard holds)."""
    print("--- wl-msvc: --stack NOT translated for Linux (negative control) ---")
    wrapper = _require_env("wl-msvc linux guard")
    if wrapper is None:
        return
    out = _invoke_wrapper_debug(wrapper, ["-target", "x86_64-linux-gnu", "-Wl,--stack,0x200000"])
    if out is None:
        WARN("wl-msvc linux guard: invoke wrapper", "wrapper did not respond (NOTFOUND or TIMEOUT)")
        return
    if "/STACK:" in out:
        FAIL("wl-msvc linux guard: no /STACK: for linux target", "/STACK: appeared for x86_64-linux-gnu -- Windows guard not firing")
    else:
        PASS("wl-msvc linux guard: /STACK: absent for x86_64-linux-gnu")


def main():
    print("=== -Wl MSVC Translation Tests (build-29 items 1+2) ===")
    print(f"  CONDA_ZIG_HOST = {os.environ.get('CONDA_ZIG_HOST', '')!r}")
    print(f"  CONDA_PREFIX   = {os.environ.get('CONDA_PREFIX', '')!r}")
    print()

    test_stack_flag_translated()
    test_wl_map_flag_translated()
    test_bare_map_two_token_translated()
    test_stack_not_translated_for_linux_target()

    print()
    n_pass = len(_results["PASS"])
    n_fail = len(_results["FAIL"])
    n_warn = len(_results["WARN"])
    n_skip = len(_results["SKIP"])
    print(f"=== Results: {n_pass} passed, {n_fail} failed, {n_warn} warnings, {n_skip} skipped ===")

    if n_fail > 0:
        print("\nFailed tests:")
        for name in _results["FAIL"]:
            print(f"  - {name}")

    if n_fail > 0:
        return 1
    if n_pass == 0 and n_skip > 0:
        print("\nFAIL: test environment not set up -- all sub-tests skipped (CONDA_ZIG_HOST unset, wrapper missing, or zig-real absent)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
