"""Probe: an aarch64-windows-msvc custom-entry link must pull in ucrt.lib.

Guards patches/non_unix/Lld.zig-remove-ucrt.patch, whose aarch64 branch keeps
ucrt.lib because libvcruntime's abort/calloc/free are otherwise unresolved.
Runs on win-64 native, using the build-arch zig to cross-probe aarch64.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET = "aarch64-windows-msvc"
ENTRY = "MyEntry"
TAIL = 4000


def main():
    build_zig = os.environ.get("CONDA_ZIG_BUILD")
    if not build_zig:
        print("SKIP: CONDA_ZIG_BUILD unset")
        return 0
    zig = shutil.which(build_zig)
    if not zig:
        print("SKIP: %s not on PATH" % build_zig)
        return 0

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "entry.c"
        src.write_text("int %s(void) { return 0; }\n" % ENTRY)
        out = Path(td) / "entry.exe"
        # -Wl,--entry,SYM not -Wl,-eSYM: raw zig rejects the concat short form
        # with "unsupported linker arg" before the linker runs.
        cmd = [
            zig, "cc", "-target", TARGET, "-v",
            "-Wl,--entry,%s" % ENTRY, "-Wl,--subsystem,console",
            str(src), "-o", str(out),
        ]
        print("CMD: %s" % " ".join(cmd))
        proc = subprocess.run(cmd, capture_output=True, text=True)

    combined = (proc.stdout or "") + (proc.stderr or "")
    tail = combined[-TAIL:]
    print("--- stderr tail (last %d chars) ---" % TAIL)
    print(tail)
    print("--- end tail ---")

    # A rejected arg never reaches the linker, so ucrt is inconclusive, not refuted.
    if "unsupported linker arg" in combined:
        print("FAIL: probe malformed - zig rejected a linker arg before linking.")
        print("      ucrt.lib presence is INCONCLUSIVE, not refuted.")
        return 1

    if "lld-link" not in combined:
        print("REPORT: no lld-link line observed - probe may be vacuous")

    # Report-only: a runner without a complete ARM64 CRT must not redden the lane.
    print("REPORT: exit=%d (link success is report-only)" % proc.returncode)
    entry_form = "-ENTRY:%s" % ENTRY
    print("REPORT: %s %s" % (entry_form, "present" if entry_form in combined else "absent"))
    print("REPORT: ucrt.lib in tail slice: %s" % ("ucrt.lib" in tail.lower()))

    if "ucrt.lib" not in combined.lower():
        print("FAIL: a link line was produced but contains no ucrt token;")
        print("      consistent with the aarch64 branch of")
        print("      Lld.zig-remove-ucrt.patch not firing for %s." % TARGET)
        return 1
    print("PASS: ucrt.lib present in %s link" % TARGET)
    return 0


if __name__ == "__main__":
    sys.exit(main())
