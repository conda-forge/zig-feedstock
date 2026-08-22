#!/usr/bin/env python3
"""Verify the mingw32 CRT bootstrap for ALL staged Windows targets.

recipe/building/_mingw.sh cache-warms x86_64-windows-gnu, aarch64-windows-gnu
and x86-windows-gnu, staging the real archives into lib-common/, libarm64/ and
lib32/ respectively.  A failed warm iteration only WARNs and skips its stage,
so an entire architecture can go missing from the package silently; this test
checks all three.

Not pytest: uses the custom PASS/FAIL/WARN/SKIP harness (see _test_utils.py,
also used by test_zig_toolchain.py and test_flag_translation_parity.py) so
one broken arch records a FAIL and the rest of the checks still run.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from _test_utils import PASS, FAIL, WARN, SKIP, _results

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Build-side platform: rattler-build sets CONDA_BUILD_SYSROOT on macOS/Linux;
# on native Windows runners the OS reports itself directly.
_build_is_win = sys.platform == "win32" or os.environ.get("MSYSTEM") is not None

# Minimal C source for the cross-target link probes: a setjmp/longjmp
# round-trip (__setjmp3 path) plus a floating-point op (_fpreset-adjacent
# codegen) -- the symbol classes that have historically broken the
# non-x86_64 mingw CRT bootstrap. Link-only; never executed (arm64/32-bit
# outputs cannot run on this runner).
_LINK_PROBE_C = """\
#include <setjmp.h>

static jmp_buf _probe_buf;

static double _probe_fp(double x) {
    return x * 2.5;
}

