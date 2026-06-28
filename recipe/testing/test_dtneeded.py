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
import sys
import tempfile

from _test_utils import (
    FAIL,
    PASS,
    _results,
    _run,
    _triplet,
    print_results,
)


def _build(triplet: str, src: str, binary: str,
           *, verbose: bool = False, extra: list[str] | None = None):
    cmd = [f"{triplet}-zig", "cc"]
    if verbose:
        cmd += ["-v", "-Wl,--verbose"]
    if extra:
        cmd += extra
    cmd += ["-Wl,--no-as-needed", "-lm", src, "-o", binary]
    return _run(cmd)


def main(triplet: str) -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "foo.c")
        binary = os.path.join(tmpdir, "foo")
        with open(src, "w") as f:
            f.write("int main(void) { return 0; }\n")

        test_name = "-Wl,--no-as-needed -lm puts libm in DT_NEEDED"

        # Quiet first attempt.
        result = _build(triplet, src, binary)
        if result.returncode != 0:
            FAIL(test_name, "zig cc failed to compile/link")
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return 1

        readelf = _run(["readelf", "-d", binary])
        if readelf.returncode != 0:
            FAIL(test_name, "readelf failed")
            print(readelf.stderr, file=sys.stderr)
            return 1

        if re.search(r"NEEDED\b.*libm", readelf.stdout):
            PASS(test_name)
            return 0

        # Failure path: dump verbose diagnostics so the CI log shows
        # zig's actual LLD invocation and any env-level interference.
        FAIL(test_name, "libm not in DT_NEEDED after -Wl,--no-as-needed -lm")
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
        verbose1 = _build(triplet, src, binary + ".v1", verbose=True)
        print("[exit_code]", verbose1.returncode, file=sys.stderr)
        print("[stdout]", file=sys.stderr)
        print(verbose1.stdout, file=sys.stderr)
        print("[stderr]", file=sys.stderr)
        print(verbose1.stderr, file=sys.stderr)

        # Diagnostic re-run 2: with -fuse-ld=lld forced, -v -Wl,--verbose
        print("--- re-running with -v -Wl,--verbose -fuse-ld=lld (forced LLD) ---", file=sys.stderr)
        verbose2 = _build(triplet, src, binary + ".v2", verbose=True, extra=["-fuse-ld=lld"])
        print("[exit_code]", verbose2.returncode, file=sys.stderr)
        print("[stdout]", file=sys.stderr)
        print(verbose2.stdout, file=sys.stderr)
        print("[stderr]", file=sys.stderr)
        print(verbose2.stderr, file=sys.stderr)
        return 1


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit(f"usage: {sys.argv[0]} [conda_triplet]")
    triplet = sys.argv[1] if len(sys.argv) == 2 else _triplet
    if not triplet:
        sys.exit("error: no triplet supplied and CONDA_ZIG_HOST not set")
    main(triplet)
    ok = print_results(_results)
    sys.exit(0 if ok else 1)
