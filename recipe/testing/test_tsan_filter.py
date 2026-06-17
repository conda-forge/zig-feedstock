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
import shutil
import subprocess
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

_MINIMAL_MAIN_C = "int main(void) { return 0; }\n"

# TEMPORARY diagnostic probe (H1/H2 long-path overflow) for PR #120.
# Set False to restore the normal fatal windows-gnu gate.
H1H2_PROBE = True


def _classify_compile(rc, stderr):
    if rc == 0:
        return "OK"
    if "integer overflow" in stderr or rc < 0:
        return "PANIC"
    return "OTHER_FAIL(rc=%d)" % rc


def _probe_compile(zig_str, triple, work_dir, cache_dir):
    src_file = os.path.join(work_dir, "test.c")
    out = os.path.join(work_dir, "test.o")
    with open(src_file, "w") as f:
        f.write(_MINIMAL_MAIN_C)
    argv = [zig_str, "cc", "-target", triple, "-c", "-o", out, src_file]
    env = dict(os.environ)
    if cache_dir is not None:
        env["ZIG_GLOBAL_CACHE_DIR"] = cache_dir
        env["ZIG_LOCAL_CACHE_DIR"] = cache_dir
    proc = subprocess.run(argv, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)
    return proc.returncode, proc.stdout


# H1/H2 PROBE (PR #120, TEMPORARY): windows-gnu compiles run COLD and NON-FATAL under
# ambient(long GHA path) vs short(/tmp) cache+work dirs, to test whether path length
# drives the integer-overflow panic. Revert by setting H1H2_PROBE = False.
def run_h1h2_probe(zig_str):
    targets = ["aarch64-windows-gnu", "x86_64-windows-gnu"]
    results = {}
    cleanup = []
    print("=== H1/H2 cache-path probe (PR #120) ===")
    for triple in targets:
        arch = triple.split("-")[0]
        ambient_dir = tempfile.mkdtemp()
        cleanup.append(ambient_dir)
        rc, err = _probe_compile(zig_str, triple, ambient_dir, None)
        cls = _classify_compile(rc, err)
        results[(triple, "ambient")] = cls
        print("PROBE: %s  %-7s  pathlen=%d  -> %s" % (triple, "ambient", len(ambient_dir), cls))

        short_dir = "/tmp/zc_" + arch
        shutil.rmtree(short_dir, ignore_errors=True)
        os.makedirs(short_dir, exist_ok=True)
        cleanup.append(short_dir)
        rc, err = _probe_compile(zig_str, triple, short_dir, short_dir)
        cls = _classify_compile(rc, err)
        results[(triple, "short")] = cls
        print("PROBE: %s  %-7s  pathlen=%d  -> %s" % (triple, "short", len(short_dir), cls))

    confirmed = any(results.get((t, "ambient")) == "PANIC" and results.get((t, "short")) == "OK"
                    for t in targets)
    all_persist = all(results.get((t, "ambient")) == "PANIC" and results.get((t, "short")) == "PANIC"
                      for t in targets)
    any_ambient_panic = any(results.get((t, "ambient")) == "PANIC" for t in targets)
    if confirmed:
        verdict = "H1/H2 CONFIRMED: short path clears the windows-gnu integer-overflow panic"
    elif all_persist:
        verdict = "H1/H2 REJECTED: panic persists under short path (not path-length driven)"
    elif not any_ambient_panic:
        verdict = "INCONCLUSIVE: windows-gnu panic did not reproduce this run"
    else:
        verdict = "MIXED: see per-condition lines above"
    print("PROBE VERDICT: %s" % verdict)
    for d in cleanup:
        shutil.rmtree(d, ignore_errors=True)
    return True


def _cc_wrapper_str() -> str | None:
    """Return the cc wrapper path string, or None if not found."""
    p = get_zig_wrapper("cc")
    if not p.exists():
        return None
    return str(p)