int main(void) {
    volatile double d = _probe_fp(3.0);
    if (setjmp(_probe_buf) == 0) {
        longjmp(_probe_buf, 1);
    }
    return (int)d;
}
"""


def _find_zig_exe() -> tuple[str | None, str | None]:
    """Discover the build machine's <arch>-w64-mingw32-zig binary on PATH.

    This IS the real zig compiler (renamed to its build-triplet alias, see
    CONDA_ZIG_BUILD / install_zig_activation.py), so it accepts `-target`
    for any output arch -- reused by both the member check and the
    cross-target link probes.
    """
    candidates = [
        "x86_64-w64-mingw32-zig",
        "i686-w64-mingw32-zig",
        "aarch64-w64-mingw32-zig",
    ]
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            return found, candidate.removesuffix("-zig")
    return None, None


def test_bundled_setjmp_h_undecorated(mingw_dir: Path) -> None:
    """Canary: guards against zig snapshot bumps that decorate the bundled
    mingw setjmp.h's `_setjmp3`/`_setjmp` with `_CRTIMP` (fuse = snapshot bump).
    """
    header = mingw_dir.parent / "include" / "any-windows-any" / "setjmp.h"
    if not header.is_file():
        SKIP("bundled setjmp.h canary", f"header not found at {header}")
        return

    text = header.read_text(encoding="utf-8", errors="replace")
    for symbol in ("_setjmp3", "_setjmp"):
        name = f"bundled setjmp.h {symbol} undecorated"
        # A symbol can appear on a preprocessor-directive line (e.g. the
        # macro `#define setjmp(BUF) _setjmp((BUF))`); that is not a
        # declaration, so skip such occurrences and keep looking for one
        # that actually is a declaration.
        match = None
        for candidate in re.finditer(rf"(?<!\w){re.escape(symbol)}\s*\(", text):
            line_start = text.rfind("\n", 0, candidate.start()) + 1
            newline_idx = text.find("\n", candidate.start())
            line_end = len(text) if newline_idx == -1 else newline_idx
            line = text[line_start:line_end]
            if line.lstrip().startswith("#"):
                continue
            match = candidate
            break
        if match is None:
            SKIP(name, f"no declaration of {symbol} found in {header}")
            continue
        # Expand to the full statement so multi-line declarations and
        # attributes between the type and the symbol name are captured.
        # The backward boundary is bounded by whichever of these sits
        # closest (nearest/highest index) to the match: a previous ';',
        # a previous '}', the end of a previous '*/' block comment, or
        # the end of the nearest preceding preprocessor directive line
        # (so long #define/#include/#if stretches with no semicolon
        # can't smuggle unrelated text like a `_CRTIMP` macro definition
        # into the captured declaration).
        semi = text.rfind(";", 0, match.start()) + 1
        brace = text.rfind("}", 0, match.start()) + 1
        comment_end = text.rfind("*/", 0, match.start())
        comment_end = comment_end + 2 if comment_end != -1 else 0
        directive_end = 0
        for directive in re.finditer(r"^[ \t]*#.*$", text, re.MULTILINE):
            if directive.start() >= match.start():
                break
            directive_end = directive.end()
        start = max(semi, brace, comment_end, directive_end, 0)
        # Belt and braces: whatever the boundary logic above computes,
        # never let the window start past the symbol itself.
        start = min(start, match.start())
        end = text.find(";", match.end())
        end = len(text) if end == -1 else end + 1
        decl_text = text[start:end].strip()
        # Strip comments so a comment merely mentioning _CRTIMP (rather
        # than an actual decorator on the declaration) can't trip this.
        decl_text = re.sub(r"/\*.*?\*/", "", decl_text, flags=re.DOTALL)
        decl_text = re.sub(r"//.*", "", decl_text).strip()
        if "_CRTIMP" in decl_text:
            FAIL(
                name,
                f"bundled zig snapshot's mingw setjmp.h now declares {symbol} "
                f"with _CRTIMP (dllimport). The zig 0.16.0 baseline is "
                f"undecorated for both _setjmp and _setjmp3 (only longjmp "
                f"carries _CRTIMP), so this is a snapshot change. Do NOT "
                f"assume stripping it is the fix: _CRTIMP was measured and "
                f"eliminated as the cause of the x86_64-windows-gnu "
                f"winpthreads/thread.c pthread_create_wrapper link failure. "
                f"Investigate before acting. Offending declaration: "
                f"{decl_text!r}",
            )
        else:
            PASS(name)


def test_staged_archives(staged: list[tuple[str, Path]]) -> None:
    """1. All 8 staged real archives exist with size > 1MB, for every target.

    Observed sizes are ~10.8MB (x86_64), ~11.0MB (aarch64), ~11.4MB (x86).
    """
    print("--- Staged CRT archives (per target) ---")
    expected_libs = [
        "libmingw32.lib", "libmingw32.a",
        "libucrt.lib", "libucrt.a",
        "libmingwex.lib", "libmingwex.a",
        "libwinpthread.lib", "libwinpthread.a",
    ]
    for target, lib_dir in staged:
        if not lib_dir.is_dir():
            FAIL(
                f"staging dir exists ({target})",
                f"{lib_dir} missing -- cache-warm failed for this target "
                f"(it only WARNs, so the package would ship with no CRT "
                f"archives for this arch)",
            )
            continue
        PASS(f"staging dir exists ({target})")
        for lib in expected_libs:
            p = lib_dir / lib
            if not p.is_file():
                FAIL(f"{lib} present ({target})", f"missing: {p}")
                continue
            size = p.stat().st_size
            if size < 1_000_000:
                FAIL(f"{lib} size ({target})", f"{size} bytes, expected >1MB real archive")
            else:
                PASS(f"{lib} size ({target})", f"{size} bytes")


def test_prebuilt_implibs(staged: list[tuple[str, Path]]) -> None:
    """1b. Pre-generated import libs per arch (_mingw.sh Steps 1/2/3/4).

    Asserted here, on the lane that generates them; see its WARNING output
    if any of these are missing or empty.
    """
    print("--- Pre-generated per-arch import libs ---")
    per_arch_implibs = [
        "libws2_32.a",
        "libkernel32.a",
        "libole32.a",
        "libadvapi32.a",
        "libuser32.a",
        "libsynchronization.a",
        "libshlwapi.a",
        "libversion.a",
        "libuuid.a",
    ]
    for target, lib_dir in staged:
        for lib in per_arch_implibs:
            name = f"{lib} present+nonempty ({target})"
            p = lib_dir / lib
            if not p.is_file():
                FAIL(name, f"missing: {p}")
            elif p.stat().st_size == 0:
                FAIL(name, f"0 bytes: {p}")
            else:
                PASS(name, f"{p.stat().st_size} bytes")


def test_libpthread_import_lib(lib_common: Path) -> None:
    """2. libpthread.a preserved as small import lib (NOT overwritten by alias).

    Generated from mingw-defs into lib-common only -- the cache-warm loop
    does not stage it into libarm64/ or lib32/, so scoped to lib-common.
    """
    print("--- libpthread.a import lib (lib-common only) ---")
    pthread_a = lib_common / "libpthread.a"
    if not pthread_a.is_file():
        FAIL("libpthread.a exists", f"missing: {pthread_a}")
        return
    size = pthread_a.stat().st_size
    if size == 0:
        FAIL("libpthread.a nonempty", "0 bytes (dlltool failed -- see _mingw.sh WARNING output)")
    elif size > 5000:
        FAIL("libpthread.a size", f"{size} bytes (import lib should be <5KB, was it overwritten?)")
    else:
        PASS("libpthread.a size", f"{size} bytes")


def test_libmingw32_members(staged: list[tuple[str, Path]]) -> None:
    """3. Key source members present in libmingw32.lib via `zig ar t`.

    Runs the member listing for all three staged dirs -- an unreadable
    archive or a listing with zero members is arch-independent and always
    a FAIL. The specific ucrt_*/thread/mutex member names are asserted
    (FAIL on absence) only for lib-common (x86_64), where they were
    verified; for libarm64/lib32 those names are unconfirmed, so any
    mismatch there only WARNs and prints the actual matching member lines
    found, so they can be confirmed from the next CI log and hardened to
    FAIL later.
    """
    print("--- libmingw32.lib source member check (zig ar t) ---")
    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        FAIL("libmingw32.lib member check", "no <arch>-w64-mingw32-zig binary found on PATH")
        return

    expected_members = ("ucrt_snprintf", "ucrt_vsnprintf", "thread", "mutex")
    for target, lib_dir in staged:
        libmingw32 = lib_dir / "libmingw32.lib"
        result = subprocess.run(
            [zig_exe, "ar", "t", str(libmingw32)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            FAIL(f"zig ar t ({target})", f"rc={result.returncode}: {result.stderr[:400]}")
            continue

        member_lines = result.stdout.splitlines()
        if not member_lines:
            FAIL(f"zig ar t ({target}) member count", "archive lists 0 members")
            continue
        PASS(f"zig ar t ({target}) member count", f"{len(member_lines)} members")

        if target == "x86_64-windows-gnu":
            # Both .o (Unix archive convention) and .obj (Windows COFF) possible.
            for member in expected_members:
                found = any(
                    f"{member}.o" in line or f"{member}.obj" in line
                    for line in member_lines
                )
                if found:
                    PASS(f"libmingw32.lib member {member} ({target})")
                else:
                    FAIL(f"libmingw32.lib member {member} ({target})", "not found in ar t output")
        else:
            matches = [
                line for line in member_lines
                if any(m in line for m in expected_members)
            ]
            WARN(
                f"libmingw32.lib ucrt_*/thread/mutex members ({target}) unconfirmed",
                f"matching lines: {matches!r}" if matches
                else f"no match; sample members: {member_lines[:20]!r}",
            )


def test_cross_target_link_probes() -> None:
    """1. Compile+link a real binary against each staged CRT quartet.

    Exercises setjmp/longjmp (__setjmp3 path) and a floating-point op
    (_fpreset-adjacent path) via `zig cc -target <triple>` -- link-only,
    since arm64/32-bit outputs cannot run on this (win-64) runner.
    """
    print("--- Cross-target link probes ---")
    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        SKIP("cross-target link probes", "no <arch>-w64-mingw32-zig binary found on PATH")
        return

    probe_timeout_s = 600
    targets = ["x86_64-windows-gnu", "aarch64-windows-gnu", "x86-windows-gnu"]
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "probe.c"
        src.write_text(_LINK_PROBE_C)
        for target in targets:
            name = f"link probe ({target})"
            out = Path(td) / f"probe_{target}.exe"
            try:
                result = subprocess.run(
                    [zig_exe, "cc", "-target", target, "-o", str(out), str(src)],
                    capture_output=True, text=True, timeout=probe_timeout_s, check=False,
                )
            except subprocess.TimeoutExpired:
                FAIL(name, f"TIMEOUT ({probe_timeout_s}s)")
                continue
            if result.returncode == 0 and out.is_file():
                PASS(name)
            else:
                FAIL(name, f"rc={result.returncode} stderr={result.stderr[:400]!r}")


def main() -> int:
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    if not prefix.exists():
        FAIL("CONDA_PREFIX set", "not set or missing")

    # mingw root differs between Windows-layout and Unix-layout conda envs
    if _build_is_win:
        mingw_dir = prefix / "Library" / "lib" / "zig" / "libc" / "mingw"
    else:
        mingw_dir = prefix / "lib" / "zig" / "libc" / "mingw"

    # Staging dir per warm target, matching _mingw.sh's cache-warm loop.
    staged = [
        ("x86_64-windows-gnu", mingw_dir / "lib-common"),
        ("aarch64-windows-gnu", mingw_dir / "libarm64"),
        ("x86-windows-gnu", mingw_dir / "lib32"),
    ]
    lib_common = staged[0][1]

    test_staged_archives(staged)
    test_prebuilt_implibs(staged)
    test_libpthread_import_lib(lib_common)
    test_libmingw32_members(staged)
    test_cross_target_link_probes()
    test_bundled_setjmp_h_undecorated(mingw_dir)

    print()
    n_pass = len(_results["PASS"])
    n_fail = len(_results["FAIL"])
    n_warn = len(_results["WARN"])
    n_skip = len(_results["SKIP"])
    print(
        f"=== Results: {n_pass} passed, {n_fail} failed, "
        f"{n_warn} warnings, {n_skip} skipped ==="
    )

    if n_fail:
        print("\nFailed tests:")
        for name in _results["FAIL"]:
            print(f"  - {name}")

    if n_warn:
        print("\nWarnings (unconfirmed, not yet hardened to FAIL):")
        for name in _results["WARN"]:
            print(f"  - {name}")

    if n_fail == 0:
        print(
            "\nmingw CRT bootstrap OK: x86_64 (lib-common), "
            "aarch64 (libarm64), x86 (lib32)"
        )

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
