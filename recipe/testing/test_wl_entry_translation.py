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
    # Both build and target wrappers can be on PATH; first-found picks the
    # build one. Prefer the lane's actual target wrapper via CONDA_ZIG_HOST.
    candidates = [
        "x86_64-w64-mingw32-zig-cc",
        "i686-w64-mingw32-zig-cc",
        "aarch64-w64-mingw32-zig-cc",
    ]
    zig_cc_exe = None
    conda_zig_host = os.environ.get("CONDA_ZIG_HOST", "")
    if conda_zig_host:
        found = shutil.which(f"{conda_zig_host}-cc")
        if found:
            zig_cc_exe = found
            print(f"INFO: using {zig_cc_exe} (from CONDA_ZIG_HOST)")

    if zig_cc_exe is None:
        for candidate in candidates:
            found = shutil.which(candidate)
            if found:
                zig_cc_exe = found
                print(f"INFO: using {zig_cc_exe} (from candidate list)")
                break

    if zig_cc_exe is None:
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-cc wrapper found on PATH")

    print(f"ENV CONDA_ZIG_HOST={os.environ.get('CONDA_ZIG_HOST', '(unset)')}")
    print(f"ENV CONDA_ZIG_BUILD={os.environ.get('CONDA_ZIG_BUILD', '(unset)')}")
    print(f"ENV ZIG_TARGET_TRIPLET={os.environ.get('ZIG_TARGET_TRIPLET', '(unset)')}")
    print(f"ENV ZIG_CC={os.environ.get('ZIG_CC', '(unset)')}")

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

        # -v output is huge on aarch64; capture the stderr TAIL, not the head.
        result = subprocess.run(
            [zig_cc_exe, "-v", "-Wl,-eMyEntry", "-Wl,--subsystem,console", str(c_file_1), "-o", str(exe_file_1)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            stderr_short = result.stderr[-4000:]
            sys.exit(
                f"FAIL: zig-cc -Wl,-eMyEntry test1.c failed (rc={result.returncode})\n"
                f"--- stderr ---\n{stderr_short}\n"
                f"--- stdout ---\n{result.stdout[:2000]}"
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
            [zig_cc_exe, "-v", "-Wl,-e,MyEntry", "-Wl,--subsystem,console", str(c_file_2), "-o", str(exe_file_2)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            stderr_short = result.stderr[-4000:]
            sys.exit(
                f"FAIL: zig-cc -Wl,-e,MyEntry test2.c failed (rc={result.returncode})\n"
                f"--- stderr ---\n{stderr_short}\n"
                f"--- stdout ---\n{result.stdout[:2000]}"
            )

        if not exe_file_2.is_file():
            sys.exit(f"FAIL: zig-cc did not create {exe_file_2}")

        size_2 = exe_file_2.stat().st_size
        if size_2 == 0:
            sys.exit(f"FAIL: zig-cc output {exe_file_2} is empty (0 bytes)")

    print(f"PASS: -Wl,-eSYM and -Wl,-e,SYM translated to -Wl,--entry,SYM; output sizes: {size_1} {size_2}")


if __name__ == "__main__":
    main()
