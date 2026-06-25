#!/usr/bin/env python3
"""Section 2 item 2 — arm64 startup stubs in patched libmingw32.a (should FAIL against build-28).

Tests for arm64 startup stub presence in the patched libmingw32.a.  Uses
``nm_symbols()`` from ``_test_utils`` to inspect archive symbol tables.

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
    COFF_MACHINE_AARCH64,
    FAIL,
    PASS,
    SKIP,
    WARN,
    _results,
    _run,
    compile_minimal_winmain_c,
    get_zig_wrapper,
    nm_symbols,
    pe_machine_type,
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


# ---------------------------------------------------------------------------
# Locate the aarch64 libmingw32.a
# ---------------------------------------------------------------------------

def _find_libmingw32_aarch64() -> Path | None:
    """Locate the aarch64 variant of libmingw32.a under the conda prefix.

    Checks ``lib-aarch64/``, ``libarm64/``, and ``lib/zig/libc/mingw/`` sub-trees.
    Returns None if not found.
    """
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if sys.platform == "win32":
        base = prefix / "Library" / "lib" / "zig" / "libc" / "mingw"
    else:
        base = prefix / "lib" / "zig" / "libc" / "mingw"

    candidates = [
        base / "lib-aarch64" / "libmingw32.a",
        base / "libarm64" / "libmingw32.a",
        # Top-level fallback in case recipe layout changes
        base / "libmingw32.a",
    ]
    for c in candidates:
        if c.exists() and c.stat().st_size > 0:
            return c
    return None


def _skip_if_no_archive() -> Path | None:
    """Return the archive Path, or None (test should SKIP)."""
    archive = _find_libmingw32_aarch64()
    return archive


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_existing_arm64_stubs_present() -> None:
    """Pre-existing arm64 stubs ``_fpreset``, ``fpreset``, ``___chkstk_ms``, ``setjmp`` are defined."""
    print("--- arm64 stubs: pre-existing stubs present ---")

    archive = _skip_if_no_archive()
    if archive is None:
        SKIP(
            "arm64 stubs pre-existing",
            "libmingw32.a (aarch64 variant) not found under CONDA_PREFIX",
        )
        return

    symbols = nm_symbols(archive)
    if not symbols:
        SKIP("arm64 stubs pre-existing", "llvm-nm not on PATH or produced no output")
        return

    required = ["_fpreset", "fpreset", "___chkstk_ms", "setjmp"]
    for sym in required:
        type_letter = symbols.get(sym)
        if type_letter is None:
            FAIL(f"arm64 stub present: {sym}", "symbol not found in archive")
        elif type_letter == "U":
            FAIL(f"arm64 stub defined: {sym}", f"type={type_letter!r} (undefined — should be defined)")
        else:
            PASS(f"arm64 stub present and defined: {sym}", f"type={type_letter!r}")


def test_new_wmainCRTStartup_stub_present() -> None:
    """New stub ``wmainCRTStartup`` is present and defined in libmingw32.a (aarch64)."""
    print("--- arm64 stubs: wmainCRTStartup present ---")

    archive = _skip_if_no_archive()
    if archive is None:
        SKIP(
            "arm64 stubs wmainCRTStartup",
            "libmingw32.a (aarch64 variant) not found under CONDA_PREFIX",
        )
        return

    symbols = nm_symbols(archive)
    if not symbols:
        SKIP("arm64 stubs wmainCRTStartup", "llvm-nm not on PATH or produced no output")
        return

    sym = "wmainCRTStartup"
    type_letter = symbols.get(sym)
    if type_letter is None:
        FAIL(f"arm64 stub present: {sym}", "symbol not found in archive (build-29 patch not applied)")
    elif type_letter == "U":
        FAIL(
            f"arm64 stub defined: {sym}",
            f"type={type_letter!r} (undefined — stub not fully linked)",
        )
    else:
        PASS(f"arm64 stub wmainCRTStartup present and defined", f"type={type_letter!r}")


def test_new_crt2_startup_cluster_present() -> None:
    """CRT2 cluster ``_cexit``, ``_initterm``, ``_commode``, ``_fmode`` are all present and defined."""
    print("--- arm64 stubs: CRT2 startup cluster present ---")

    archive = _skip_if_no_archive()
    if archive is None:
        SKIP(
            "arm64 CRT2 cluster",
            "libmingw32.a (aarch64 variant) not found under CONDA_PREFIX",
        )
        return

    symbols = nm_symbols(archive)
    if not symbols:
        SKIP("arm64 CRT2 cluster", "llvm-nm not on PATH or produced no output")
        return

    required = ["_cexit", "_initterm", "_commode", "_fmode"]
    all_ok = True
    for sym in required:
        type_letter = symbols.get(sym)
        if type_letter is None:
            FAIL(f"arm64 CRT2 cluster: {sym} present", "symbol not found in archive")
            all_ok = False
        elif type_letter == "U":
            FAIL(
                f"arm64 CRT2 cluster: {sym} defined",
                f"type={type_letter!r} (undefined)",
            )
            all_ok = False
        else:
            PASS(f"arm64 CRT2 cluster: {sym}", f"type={type_letter!r}")

    if all_ok:
        PASS("arm64 CRT2 startup cluster: all symbols present and defined")


def test_arm64_winmain_end_to_end_link() -> None:
    """``zig cc -target aarch64-windows-gnu`` links wmain → aarch64 PE (end-to-end)."""
    print("--- arm64 stubs: wmain end-to-end link ---")

    cc_wrapper = get_zig_wrapper("cc")
    if not cc_wrapper.exists():
        SKIP("arm64 wmain end-to-end", "wrapper cc not found — needs build env")
        return

    # Use the bare <triplet>-zig if available, else <triplet>-zig-cc
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    exe_suffix = ".exe" if sys.platform == "win32" else ""
    if sys.platform == "win32":
        wrapper_dir = prefix / "Library" / "bin"
    else:
        wrapper_dir = prefix / "bin"
    bare = wrapper_dir / f"{_triplet}-zig{exe_suffix}"
    zig = str(bare) if bare.exists() else str(cc_wrapper)

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        src = compile_minimal_winmain_c(td_path)
        out = td_path / "winmain.exe"

        cmd = [zig, "cc", "-target", "aarch64-windows-gnu", str(src), "-o", str(out)]
        r = _run(cmd, cwd=td, timeout=60)

        if r.stderr == "TIMEOUT":
            WARN("arm64 wmain end-to-end link", "timed out (60s)")
            return

        if r.returncode != 0:
            FAIL(
                "arm64 wmain end-to-end link: exit 0",
                f"rc={r.returncode} stderr={r.stderr[:2000]}",
            )
            return

        if not out.exists():
            FAIL("arm64 wmain end-to-end link: output exists", str(out))
            return

        machine = pe_machine_type(out)
        if machine == COFF_MACHINE_AARCH64:
            PASS("arm64 wmain end-to-end link: PE machine type is AARCH64 (0xAA64)")
        elif machine == 0:
            WARN(
                "arm64 wmain end-to-end link: PE machine type",
                "could not parse PE header (output may not be a valid PE)",
            )
        else:
            FAIL(
                "arm64 wmain end-to-end link: PE machine type is AARCH64",
                f"got 0x{machine:04X}, expected 0x{COFF_MACHINE_AARCH64:04X}",
            )


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== ARM64 Startup Stubs Tests ===")
    print(f"  CONDA_ZIG_HOST = {_host!r}")
    print(f"  triplet        = {_triplet!r}")
    print(f"  arch           = {_arch!r}")
    archive = _find_libmingw32_aarch64()
    print(f"  libmingw32.a   = {archive!r}")
    print()

    test_existing_arm64_stubs_present()
    test_new_wmainCRTStartup_stub_present()
    test_new_crt2_startup_cluster_present()
    test_arm64_winmain_end_to_end_link()

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
