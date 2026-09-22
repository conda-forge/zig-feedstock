#!/usr/bin/env python3
"""Probe the <triplet>-zig-cc wrapper linking a foreign (MSVC-built) prebuilt
IMPORT LIBRARY (zstd) -- the operation every win-arm64 consumer performs by
default, since conda-forge ships that lane as stock MSVC binaries."""

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

# Symbol declared locally, no zstd.h -- an include-path failure must never be
# misread as a link failure. stddef.h is a compiler header, not a zstd one.
_PROBE_C = """\
#include <stddef.h>

size_t ZSTD_compressBound(size_t srcSize);

int main(void) {
    size_t bound = ZSTD_compressBound(100);
    return bound == 0;
}
"""

_LINK_TIMEOUT_S = 120


def _find_wrapper(triplet: str, wrapper_dir: Path) -> str | None:
    """Locate the <triplet>-zig-cc wrapper: prefer ZIG_CC (set by activation),
    else the triplet-prefixed binary in the resolved wrapper dir -- same
    resolution test_zig_toolchain.py uses."""
    zig_cc_env = os.environ.get("ZIG_CC")
    if zig_cc_env and Path(zig_cc_env).is_file():
        return zig_cc_env
    suffix = ".exe" if _build_is_win else ""
    candidate = wrapper_dir / f"{triplet}-zig-cc{suffix}"
    return str(candidate) if candidate.is_file() else None


def main() -> None:
    failures: list[str] = []

    host = os.environ.get("CONDA_ZIG_HOST", "")
    triplet = host.removesuffix("-zig") if host.endswith("-zig") else host

    prefix = resolve_test_prefix("Library/bin" if _build_is_win else "bin")
    wrapper_dir = prefix / "Library" / "bin" if _build_is_win else prefix / "bin"

    zig_cc = _find_wrapper(triplet, wrapper_dir)
    if zig_cc is None:
        print(f"FAIL: no {triplet}-zig-cc wrapper found (checked ZIG_CC and {wrapper_dir})")
        failures.append("wrapper not found")
    else:
        # conda-forge's Windows zstd package installs its import library under
        # the Library/lib layout (same layout test_mingw_crt.py/test_libcxx_shared.py
        # use for Library/lib/zig -- zstd sits one level up, in Library/lib itself).
        lib_dir = prefix / "Library" / "lib"
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "foreign_import_lib.c"
            src.write_text(_PROBE_C)
            out = Path(td) / "foreign_import_lib.exe"
            argv = [zig_cc, str(src), f"-L{lib_dir}", "-lzstd", "-o", str(out)]
            result = _run(argv, cwd=td, timeout=_LINK_TIMEOUT_S)
            if timed_out(result):
                print(f"FAIL: link against foreign zstd import library timed out "
                      f"after {_LINK_TIMEOUT_S}s")
                failures.append("link timed out")
            elif result.returncode != 0:
                print("FAIL: link against foreign zstd import library: "
                      f"rc={result.returncode}")
                print(f"  ARGV: {' '.join(argv)}")
                print(f"  STDERR: {result.stderr[:2000]}")
                failures.append(f"link rc={result.returncode}")
            elif not out.is_file():
                print("FAIL: link reported success but output executable is missing")
                failures.append("output executable missing")
            else:
                print(f"PASS: linked foreign zstd import library via {zig_cc}")

    if failures:
        sys.stdout.flush()
        sys.exit("FAIL: foreign import library link probe: " + "; ".join(failures))

    print("foreign import library link probe: OK")


if __name__ == "__main__":
    main()
