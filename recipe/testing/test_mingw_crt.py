#!/usr/bin/env python3
"""Verify x86_64-windows-gnu CRT bootstrap: real mingw32 archives in lib-common."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Build-side platform: rattler-build sets CONDA_BUILD_SYSROOT on macOS/Linux;
# on native Windows runners the OS reports itself directly.
_build_is_win = sys.platform == "win32" or os.environ.get("MSYSTEM") is not None

# Link probe: setjmp/longjmp reaches the __setjmp3 path, the double multiply
# reaches the _fpreset-adjacent path. Both are link-time-only concerns here.
_LINK_PROBE_C = """\
#include <setjmp.h>

static jmp_buf _probe_buf;

static double _probe_fp(double x) {
    return x * 2.5;
}

int main(void) {
    volatile double d = _probe_fp(3.0);
    if (setjmp(_probe_buf) == 0) {
        longjmp(_probe_buf, 1);
    }
    return (int)d;
}
"""


def _find_zig_exe() -> tuple[str | None, str | None]:
    """Discover the build machine's <arch>-w64-mingw32-zig binary on PATH.

    This IS the real zig compiler (renamed to its build-triplet alias), so it
    accepts `-target` for any output arch -- reused by both the archive member
    check and the cross-target link probes.
    """
    candidates = [
        "x86_64-w64-mingw32-zig",
        "i686-w64-mingw32-zig",
        "aarch64-w64-mingw32-zig",
    ]
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            return found, candidate.removesuffix("-zig")
    return None, None


def test_cross_target_link_probes(zig_exe: str) -> list[str]:
    """Compile+link a real binary against each staged CRT quartet.

    Link-only: arm64/32-bit outputs cannot run on a win-64 runner.

    The three targets mirror the cache-warm loop in recipe/building/_mingw.sh,
    where a failure on any one of them is a build FATAL -- so by the time this
    runs, all three CRTs are staged and correctly sized. Staged is not the same
    as linkable, which is the whole point of this probe: the warm program links
    snprintf+pthread_self and never touches setjmp.

    Every target is attempted even after a failure. WHICH SUBSET fails is the
    diagnostic: a single failing arch points at that arch's source-array
    membership, whereas all three failing uniformly points at this harness
    (zig discovery or triple spelling) instead.

    Returns a list of failure descriptions; empty means all probes linked.
    """
    print("--- Cross-target link probes ---")
    failures: list[str] = []
    targets = ["x86_64-windows-gnu", "aarch64-windows-gnu", "x86-windows-gnu"]
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "probe.c"
        src.write_text(_LINK_PROBE_C)
        for target in targets:
            out = Path(td) / f"probe_{target}.exe"
            try:
                result = subprocess.run(
                    [zig_exe, "cc", "-target", target, "-o", str(out), str(src)],
                    capture_output=True, text=True, timeout=900, check=False,
                )
            except subprocess.TimeoutExpired:
                print(f"  FAIL: link probe ({target}): TIMEOUT (900s)")
                failures.append(f"{target}: TIMEOUT")
                continue
            if result.returncode == 0 and out.is_file():
                print(f"  PASS: link probe ({target})")
            else:
                print(f"  FAIL: link probe ({target}): rc={result.returncode}")
                print(f"    stderr: {result.stderr[:400]!r}")
                failures.append(f"{target}: rc={result.returncode}")
    return failures


def main() -> None:
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if not prefix.exists():
        sys.exit("FAIL: CONDA_PREFIX not set or missing")

    # lib-common path differs between Windows-layout and Unix-layout conda envs
    if _build_is_win:
        lib_dir = prefix / "Library" / "lib" / "zig" / "libc" / "mingw" / "lib-common"
    else:
        lib_dir = prefix / "lib" / "zig" / "libc" / "mingw" / "lib-common"

    # 1. All 8 staged real archives exist with size > 1MB
    expected_libs = [
        "libmingw32.lib", "libmingw32.a",
        "libucrt.lib", "libucrt.a",
        "libmingwex.lib", "libmingwex.a",
        "libwinpthread.lib", "libwinpthread.a",
    ]
    for lib in expected_libs:
        p = lib_dir / lib
        if not p.is_file():
            sys.exit(f"FAIL: missing {p}")
        size = p.stat().st_size
        if size < 1_000_000:
            sys.exit(f"FAIL: {p} is {size} bytes (expected >1MB real archive)")

    # 2. libpthread.a preserved as small import lib (NOT overwritten by alias)
    pthread_a = lib_dir / "libpthread.a"
    if not pthread_a.is_file():
        sys.exit(f"FAIL: missing import lib {pthread_a}")
    pthread_size = pthread_a.stat().st_size
    if pthread_size > 5000:
        sys.exit(
            f"FAIL: libpthread.a is {pthread_size} bytes "
            f"(import lib should be <5KB, was it overwritten?)"
        )

    # 3. Key source members present in libmingw32.lib via `zig ar t`
    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig wrapper found on PATH")

    libmingw32 = lib_dir / "libmingw32.lib"
    result = subprocess.run(
        [str(zig_exe), "ar", "t", str(libmingw32)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        sys.exit(f"FAIL: zig ar t failed (rc={result.returncode}): {result.stderr}")

    members = result.stdout
    member_lines = members.splitlines()
    # Both .o (Unix archive convention) and .obj (Windows COFF) are possible
    for member in ("ucrt_snprintf", "ucrt_vsnprintf", "thread", "mutex"):
        found = any(
            f"{member}.o" in line or f"{member}.obj" in line
            for line in member_lines
        )
        if not found:
            print(f"FAIL: libmingw32.lib missing source member {member}.o/.obj")
            print("--- full ar t output ---")
            print(members)
            sys.exit(1)

    print("x86_64-windows-gnu CRT bootstrap: OK")

    # 4. Cross-target link probes -- staged+sized is not the same as linkable.
    probe_failures = test_cross_target_link_probes(zig_exe)
    if probe_failures:
        sys.exit(
            "FAIL: cross-target link probes failed: " + "; ".join(probe_failures)
        )

    print("mingw CRT cross-target link probes: OK")


if __name__ == "__main__":
    main()
