#!/usr/bin/env python3
"""Verify <triplet>-zig-windres wrapper: -o to -fo and -i to positional input translations."""

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


from _test_utils import _build_is_win, resolve_test_prefix


def _find_wrapper(triplet: str, wrapper_dir: Path) -> str | None:
    """Locate the <triplet>-zig-windres wrapper in the resolved wrapper dir --
    same resolution test_foreign_import_lib.py uses."""
    suffix = ".exe" if _build_is_win else ""
    candidate = wrapper_dir / f"{triplet}-zig-windres{suffix}"
    return str(candidate) if candidate.is_file() else None


def main() -> None:
    # CONDA_ZIG_HOST is preferred: both build and target wrappers are on PATH,
    # and first-found in the candidate list below silently picks the build one.
    host = os.environ.get("CONDA_ZIG_HOST", "")
    triplet = host.removesuffix("-zig") if host.endswith("-zig") else host

    windres_exe = None
    selection = None
    if triplet:
        prefix = resolve_test_prefix("Library/bin" if _build_is_win else "bin")
        wrapper_dir = prefix / "Library" / "bin" if _build_is_win else prefix / "bin"
        windres_exe = _find_wrapper(triplet, wrapper_dir)
        if windres_exe:
            selection = "from CONDA_ZIG_HOST"

    if windres_exe is None:
        # Discover the mingw windres wrapper from PATH by trying known candidates
        candidates = [
            "x86_64-w64-mingw32-zig-windres",
            "i686-w64-mingw32-zig-windres",
            "aarch64-w64-mingw32-zig-windres",
        ]
        for candidate in candidates:
            found = shutil.which(candidate)
            if found:
                windres_exe = found
                selection = "from candidate list"
                break

    if windres_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-windres wrapper found on PATH")

    print(f"INFO: using {windres_exe} ({selection})")

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

        # Test 3: -i <input> -o <output>, fully GNU-shaped, both flags spaced
        rc_file_3 = tmpdir_path / "test3.rc"
        res_file_3 = tmpdir_path / "test3.res"
        rc_file_3.write_text(rc_source)

        result = subprocess.run(
            [windres_exe, "-i", str(rc_file_3), "-o", str(res_file_3)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            sys.exit(
                f"FAIL: windres -i test3.rc -o test3.res failed "
                f"(rc={result.returncode}): {result.stderr}"
            )

        if not res_file_3.is_file():
            sys.exit(f"FAIL: windres did not create {res_file_3}")

        size_3 = res_file_3.stat().st_size
        if size_3 == 0:
            sys.exit(f"FAIL: windres output {res_file_3} is empty (0 bytes)")

        # Test 4: -i<input> -o<output>, both flags concatenated
        rc_file_4 = tmpdir_path / "test4.rc"
        res_file_4 = tmpdir_path / "test4.res"
        rc_file_4.write_text(rc_source)

        result = subprocess.run(
            [windres_exe, f"-i{rc_file_4}", f"-o{res_file_4}"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            sys.exit(
                f"FAIL: windres -i<path> -o<path> test4.rc failed "
                f"(rc={result.returncode}): {result.stderr}"
            )

        if not res_file_4.is_file():
            sys.exit(f"FAIL: windres did not create {res_file_4}")

        size_4 = res_file_4.stat().st_size
        if size_4 == 0:
            sys.exit(f"FAIL: windres output {res_file_4} is empty (0 bytes)")

    print(
        f"PASS: windres -o translated to -fo, -i translated to positional, "
        f"output sizes: {size_1} {size_2} {size_3} {size_4}"
    )


if __name__ == "__main__":
    main()