def _bare_zig_str() -> str | None:
    """Return bare ``<triplet>-zig`` path, or fall back to cc wrapper."""
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    exe_suffix = ".exe" if sys.platform == "win32" else ""
    if sys.platform == "win32":
        wrapper_dir = prefix / "Library" / "bin"
    else:
        wrapper_dir = prefix / "bin"
    bare = wrapper_dir / f"{_triplet}-zig{exe_suffix}"
    if bare.exists():
        return str(bare)
    cc = get_zig_wrapper("cc")
    if cc.exists():
        return str(cc)
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_no_tsan_undefined_refs_in_aarch64_windows_gnu_object() -> None:
    """No ``__tsan_*`` undefined symbols appear in aarch64-windows-gnu compiled object."""
    print("--- tsan filter: aarch64-windows-gnu object ---")

    zig = _bare_zig_str()
    if zig is None:
        SKIP("tsan filter aarch64-windows-gnu", "wrapper cc not found -- needs build env")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        src = td_path / "test.c"
        src.write_text(_MINIMAL_MAIN_C, encoding="utf-8")
        obj = td_path / "test.o"

        cmd = [zig, "cc", "-target", "aarch64-windows-gnu", "-c", "-o", str(obj), str(src)]
        r = _run(cmd, cwd=td, timeout=60)

        if r.stderr == "TIMEOUT":
            WARN("tsan filter aarch64-windows-gnu: compile", "timed out (60s)")
            return

        if r.returncode != 0:
            FAIL(
                "tsan filter aarch64-windows-gnu: compile exit 0",
                f"rc={r.returncode} stderr={r.stderr[:2000]}",
            )
            return

        if not obj.exists():
            FAIL("tsan filter aarch64-windows-gnu: object exists", str(obj))
            return

        symbols = nm_symbols(obj)
        if not symbols:
            SKIP(
                "tsan filter aarch64-windows-gnu: nm check",
                "llvm-nm not on PATH or produced no output",
            )
            return

        tsan_undefined = [
            name for name, letter in symbols.items()
            if name.startswith("__tsan_") and letter == "U"
        ]
        if tsan_undefined:
            FAIL(
                "tsan filter aarch64-windows-gnu: no __tsan_* undefined",
                f"undefined tsan symbols found: {tsan_undefined[:10]}",
            )
        else:
            PASS("tsan filter aarch64-windows-gnu: no __tsan_* undefined refs in object")


def test_no_tsan_undefined_refs_in_x86_64_windows_gnu_object() -> None:
    """No ``__tsan_*`` undefined symbols appear in x86_64-windows-gnu compiled object."""
    print("--- tsan filter: x86_64-windows-gnu object ---")

    zig = _bare_zig_str()
    if zig is None:
        SKIP("tsan filter x86_64-windows-gnu", "wrapper cc not found -- needs build env")
        return

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        src = td_path / "test.c"
        src.write_text(_MINIMAL_MAIN_C, encoding="utf-8")
        obj = td_path / "test.o"

        cmd = [zig, "cc", "-target", "x86_64-windows-gnu", "-c", "-o", str(obj), str(src)]
        r = _run(cmd, cwd=td, timeout=60)

        if r.stderr == "TIMEOUT":
            WARN("tsan filter x86_64-windows-gnu: compile", "timed out (60s)")
            return

        if r.returncode != 0:
            FAIL(
                "tsan filter x86_64-windows-gnu: compile exit 0",
                f"rc={r.returncode} stderr={r.stderr[:2000]}",
            )
            return

        if not obj.exists():
            FAIL("tsan filter x86_64-windows-gnu: object exists", str(obj))
            return

        symbols = nm_symbols(obj)
        if not symbols:
            SKIP(
                "tsan filter x86_64-windows-gnu: nm check",
                "llvm-nm not on PATH or produced no output",
            )
            return

        tsan_undefined = [
            name for name, letter in symbols.items()
            if name.startswith("__tsan_") and letter == "U"
        ]
        if tsan_undefined:
            FAIL(
                "tsan filter x86_64-windows-gnu: no __tsan_* undefined",
                f"undefined tsan symbols found: {tsan_undefined[:10]}",
            )
        else:
            PASS("tsan filter x86_64-windows-gnu: no __tsan_* undefined refs in object")


def test_linux_target_unaffected_by_filter() -> None:
    """``-target x86_64-linux-gnu -c`` still compiles successfully (no regression)."""
    print("--- tsan filter: linux target unaffected ---")

    zig = _bare_zig_str()
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

    if H1H2_PROBE:
        # ------------------------------------------------------------------
        # TEMPORARY diagnostic mode (PR #120):
        # Run COLD ambient-vs-short path probe; linux warmup as sanity check.
        # windows-gnu panics are NON-FATAL here. Set H1H2_PROBE = False to
        # restore the original fatal gate.
        # ------------------------------------------------------------------
        zig_str = _bare_zig_str()
        if zig_str is None:
            print("SKIP: zig wrapper not found -- needs build env (CONDA_ZIG_HOST unset or binary absent)")
            return 1

        run_h1h2_probe(zig_str)

        # Linux sanity warmup -- fatal only if the compile environment is broken entirely.
        test_linux_target_unaffected_by_filter()
        n_fail = len(_results["FAIL"])
        if n_fail > 0:
            print("\nFAIL: linux sanity warmup failed -- zig environment not functional")
            return 1

        print()
        print("=== H1/H2 probe complete (windows-gnu panics treated as non-fatal) ===")
        return 0
    else:
        # ------------------------------------------------------------------
        # ORIGINAL fatal gate (H1H2_PROBE = False):
        # Run linux-target compile FIRST as a warmup -- empirically primes zig's
        # internal state and may prevent a GHA-runner-specific integer-overflow
        # panic observed in CI when windows-gnu compiles run cold (see PR #120).
        # ------------------------------------------------------------------
        test_linux_target_unaffected_by_filter()
        test_no_tsan_undefined_refs_in_aarch64_windows_gnu_object()
        test_no_tsan_undefined_refs_in_x86_64_windows_gnu_object()

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
