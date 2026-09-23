#!/usr/bin/env python3
"""Guard against the Lld.zig-remove-ucrt regression on the aarch64 MSVC link path."""

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
    conda_zig_build = os.environ.get("CONDA_ZIG_BUILD", "")
    build_zig_exe = shutil.which(conda_zig_build) if conda_zig_build else None
    if build_zig_exe is None:
        print(
            f"SKIP: aarch64 MSVC UCRT link probe "
            f"(CONDA_ZIG_BUILD={conda_zig_build or '(unset)'} not resolvable via shutil.which)"
        )
        return

    print(f"INFO: aarch64 MSVC probe using {build_zig_exe} -target aarch64-windows-msvc")

    c_source = """#include <windows.h>
void MyEntry(void) { ExitProcess(0); }
"""

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)
        c_file = tmpdir_path / "test_aarch64_msvc.c"
        exe_file = tmpdir_path / "test_aarch64_msvc.exe"
        c_file.write_text(c_source)

        # -v output is huge on aarch64; capture the stderr TAIL, not the head.
        result = subprocess.run(
            [
                build_zig_exe,
                "cc",
                "-target",
                "aarch64-windows-msvc",
                "-v",
                "-Wl,--entry,MyEntry",
                "-Wl,--subsystem,console",
                str(c_file),
                "-o",
                str(exe_file),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        if "unsupported linker arg" in result.stderr:
            stderr_tail_2000 = result.stderr[-2000:]
            sys.exit(
                "FAIL: probe itself is malformed - zig rejected a linker arg, so the "
                "link never ran; the ucrt check is inconclusive (this is a test bug, "
                f"NOT a ucrt regression) (rc={result.returncode})\n"
                f"--- stderr tail ---\n{stderr_tail_2000}"
            )

        if "ucrt.lib" not in result.stderr:
            stderr_tail = result.stderr[-4000:]
            sys.exit(
                "FAIL: aarch64 msvc link line was produced but contains no ucrt token; "
                "this is consistent with the Lld.zig-remove-ucrt regression "
                f"(rc={result.returncode})\n"
                f"--- stderr tail ---\n{stderr_tail}"
            )

        if "lld-link" not in result.stderr:
            print("REPORT: lld-link line was not observed in stderr; ucrt check may be vacuous")

        print(f"REPORT: -ENTRY:MyEntry present in stderr: {'-ENTRY:MyEntry' in result.stderr}")

        if result.returncode == 0 and exe_file.is_file() and exe_file.stat().st_size > 0:
            print(f"PASS: aarch64 MSVC link succeeded, output size: {exe_file.stat().st_size}")
        else:
            stderr_tail_2000 = result.stderr[-2000:]
            print(
                f"REPORT: aarch64 MSVC link did not complete (rc={result.returncode})\n"
                f"--- stderr tail ---\n{stderr_tail_2000}"
            )


if __name__ == "__main__":
    main()
