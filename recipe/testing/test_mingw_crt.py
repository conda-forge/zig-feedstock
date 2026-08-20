#!/usr/bin/env python3
"""Verify the mingw32 CRT bootstrap for ALL staged Windows targets.

recipe/building/_mingw.sh cache-warms x86_64-windows-gnu, aarch64-windows-gnu
and x86-windows-gnu, staging the real archives into lib-common/, libarm64/ and
lib32/ respectively.  A failed warm iteration only WARNs and skips its stage,
so an entire architecture can go missing from the package silently; this test
checks all three.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
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


def main() -> None:
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if not prefix.exists():
        sys.exit("FAIL: CONDA_PREFIX not set or missing")

    # mingw root differs between Windows-layout and Unix-layout conda envs
    if _build_is_win:
        mingw_dir = prefix / "Library" / "lib" / "zig" / "libc" / "mingw"
    else:
        mingw_dir = prefix / "lib" / "zig" / "libc" / "mingw"

    # Staging dir per warm target, matching _mingw.sh's cache-warm loop.
    staged = [
        ("x86_64-windows-gnu", mingw_dir / "lib-common"),
        ("aarch64-windows-gnu", mingw_dir / "libarm64"),
        ("x86-windows-gnu", mingw_dir / "lib32"),
    ]
    lib_common = staged[0][1]

    # 1. All 8 staged real archives exist with size > 1MB, for every target.
    #    Observed sizes are ~10.8MB (x86_64), ~11.0MB (aarch64), ~11.4MB (x86).
    expected_libs = [
        "libmingw32.lib", "libmingw32.a",
        "libucrt.lib", "libucrt.a",
        "libmingwex.lib", "libmingwex.a",
        "libwinpthread.lib", "libwinpthread.a",
    ]
    for target, lib_dir in staged:
        if not lib_dir.is_dir():
            sys.exit(
                f"FAIL: missing staging dir {lib_dir} for {target} "
                f"(cache-warm failed for this target -- it only WARNs, so the "
                f"package would ship with no CRT archives for this arch)"
            )
        for lib in expected_libs:
            p = lib_dir / lib
            if not p.is_file():
                sys.exit(f"FAIL: missing {p} ({target})")
            size = p.stat().st_size
            if size < 1_000_000:
                sys.exit(
                    f"FAIL: {p} is {size} bytes for {target} "
                    f"(expected >1MB real archive)"
                )

    # 2. libpthread.a preserved as small import lib (NOT overwritten by alias).
    #    Generated from mingw-defs into lib-common only -- the cache-warm loop
    #    does not stage it into libarm64/ or lib32/, so scope this to lib-common.
    pthread_a = lib_common / "libpthread.a"
    if not pthread_a.is_file():
        sys.exit(f"FAIL: missing import lib {pthread_a}")
    pthread_size = pthread_a.stat().st_size
    if pthread_size == 0:
        sys.exit(
            f"FAIL: {pthread_a} is 0 bytes (dlltool failed to generate a "
            f"real import lib -- see _mingw.sh WARNING output)"
        )
    if pthread_size > 5000:
        sys.exit(
            f"FAIL: libpthread.a is {pthread_size} bytes "
            f"(import lib should be <5KB, was it overwritten?)"
        )

    # 3. Key source members present in libmingw32.lib via `zig ar t`
    # Discover the mingw zig wrapper from PATH by trying known candidates
    candidates = [
        "x86_64-w64-mingw32-zig",
        "i686-w64-mingw32-zig",
        "aarch64-w64-mingw32-zig",
    ]
    zig_exe = None
    _triplet = None
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            zig_exe = found
            _triplet = candidate.removesuffix("-zig")
            break

    if zig_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig wrapper found on PATH")

    # Member check stays on lib-common: ucrt_* member names are verified there.
    # thread/mutex come from winpthreads and are present for aarch64 too, but
    # the ucrt_* members have not been confirmed across all three arches.
    libmingw32 = lib_common / "libmingw32.lib"
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

    print(
        "mingw CRT bootstrap OK: x86_64 (lib-common), "
        "aarch64 (libarm64), x86 (lib32)"
    )


if __name__ == "__main__":
    main()
