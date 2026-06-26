#!/usr/bin/env python3
"""Section 2 item 4 -- ``__tsan_*`` symbol filtering on mingw targets (should FAIL against build-28).

Tests that no ``__tsan_*`` symbols appear as undefined references in object files
compiled for Windows/mingw targets.  Outcome-only -- mechanism-agnostic.

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
    FAIL,
    PASS,
    SKIP,
    WARN,
    _results,
    _run,
    get_bare_zig_wrapper,
    nm_symbols,
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

# Long cache paths trigger a cold-compile integer-overflow panic when
# cross-compiling *-windows-gnu (PR #120); a short /tmp path clears it.
_short_cache = os.path.join(tempfile.gettempdir(), "zig-tsan-cache")
os.makedirs(_short_cache, exist_ok=True)
os.environ["ZIG_GLOBAL_CACHE_DIR"] = _short_cache
os.environ["ZIG_LOCAL_CACHE_DIR"] = _short_cache

_MINIMAL_MAIN_C = "int main(void) { return 0; }\n"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_no_tsan_undefined_refs_in_windows_gnu_object(arch: str, target: str) -> None:
    """No ``__tsan_*`` undefined symbols appear in a *target* compiled object."""
    print(f"--- tsan filter: {target} object ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP(f"tsan filter {target}", "wrapper cc not found -- needs build env")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        src = td_path / "test.c"
        src.write_text(_MINIMAL_MAIN_C, encoding="utf-8")
        obj = td_path / f"{arch}_obj"

        cmd = [zig, "cc", "-target", target, "-c", "-o", str(obj), str(src)]
        r = _run(cmd, cwd=td, timeout=60)

        if r.stderr == "TIMEOUT":
            WARN(f"tsan filter {target}: compile", "timed out (60s)")
            return

        if r.returncode != 0:
            FAIL(
                f"tsan filter {target}: compile exit 0",
                f"rc={r.returncode} stderr={r.stderr[:2000]}",
            )
            return

        if not obj.exists():
            FAIL(f"tsan filter {target}: object exists", str(obj))
            return

        symbols = nm_symbols(obj)
        if not symbols:
            SKIP(
                f"tsan filter {target}: nm check",
                "llvm-nm not on PATH or produced no output",
            )
            return

        tsan_undefined = [
            name for name, letter in symbols.items()
            if name.startswith("__tsan_") and letter == "U"
        ]
        if tsan_undefined:
            FAIL(
                f"tsan filter {target}: no __tsan_* undefined",
                f"undefined tsan symbols found: {tsan_undefined[:10]}",
            )
        else:
            PASS(f"tsan filter {target}: no __tsan_* undefined refs in object")


def test_linux_target_unaffected_by_filter() -> None:
    """``-target x86_64-linux-gnu -c`` still compiles successfully (no regression)."""
    print("--- tsan filter: linux target unaffected ---")

    zig = get_bare_zig_wrapper()
    if zig is None:
        SKIP("tsan filter linux unaffected", "wrapper cc not found -- needs build env")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        src = td_path / "test.c"
        src.write_text(_MINIMAL_MAIN_C, encoding="utf-8")
        obj = td_path / "test.o"

        cmd = [zig, "cc", "-target", "x86_64-linux-gnu", "-c", "-o", str(obj), str(src)]
        r = _run(cmd, cwd=td, timeout=60)

        if r.stderr == "TIMEOUT":
            WARN("tsan filter linux unaffected: compile", "timed out (60s)")
            return

        if r.returncode != 0:
            FAIL(
                "tsan filter linux unaffected: compile exit 0",
                f"rc={r.returncode} stderr={r.stderr[:2000]}",
            )
        elif not obj.exists():
            FAIL("tsan filter linux unaffected: object exists", str(obj))
        else:
            PASS("tsan filter linux unaffected: x86_64-linux-gnu -c succeeds")


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== TSan Filter Tests ===")
    print(f"  CONDA_ZIG_HOST = {_host!r}")
    print(f"  triplet        = {_triplet!r}")
    print(f"  arch           = {_arch!r}")
    print()

    # Run linux-target compile FIRST as a warmup -- empirically primes zig's
    # internal state and may prevent a GHA-runner-specific integer-overflow
    # panic observed in CI when windows-gnu compiles run cold (see PR #120).
    test_linux_target_unaffected_by_filter()
    test_no_tsan_undefined_refs_in_windows_gnu_object("aarch64", "aarch64-windows-gnu")
    test_no_tsan_undefined_refs_in_windows_gnu_object("x86_64", "x86_64-windows-gnu")

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
        print("\nFAIL: test environment not properly set up -- all sub-tests skipped (likely CONDA_ZIG_HOST unset or wrapper binary not found)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
