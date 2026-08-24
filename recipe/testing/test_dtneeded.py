#!/usr/bin/env python3
"""Regression test: -Wl,--no-as-needed -lm must put libm in DT_NEEDED.

If the assertion fails, this test ALSO re-runs the compile with -v and
-Wl,--verbose to capture zig cc's clang+linker invocations, so the CI log
shows exactly what zig is passing to LLD (or filtering out). This pinpoints
whether the issue is in zig's flag forwarding, in the conda-env LDFLAGS
interaction, or elsewhere.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile


def _build(triplet: str, src: str, binary: str, zig_target: str,
           *, verbose: bool = False, extra: list[str] | None = None) -> subprocess.CompletedProcess:
    cmd = [f"{triplet}-zig", "cc"]
    if verbose:
        cmd += ["-v", "-Wl,--verbose"]
    if extra:
        cmd += extra
    cmd += ["-target", zig_target, "-Wl,--no-as-needed", "-lm", src, "-o", binary]
    return subprocess.run(cmd, capture_output=True, text=True)


def main(triplet: str, zig_target: str = "") -> int:
    if not zig_target:
        zig_target = triplet.replace("-conda", "") + ".2.17"
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "foo.c")
        binary = os.path.join(tmpdir, "foo")
        with open(src, "w") as f:
            f.write("int main(void) { return 0; }\n")

        # Quiet first attempt.
        result = _build(triplet, src, binary, zig_target)
        if result.returncode != 0:
            print("FAIL: zig cc failed to compile/link", file=sys.stderr)
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return 1

        readelf = subprocess.run(
            ["readelf", "-d", binary],
            check=True, capture_output=True, text=True,
        )

        if re.search(r"NEEDED\b.*libm", readelf.stdout):
            print("PASS -Wl,--no-as-needed -lm puts libm in DT_NEEDED")
            return 0

        # Failure path: dump verbose diagnostics so the CI log shows
        # zig's actual LLD invocation and any env-level interference.
        print(
            "FAIL: libm not in DT_NEEDED after -Wl,--no-as-needed -lm",
            file=sys.stderr,
        )
        print("--- readelf -d (failing binary) ---", file=sys.stderr)
        print(readelf.stdout, file=sys.stderr)

        print("--- relevant env vars ---", file=sys.stderr)
        for key in ("LDFLAGS", "LDFLAGS_LD", "CFLAGS", "CPPFLAGS",
                    "CONDA_BUILD_SYSROOT", "CONDA_TOOLCHAIN_HOST",
                    "CONDA_TOOLCHAIN_BUILD"):
            val = os.environ.get(key)
            if val is not None:
                print(f"{key}={val}", file=sys.stderr)

        # Diagnostic re-run 1: bare, with -v (zig cc default linker path)
        print("--- re-running with -v -Wl,--verbose (default linker) ---", file=sys.stderr)
        verbose1 = _build(triplet, src, binary + ".v1", zig_target, verbose=True)
        print("[exit_code]", verbose1.returncode, file=sys.stderr)
        print("[stdout]", file=sys.stderr)
        print(verbose1.stdout, file=sys.stderr)
        print("[stderr]", file=sys.stderr)
        print(verbose1.stderr, file=sys.stderr)

        # Diagnostic re-run 2: with -fuse-ld=lld forced, -v -Wl,--verbose
        print("--- re-running with -v -Wl,--verbose -fuse-ld=lld (forced LLD) ---", file=sys.stderr)
        verbose2 = _build(triplet, src, binary + ".v2", zig_target, verbose=True, extra=["-fuse-ld=lld"])
        print("[exit_code]", verbose2.returncode, file=sys.stderr)
        print("[stdout]", file=sys.stderr)
        print(verbose2.stdout, file=sys.stderr)
        print("[stderr]", file=sys.stderr)
        print(verbose2.stderr, file=sys.stderr)
        return 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(f"usage: {sys.argv[0]} <conda_triplet> [zig_target]")
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))
