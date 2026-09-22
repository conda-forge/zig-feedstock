#!/usr/bin/env python3
"""Probe the <triplet>-zig-cc wrapper's GNU -l:<filename> exact-filename
resolution. Nothing in this recipe emits a -l: token, so this wrapper code
path has no other coverage -- a defect in it surfaces only in a consumer
build, never on our own board.

Covers resolution against both -L spellings, and the not-found path."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from _test_utils import _build_is_win, _run, resolve_test_prefix, timed_out

# foo_value is defined ONLY inside the archive reached via -l:. If the wrapper
# drops or mangles the token, the link fails with an undefined symbol -- so a
# successful link proves the resolved path really reached the linker.
_LIB_C = """\
int foo_value(void) { return 42; }
"""

_MAIN_C = """\
int foo_value(void);

int main(void) {
    return foo_value() == 42 ? 0 : 1;
}
"""

_TIMEOUT_S = 120

# Distinctive so the searched-dirs diagnostic can be asserted without
# depending on path separator spelling.
_EMPTY_DIR_NAME = "probe_empty_ldir"


def _find_tool(triplet: str, wrapper_dir: Path, name: str, env_var: str) -> str | None:
    """Prefer the activation-set env var, else the triplet-prefixed binary in
    the resolved wrapper dir -- same resolution test_foreign_import_lib.py uses."""
    from_env = os.environ.get(env_var)
    if from_env and Path(from_env).is_file():
        return from_env
    suffix = ".exe" if _build_is_win else ""
    candidate = wrapper_dir / f"{triplet}-{name}{suffix}"
    return str(candidate) if candidate.is_file() else None


def main() -> None:
    failures: list[str] = []

    host = os.environ.get("CONDA_ZIG_HOST", "")
    triplet = host.removesuffix("-zig") if host.endswith("-zig") else host

    prefix = resolve_test_prefix("Library/bin" if _build_is_win else "bin")
    wrapper_dir = prefix / "Library" / "bin" if _build_is_win else prefix / "bin"

    zig_cc = _find_tool(triplet, wrapper_dir, "zig-cc", "ZIG_CC")
    zig_ar = _find_tool(triplet, wrapper_dir, "zig-ar", "ZIG_AR")
    if zig_cc is None or zig_ar is None:
        sys.exit(
            f"FAIL: -l: link probe: wrapper not found "
            f"(zig-cc={zig_cc}, zig-ar={zig_ar}, dir={wrapper_dir})"
        )

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        libdir = tmp / "libs"
        libdir.mkdir()
        empty = tmp / _EMPTY_DIR_NAME
        empty.mkdir()

        lib_src = tmp / "foo.c"
        lib_src.write_text(_LIB_C)
        main_src = tmp / "main.c"
        main_src.write_text(_MAIN_C)
        obj = tmp / "foo.o"

        # Build libfoo.a through the same toolchain the wrapper drives.
        result = _run([zig_cc, "-c", str(lib_src), "-o", str(obj)], cwd=td, timeout=_TIMEOUT_S)
        if result.returncode != 0:
            sys.exit(
                f"FAIL: -l: link probe: could not compile fixture object: "
                f"rc={result.returncode}\n{result.stderr[:2000]}"
            )

        archive = libdir / "libfoo.a"
        result = _run([zig_ar, "rcs", str(archive), str(obj)], cwd=td, timeout=_TIMEOUT_S)
        if result.returncode != 0 or not archive.is_file():
            sys.exit(
                f"FAIL: -l: link probe: could not archive fixture: "
                f"rc={result.returncode}\n{result.stderr[:2000]}"
            )

        # Checks 1 and 2: the token resolves against both -L spellings.
        for tag, label, ldflags in (
            ("joined", "joined -L<dir>", [f"-L{libdir}"]),
            ("spaced", "spaced -L <dir>", ["-L", str(libdir)]),
        ):
            out = tmp / f"out_{tag}.exe"
            argv = [zig_cc, str(main_src), *ldflags, "-l:libfoo.a", "-o", str(out)]
            result = _run(argv, cwd=td, timeout=_TIMEOUT_S)
            if timed_out(result):
                print(f"FAIL: -l:libfoo.a with {label} timed out after {_TIMEOUT_S}s")
                failures.append(f"{label} timed out")
            elif result.returncode != 0:
                print(f"FAIL: -l:libfoo.a with {label}: rc={result.returncode}")
                print(f"  ARGV: {' '.join(argv)}")
                print(f"  STDERR: {result.stderr[:2000]}")
                failures.append(f"{label} rc={result.returncode}")
            elif not out.is_file():
                print(f"FAIL: -l:libfoo.a with {label}: link reported success but output is missing")
                failures.append(f"{label} output missing")
            else:
                print(f"PASS: resolved -l:libfoo.a with {label}")

        # Check 3: unresolvable token WITH a -L dir must fail loudly and name
        # the dirs it searched, rather than forwarding the token to zig.
        out = tmp / "miss.exe"
        argv = [zig_cc, str(main_src), f"-L{empty}", "-l:libmissing.a", "-o", str(out)]
        result = _run(argv, cwd=td, timeout=_TIMEOUT_S)
        if timed_out(result):
            print(f"FAIL: unresolvable -l: with a -L dir timed out after {_TIMEOUT_S}s")
            failures.append("miss-with-Ldir timed out")
        elif result.returncode == 0:
            print("FAIL: unresolvable -l:libmissing.a with a -L dir unexpectedly succeeded")
            failures.append("miss-with-Ldir succeeded")
        elif "not found. Searched" not in result.stderr or _EMPTY_DIR_NAME not in result.stderr:
            print("FAIL: unresolvable -l: with a -L dir did not emit the searched-dirs diagnostic")
            print(f"  STDERR: {result.stderr[:2000]}")
            failures.append("miss-with-Ldir diagnostic missing")
        else:
            print("PASS: unresolvable -l: with a -L dir failed loudly, naming the searched dirs")

        # Check 4: unresolvable token with no user -L dir must still be OUR
        # diagnostic, not a zig driver panic. The wrapper may inject -L dirs of
        # its own, so assert only the substring common to both diagnostic forms.
        out = tmp / "miss_no_ldir.exe"
        argv = [zig_cc, str(main_src), "-l:libmissing.a", "-o", str(out)]
        result = _run(argv, cwd=td, timeout=_TIMEOUT_S)
        if timed_out(result):
            print(f"FAIL: unresolvable -l: with no -L dir timed out after {_TIMEOUT_S}s")
            failures.append("miss-no-Ldir timed out")
        elif result.returncode == 0:
            print("FAIL: unresolvable -l:libmissing.a with no -L dir unexpectedly succeeded")
            failures.append("miss-no-Ldir succeeded")
        elif "-l:libmissing.a not found" not in result.stderr:
            print("FAIL: unresolvable -l: with no -L dir did not emit the wrapper diagnostic")
            print(f"  STDERR: {result.stderr[:2000]}")
            failures.append("miss-no-Ldir diagnostic missing")
        else:
            print("PASS: unresolvable -l: with no -L dir failed loudly with the wrapper diagnostic")

    if failures:
        sys.stdout.flush()
        sys.exit("FAIL: -l: exact-filename link probe: " + "; ".join(failures))

    print("-l: exact-filename link probe: OK")


if __name__ == "__main__":
    main()
