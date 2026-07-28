#!/usr/bin/env python3
"""Verify <triplet>-zig-windres wrapper: -o flag translation works correctly."""

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
    # Discover the mingw windres wrapper from PATH by trying known candidates
    candidates = [
        "x86_64-w64-mingw32-zig-windres",
        "i686-w64-mingw32-zig-windres",
        "aarch64-w64-mingw32-zig-windres",
    ]
    windres_exe = None
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            windres_exe = found
            break

    if windres_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-windres wrapper found on PATH")

    # RC source with minimal but valid VERSIONINFO structure
    rc_source = """1 VERSIONINFO
FILEVERSION 1,0,0,0
PRODUCTVERSION 1,0,0,0
{
BLOCK "StringFileInfo"
{
  BLOCK "040904E4"
  {
    VALUE "ProductName", "test"
  }
}
BLOCK "VarFileInfo"
{
  VALUE "Translation", 0x0409, 0x04E4
}
}
"""

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)

        # Test 1: -o with space (windres-style flag)
        rc_file_1 = tmpdir_path / "test1.rc"
        res_file_1 = tmpdir_path / "test1.res"
        rc_file_1.write_text(rc_source)

        result = subprocess.run(
            [windres_exe, "-o", str(res_file_1), str(rc_file_1)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            sys.exit(
                f"FAIL: windres -o test1.rc -o test1.res failed "
                f"(rc={result.returncode}): {result.stderr}"
            )

        if not res_file_1.is_file():
            sys.exit(f"FAIL: windres did not create {res_file_1}")

        size_1 = res_file_1.stat().st_size
        if size_1 == 0:
            sys.exit(f"FAIL: windres output {res_file_1} is empty (0 bytes)")

        # Test 2: -oX (concatenated flag)
        rc_file_2 = tmpdir_path / "test2.rc"
        res_file_2 = tmpdir_path / "test2.res"
        rc_file_2.write_text(rc_source)

        result = subprocess.run(
            [windres_exe, f"-o{res_file_2}", str(rc_file_2)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            sys.exit(
                f"FAIL: windres -o<path> test2.rc failed "
                f"(rc={result.returncode}): {result.stderr}"
            )

        if not res_file_2.is_file():
            sys.exit(f"FAIL: windres did not create {res_file_2}")

        size_2 = res_file_2.stat().st_size
        if size_2 == 0:
            sys.exit(f"FAIL: windres output {res_file_2} is empty (0 bytes)")

    print(f"PASS: windres -o translated to -fo, output sizes: {size_1} {size_2}")


if __name__ == "__main__":
    main()
