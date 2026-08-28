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
import shutil
import subprocess
import sys
import tempfile

from _test_utils import _run, check_emulation_env, resolve_test_prefix

_LINK_TIMEOUT_S = 900  # emulated zig cc compile+link needs headroom

# qemu-execve emulates the execve(2) syscall: it takes only pathnames and
# performs no PATH search, unlike Popen/execvp. Foreign-arch invocations
# (see _run()/emulation_prefix()) therefore need an absolute path to the
# zig wrapper, not a bare name.
_prefix = resolve_test_prefix("bin")
_wrapper_dir = _prefix / "bin"


def _build(triplet: str, src: str, binary: str,
           *, verbose: bool = False, extra: list[str] | None = None,
           zig_target: str | None = None) -> subprocess.CompletedProcess:
    zig_bin = _wrapper_dir / f"{triplet}-zig"
    if not zig_bin.is_file():
        msg = f"resolved zig wrapper not found: {zig_bin}"
        return subprocess.CompletedProcess([str(zig_bin), "cc"], returncode=1, stdout="", stderr=msg)
    cmd = [str(zig_bin), "cc"]
    if verbose:
        cmd += ["-v", "-Wl,--verbose"]
    if extra:
        cmd += extra
    if zig_target is not None:
        cmd += ["-target", zig_target]
    cmd += ["-Wl,--no-as-needed", "-lm", src, "-o", binary]
    return _run(cmd, timeout=_LINK_TIMEOUT_S, target=triplet)


def _dump_verbose_diagnostics(triplet: str, src: str, binary: str,
                               zig_target: str | None,
                               failing_argv: list[str] | None = None) -> None:
    """Re-run the compile verbosely to capture zig cc's actual linker invocation."""
    print("--- FAILING ARGV (original invocation) ---")
    if failing_argv is not None:
        for i, arg in enumerate(failing_argv):
            print(f"argv[{i:02d}]=[{arg}]")
        print("[joined]", " ".join(failing_argv))
    else:
        print("(failing argv not provided)")

    print("--- relevant env vars ---")
    for key in ("LDFLAGS", "LDFLAGS_LD", "CFLAGS", "CPPFLAGS",
                "CONDA_BUILD_SYSROOT", "CONDA_TOOLCHAIN_HOST",
                "CONDA_TOOLCHAIN_BUILD", "COMPILER_PATH", "GCC_EXEC_PREFIX",
                "LIBRARY_PATH", "LD_LIBRARY_PATH", "PATH", "CC", "CXX", "LD",
                "AR", "ZIG_LIBC", "ZIG_GLOBAL_CACHE_DIR", "QEMU_EXECVE",
                "QEMU_LD_PREFIX", "PREFIX", "BUILD_PREFIX", "CONDA_PREFIX",
                "ZIG_VERBOSE_LINK", "ZIG_VERBOSE_CC"):
        val = os.environ.get(key)
        print(f"{key}={val if val is not None else '(unset)'}")

    print("--- re-running with -v -Wl,--verbose (default linker) ---")
    verbose1 = _build(triplet, src, binary + ".v1", verbose=True, zig_target=zig_target)
    print("[exit_code]", verbose1.returncode)
    print("[stdout]")
    print(verbose1.stdout)
    print("[stderr]")
    print(verbose1.stderr)

    print("--- re-running with -v -Wl,--verbose -fuse-ld=lld (forced LLD) ---")
    verbose2 = _build(triplet, src, binary + ".v2", verbose=True, extra=["-fuse-ld=lld"], zig_target=zig_target)
    print("[exit_code]", verbose2.returncode)
    print("[stdout]")
    print(verbose2.stdout)
    print("[stderr]")
    print(verbose2.stderr)


def main(triplet: str, zig_target: str | None = None) -> int:
    if not check_emulation_env(triplet):
        return 1

    os.environ["ZIG_VERBOSE_LINK"] = "1"
    os.environ["ZIG_VERBOSE_CC"] = "1"

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "foo.c")
        binary = os.path.join(tmpdir, "foo")
        with open(src, "w") as f:
            f.write("int main(void) { return 0; }\n")

        # Quiet first attempt.
        result = _build(triplet, src, binary, zig_target=zig_target)
        if result.returncode != 0:
            print("FAIL: zig cc failed to compile/link", file=sys.stderr)
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            _dump_verbose_diagnostics(triplet, src, binary, zig_target, list(result.args))
            return 1

        readelf_bin = shutil.which("readelf")
        if readelf_bin is None:
            print("FAIL: readelf not found on PATH", file=sys.stderr)
            return 1
        readelf = _run([readelf_bin, "-d", binary])
        if readelf.returncode != 0:
            print("FAIL: readelf -d failed", file=sys.stderr)
            print(readelf.stdout, file=sys.stderr)
            print(readelf.stderr, file=sys.stderr)
            return 1

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
        print("--- ZIG VERBOSE LINK/CC (stderr) ---", file=sys.stderr)
        print(result.stderr, file=sys.stderr)

        _dump_verbose_diagnostics(triplet, src, binary, zig_target, list(result.args))
        return 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(f"usage: {sys.argv[0]} <conda_triplet> [zig_triplet]")
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
