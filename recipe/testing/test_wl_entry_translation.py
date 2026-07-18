#!/usr/bin/env python3
"""Verify <triplet>-zig-cc wrapper: -Wl,-eSYM to -Wl,/ENTRY:SYM translation on Windows."""

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


def main() -> None:
    # Discover the mingw zig-cc wrapper from PATH by trying known candidates
    candidates = [
        "x86_64-w64-mingw32-zig-cc",
        "i686-w64-mingw32-zig-cc",
        "aarch64-w64-mingw32-zig-cc",
    ]
    zig_cc_exe = None
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            zig_cc_exe = found
            break

    if zig_cc_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-cc wrapper found on PATH")

    # Minimal Windows C source with custom entry point
    c_source = """#include <windows.h>
void MyEntry(void) { ExitProcess(0); }
"""

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)

        # Test 1: -Wl,-eSYM (CONCAT form)
        c_file_1 = tmpdir_path / "test1.c"
        exe_file_1 = tmpdir_path / "test1_concat.exe"
        c_file_1.write_text(c_source)

        result = subprocess.run(
            [zig_cc_exe, "-Wl,-eMyEntry", "-Wl,--subsystem,console", str(c_file_1), "-o", str(exe_file_1)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            stderr_short = result.stderr[:500]
            sys.exit(
                f"FAIL: zig-cc -Wl,-eMyEntry test1.c failed "
                f"(rc={result.returncode}): {stderr_short}"
            )

        if not exe_file_1.is_file():
            sys.exit(f"FAIL: zig-cc did not create {exe_file_1}")

        size_1 = exe_file_1.stat().st_size
        if size_1 == 0:
            sys.exit(f"FAIL: zig-cc output {exe_file_1} is empty (0 bytes)")

        # Test 2: -Wl,-e,SYM (COMMA form)
        c_file_2 = tmpdir_path / "test2.c"
        exe_file_2 = tmpdir_path / "test2_comma.exe"
        c_file_2.write_text(c_source)

        result = subprocess.run(
            [zig_cc_exe, "-Wl,-e,MyEntry", "-Wl,--subsystem,console", str(c_file_2), "-o", str(exe_file_2)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            stderr_short = result.stderr[:500]
            sys.exit(
                f"FAIL: zig-cc -Wl,-e,MyEntry test2.c failed "
                f"(rc={result.returncode}): {stderr_short}"
            )

        if not exe_file_2.is_file():
            sys.exit(f"FAIL: zig-cc did not create {exe_file_2}")

        size_2 = exe_file_2.stat().st_size
        if size_2 == 0:
            sys.exit(f"FAIL: zig-cc output {exe_file_2} is empty (0 bytes)")

    print(f"PASS: -Wl,-eSYM and -Wl,-e,SYM translated to -Wl,--entry,SYM; output sizes: {size_1} {size_2}")


if __name__ == "__main__":
    main()
