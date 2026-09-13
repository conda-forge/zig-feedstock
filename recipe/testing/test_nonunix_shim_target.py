#!/usr/bin/env python3
"""Verify non-Unix (mingw) shim compile-call counts from install_zig_activation.py.

Shim target selection is pure logic; the guarded .c sources must be copied
alongside this test or _compile_c_shim is skipped and the count assertion
below misfires (see recipe/NOTES.md 2.10).

This drives install_zig_activation.main() with _compile_c_shim mocked out,
so no zig binary is actually invoked -- only the call count to _compile_c_shim
is asserted: 8 calls for a native (non-cross) non-Unix build (2 cc/cxx + 5
tool shims + 1 windres), 17 for a cross-compiler non-Unix build (8 for the
target suite + 8 for the native-triplet suite + 1 cross wrapper shim).
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

RECIPE = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("activation", RECIPE / "install_zig_activation.py")
activation = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(activation)


def _run_case(cross: bool, expected_count: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        env = {
            "PREFIX": tmp,
            "RECIPE_DIR": str(RECIPE),
            "CROSS_COMPILER": str(cross),
            "SHIM_RUNS_ON_TARGET": "False",
            "ZIG_TRIPLET": "x86_64-windows-gnu",
            "CONDA_TRIPLET": "x86_64-w64-mingw32",
            "NATIVE_TRIPLET": "x86_64-conda-linux-gnu",
            "NATIVE_ZIG_TRIPLET": "native",
        }
        with patch.dict(os.environ, env, clear=True), \
                patch.object(activation, "_compile_c_shim") as compile_shim:
            activation.main()
        actual_count = compile_shim.call_count
        if actual_count != expected_count:
            sys.exit(
                f"FAIL: cross={cross} expected {expected_count} _compile_c_shim "
                f"calls, got {actual_count}"
            )


def main() -> None:
    # This tree's install_zig_activation.py does not thread execution-arch
    # (SHIM_ZIG_TRIPLET) into the non-Unix branch of install_zig_cc_wrappers
    # -- that "execution architecture independent of codegen architecture"
    # refinement is a 0.17-only addition. Only the call-count assertion is
    # ported here; SHIM_RUNS_ON_TARGET is still exercised (as a no-op for
    # non-Unix) to match this tree's actual env-var contract.
    _run_case(cross=False, expected_count=8)
    _run_case(cross=True, expected_count=17)
    print("PASS: non-Unix shim compile call counts correct (8 native, 17 cross)")


if __name__ == "__main__":
    main()
