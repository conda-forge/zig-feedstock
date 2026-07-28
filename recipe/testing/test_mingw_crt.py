#!/usr/bin/env python3
"""Verify x86_64-windows-gnu CRT bootstrap: real mingw32 archives in lib-common."""

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


if __name__ == "__main__":
    main()
