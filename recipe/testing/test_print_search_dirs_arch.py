#!/usr/bin/env python3
"""Section 2 item 1 — arch-correct ``-print-search-dirs`` (should FAIL against build-28).

Build-28 code at ``recipe/building/zig-wrapper.c:344-361`` hardcodes ``lib-x86_64``
regardless of the ``-target`` flag.  These tests will FAIL until item 1 ships
(dynamic arch resolution keyed on ``-target``).

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import platform
import sys
import tempfile

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from pathlib import Path

from _test_utils import (
    FAIL,
    PASS,
    SKIP,
    WARN,
    _results,
    _run,
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

# Resolve the lib-<arch> dir name from the host arch / target_platform env var
_target_platform = os.environ.get("target_platform", "")


def _host_lib_dir() -> str:
    """Return the expected ``lib-<arch>`` directory name for the build host."""
    if "aarch64" in _arch or "arm64" in _arch:
        return "lib-aarch64"
    if "x86_64" in _arch:
        return "lib-x86_64"
    if _arch in ("i686", "i386"):
        return "lib-i386"
    # Fall back to target_platform hint
    if "aarch64" in _target_platform or "arm64" in _target_platform:
        return "lib-aarch64"
    if "x86_64" in _target_platform:
        return "lib-x86_64"
    return f"lib-{_arch}"


def _bare_zig_wrapper() -> str | None:
    """Return path to ``<triplet>-zig`` (bare) or fall back to ``<triplet>-zig-cc``."""
    # Prefer the bare zig binary (if installed as a triplet-prefixed wrapper)
    cc_wrapper = get_zig_wrapper("cc")
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    exe_suffix = ".exe" if sys.platform == "win32" else ""
    if sys.platform == "win32":
        wrapper_dir = prefix / "Library" / "bin"
    else:
        wrapper_dir = prefix / "bin"
    bare = wrapper_dir / f"{_triplet}-zig{exe_suffix}"
    if bare.exists():
        return str(bare)
    if cc_wrapper.exists():
        return str(cc_wrapper)
    return None


setup_zig_global_cache_dir()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_print_search_dirs(extra_args: list[str], *, timeout: int = 15) -> tuple[int, str, str]:
    """Run ``<wrapper> -print-search-dirs [extra_args]`` and return (rc, stdout, stderr)."""
    wrapper = _bare_zig_wrapper()
    if wrapper is None:
        return -1, "", "NOTFOUND"
    cmd = [wrapper] + extra_args + ["-print-search-dirs"]
    r = _run(cmd, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_print_search_dirs_default_host_arch() -> None:
    """``-print-search-dirs`` (no ``-target``) contains ``lib-common`` and host arch dir."""
    print("--- -print-search-dirs: default host arch ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs default host arch", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs default host arch", "Windows target only")
        return

    rc, stdout, stderr = _run_print_search_dirs([])
    if rc != 0:
        FAIL("-print-search-dirs default: exit 0", f"rc={rc} stderr={stderr[:500]}")
        return

    expected_arch_dir = _host_lib_dir()
    if "lib-common" not in stdout:
        FAIL("-print-search-dirs default: contains lib-common", f"output={stdout[:500]}")
    else:
        PASS("-print-search-dirs default: contains lib-common")

    if expected_arch_dir not in stdout:
        FAIL(
            f"-print-search-dirs default: contains {expected_arch_dir}",
            f"output={stdout[:500]}",
        )
    else:
        PASS(f"-print-search-dirs default: contains {expected_arch_dir}")


def test_print_search_dirs_target_aarch64_windows_gnu() -> None:
    """``-target aarch64-windows-gnu`` yields ``lib-aarch64``, not ``lib-x86_64``."""
    print("--- -print-search-dirs: -target aarch64-windows-gnu ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs aarch64", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs aarch64", "Windows target only")
        return

    rc, stdout, stderr = _run_print_search_dirs(["-target", "aarch64-windows-gnu"])
    if rc != 0:
        FAIL("-print-search-dirs aarch64: exit 0", f"rc={rc} stderr={stderr[:500]}")
        return

    if "lib-aarch64" not in stdout:
        FAIL("-print-search-dirs aarch64: contains lib-aarch64", f"output={stdout[:500]}")
    else:
        PASS("-print-search-dirs aarch64: contains lib-aarch64")

    if "lib-x86_64" in stdout:
        FAIL(
            "-print-search-dirs aarch64: does NOT contain lib-x86_64",
            f"lib-x86_64 found in output (hardcoded path not fixed): {stdout[:500]}",
        )
    else:
        PASS("-print-search-dirs aarch64: does NOT contain lib-x86_64")


def test_print_search_dirs_target_x86_64_windows_gnu() -> None:
    """``-target x86_64-windows-gnu`` yields ``lib-x86_64``, not ``lib-aarch64``."""
    print("--- -print-search-dirs: -target x86_64-windows-gnu ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs x86_64", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs x86_64", "Windows target only")
        return

    rc, stdout, stderr = _run_print_search_dirs(["-target", "x86_64-windows-gnu"])
    if rc != 0:
        FAIL("-print-search-dirs x86_64: exit 0", f"rc={rc} stderr={stderr[:500]}")
        return

    if "lib-x86_64" not in stdout:
        FAIL("-print-search-dirs x86_64: contains lib-x86_64", f"output={stdout[:500]}")
    else:
        PASS("-print-search-dirs x86_64: contains lib-x86_64")

    if "lib-aarch64" in stdout:
        FAIL(
            "-print-search-dirs x86_64: does NOT contain lib-aarch64",
            f"lib-aarch64 found unexpectedly in output: {stdout[:500]}",
        )
    else:
        PASS("-print-search-dirs x86_64: does NOT contain lib-aarch64")


def test_print_search_dirs_target_i386_windows_gnu() -> None:
    """``-target i386-windows-gnu`` yields ``lib-i386`` (skip if i386 not shipped)."""
    print("--- -print-search-dirs: -target i386-windows-gnu ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs i386", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs i386", "Windows target only")
        return

    # Check whether i386 library directory is present on disk
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if sys.platform == "win32":
        lib_i386 = prefix / "Library" / "lib" / "zig" / "lib-i386"
    else:
        lib_i386 = prefix / "lib" / "zig" / "lib-i386"
    if not lib_i386.exists():
        SKIP("-print-search-dirs i386", f"lib-i386 not shipped ({lib_i386})")
        return

    rc, stdout, stderr = _run_print_search_dirs(["-target", "i386-windows-gnu"])
    if rc != 0:
        FAIL("-print-search-dirs i386: exit 0", f"rc={rc} stderr={stderr[:500]}")
        return

    if "lib-i386" not in stdout:
        FAIL("-print-search-dirs i386: contains lib-i386", f"output={stdout[:500]}")
    else:
        PASS("-print-search-dirs i386: contains lib-i386")


def test_print_search_dirs_last_target_wins() -> None:
    """When two ``-target`` flags appear, the last one wins (zig convention)."""
    print("--- -print-search-dirs: last -target wins ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs last-target-wins", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs last-target-wins", "Windows target only")
        return

    rc, stdout, stderr = _run_print_search_dirs(
        ["-target", "x86_64-windows-gnu", "-target", "aarch64-windows-gnu"]
    )
    if rc != 0:
        FAIL("-print-search-dirs last-target-wins: exit 0", f"rc={rc} stderr={stderr[:500]}")
        return

    if "lib-aarch64" not in stdout:
        FAIL(
            "-print-search-dirs last-target-wins: contains lib-aarch64 (last wins)",
            f"output={stdout[:500]}",
        )
    else:
        PASS("-print-search-dirs last-target-wins: lib-aarch64 present (last -target wins)")


def test_print_search_dirs_malformed_target_falls_back_with_warn() -> None:
    """A malformed ``-target`` falls back to host arch and warns on stderr."""
    print("--- -print-search-dirs: malformed -target falls back ---")

    if _bare_zig_wrapper() is None:
        SKIP("-print-search-dirs malformed-target", "wrapper cc not found — needs build env")
        return

    if not ("win" in _triplet or "mingw" in _triplet):
        SKIP("-print-search-dirs malformed-target", "Windows target only")
        return

    rc, stdout, stderr = _run_print_search_dirs(["-target", "bogus-arch-xyz"])

    if rc != 0:
        # A non-zero exit is acceptable if the target is completely unrecognised;
        # we note it as WARN rather than FAIL (behaviour may vary by build).
        WARN(
            "-print-search-dirs malformed-target: non-zero exit",
            f"rc={rc} — zig rejected bogus-arch-xyz outright (acceptable fallback)",
        )
        return

    expected_arch_dir = _host_lib_dir()
    if expected_arch_dir not in stdout:
        FAIL(
            f"-print-search-dirs malformed-target: fall-back to host arch ({expected_arch_dir})",
            f"output={stdout[:500]}",
        )
    else:
        PASS(f"-print-search-dirs malformed-target: fell back to {expected_arch_dir}")

    combined = stderr.lower()
    if "bogus" in combined or "unknown" in combined or "warn" in combined:
        PASS("-print-search-dirs malformed-target: warning on stderr")
    else:
        WARN(
            "-print-search-dirs malformed-target: warning on stderr",
            f"expected warning mentioning 'bogus' or 'unknown'; stderr={stderr[:300]}",
        )


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== -print-search-dirs Arch Tests ===")
    print(f"  CONDA_ZIG_HOST   = {_host!r}")
    print(f"  triplet          = {_triplet!r}")
    print(f"  arch             = {_arch!r}")
    print(f"  target_platform  = {_target_platform!r}")
    print(f"  expected host dir= {_host_lib_dir()!r}")
    print()

    test_print_search_dirs_default_host_arch()
    test_print_search_dirs_target_aarch64_windows_gnu()
    test_print_search_dirs_target_x86_64_windows_gnu()
    test_print_search_dirs_target_i386_windows_gnu()
    test_print_search_dirs_last_target_wins()
    test_print_search_dirs_malformed_target_falls_back_with_warn()

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
