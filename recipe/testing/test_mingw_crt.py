#!/usr/bin/env python3
"""Verify the mingw32 CRT bootstrap for ALL staged Windows targets.

recipe/building/_mingw.sh cache-warms x86_64-windows-gnu, aarch64-windows-gnu
and x86-windows-gnu, staging the real archives into lib-common/, libarm64/ and
lib32/ respectively. Uses the PASS/FAIL/WARN/SKIP harness from _test_utils.py
(also used by test_zig_toolchain.py) so one broken check records a FAIL/WARN
and the rest still run.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

from _test_utils import FAIL, PASS, WARN, _results, _run, resolve_test_prefix

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Build-side platform: rattler-build sets CONDA_BUILD_SYSROOT on macOS/Linux;
# on native Windows runners the OS reports itself directly.
_build_is_win = sys.platform == "win32" or os.environ.get("MSYSTEM") is not None

# Per-probe link budget. Probes are independent samples only because _run()
# kills the whole child process group on timeout (see _test_utils._run) --
# otherwise an orphaned zig from probe N keeps burning CPU and the zig cache
# lock during probe N+1, and the budget cannot be tuned from the measurements.
_PROBE_TIMEOUT_S = 900

# `zig ar t` only lists archive members -- no compilation -- but it gets a
# bounded budget anyway: it runs BEFORE the probes, and an unbounded hang here
# stalls the test with no diagnostic at all. Generous enough for emulated lanes.
_AR_LIST_TIMEOUT_S = 120

# Link probe: setjmp/longjmp reaches the __setjmp3 path; the explicit
# _fpreset() call forces the linker to resolve that symbol too. Both are
# link-time-only concerns -- the binary is never executed.
_LINK_PROBE_C = """\
#include <setjmp.h>

extern void _fpreset(void);

static jmp_buf _probe_buf;

static double _probe_fp(double x) {
    return x * 2.5;
}

int main(void) {
    volatile double d = _probe_fp(3.0);
    _fpreset();
    if (setjmp(_probe_buf) == 0) {
        longjmp(_probe_buf, 1);
    }
    return (int)d;
}
"""

# GUI-subsystem counterpart. Carries a constructor so the __main/__CTOR_LIST__
# path (governed by patches/non_unix/gccmain-do-global-ctors-guard.patch) is
# exercised in the same link.
_GUI_PROBE_C = """\
#include <windows.h>

static int _gui_ctor_ran = 0;

__attribute__((constructor))
static void _gui_mark_ctor(void) {
    _gui_ctor_ran = 1;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show) {
    (void)inst;
    (void)prev;
    (void)cmd;
    (void)show;
    return _gui_ctor_ran ? 0 : 3;
}
"""

# Shared target triples: mirrors the cache-warm loop in _mingw.sh (Steps 5+6
# and the warm-pair loop) so new probes stay in lockstep with staged archs.
_PROBE_TARGETS = ["x86_64-windows-gnu", "aarch64-windows-gnu", "x86-windows-gnu"]


def _find_zig_exe() -> tuple[str | None, str | None]:
    """Discover the build machine's <arch>-w64-mingw32-zig binary on PATH.

    This IS the real zig compiler (renamed to its build-triplet alias), so it
    accepts `-target` for any output arch -- reused by both the archive member
    check and the cross-target link probes.
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


def test_cross_target_link_probes(zig_exe: str) -> list[str]:
    """Compile+link a real binary against each staged CRT quartet.

    Link-only: arm64/32-bit outputs cannot run on a win-64 runner.

    The three targets mirror the cache-warm loop in recipe/building/_mingw.sh,
    where a failure on any one of them is a build FATAL -- so by the time this
    runs, all three CRTs are staged and correctly sized. Staged is not the same
    as linkable, which is the whole point of this probe: the warm program links
    snprintf+pthread_self and never touches setjmp.

    Every target is attempted even after a failure. WHICH SUBSET fails is the
    diagnostic: a single failing arch points at that arch's source-array
    membership, whereas all three failing uniformly points at this harness
    (zig discovery or triple spelling) instead.

    Returns a list of failure descriptions; empty means all probes linked.

    Each probe runs through _test_utils._run, which process-group-kills on
    timeout. That is what makes the probes independent samples: a raw
    subprocess.run leaves an orphaned zig alive after a timeout, so the next
    probe competes with it for CPU and the zig cache lock and its measured
    time says nothing usable about its own budget.
    """
    print("--- Cross-target link probes ---")
    failures: list[str] = []
    elapsed_s: list[tuple[str, float]] = []
    targets = ["x86_64-windows-gnu", "aarch64-windows-gnu", "x86-windows-gnu"]
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "probe.c"
        src.write_text(_LINK_PROBE_C)
        for target in targets:
            out = Path(td) / f"probe_{target}.exe"
            started = time.monotonic()
            result = _run(
                [zig_exe, "cc", "-target", target, "-o", str(out), str(src)],
                timeout=_PROBE_TIMEOUT_S,
            )
            elapsed = time.monotonic() - started
            elapsed_s.append((target, elapsed))
            # _run reports timeout as the (-1, "TIMEOUT") sentinel, not an exception.
            if result.returncode == -1 and result.stderr == "TIMEOUT":
                print(f"  FAIL: link probe ({target}): TIMEOUT after {elapsed:.1f}s "
                      f"(budget {_PROBE_TIMEOUT_S}s)")
                failures.append(f"{target}: TIMEOUT after {elapsed:.1f}s")
                continue
            if result.returncode == 0 and out.is_file():
                print(f"  PASS: link probe ({target}) in {elapsed:.1f}s")
            else:
                print(f"  FAIL: link probe ({target}): rc={result.returncode} "
                      f"after {elapsed:.1f}s")
                print(f"    stderr: {result.stderr[:400]!r}")
                failures.append(f"{target}: rc={result.returncode}")
    if elapsed_s:
        total = sum(e for _, e in elapsed_s)
        slowest_target, slowest = max(elapsed_s, key=lambda item: item[1])
        print(
            f"  probe timings: total {total:.1f}s, "
            + ", ".join(f"{t}={e:.1f}s" for t, e in elapsed_s)
        )
        print(
            f"  slowest probe: {slowest_target} at {slowest:.1f}s "
            f"({slowest / _PROBE_TIMEOUT_S:.0%} of the {_PROBE_TIMEOUT_S}s budget)"
        )
    return failures


def test_bundled_setjmp_h_undecorated(mingw_dir: Path) -> None:
    """Canary: guards patches/non_unix/mingw-setjmp-no-crtimp.patch, which strips
    _CRTIMP from _setjmp3/_setjmp in the SHIPPED (PREFIX-side) bundled mingw
    setjmp.h -- if that patch drifts or stops applying, callers linking against
    this header emit dllimport thunk references (__imp__setjmp / __imp___setjmp3)
    that lld-link cannot resolve against zig's statically-linked mingw runtime.
    """
    header = mingw_dir.parent / "include" / "any-windows-any" / "setjmp.h"
    if not header.is_file():
        FAIL("bundled setjmp.h canary",
             f"header not found at {header} -- the canary cannot run, "
             f"so a _CRTIMP regression would ship unseen")
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
            FAIL(name,
                 f"no declaration of {symbol} found in {header} -- "
                 f"header layout changed; re-anchor this canary")
            continue
        # Expand to the full statement; boundary is the nearest of a previous
        # ';', '}', end of a previous block comment, or end of the nearest
        # preceding preprocessor directive line.
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
        start = min(start, match.start())
        end = text.find(";", match.end())
        end = len(text) if end == -1 else end + 1
        decl_text = text[start:end].strip()
        decl_text = re.sub(r"/\*.*?\*/", "", decl_text, flags=re.DOTALL)
        decl_text = re.sub(r"//.*", "", decl_text).strip()
        if "_CRTIMP" in decl_text:
            FAIL(
                name,
                f"bundled setjmp.h now declares {symbol} with _CRTIMP (dllimport); "
                f"patches/non_unix/mingw-setjmp-no-crtimp.patch strips this on "
                f"apply -- either the patch failed to apply or upstream re-added "
                f"the decoration. Do NOT assume stripping it here is the fix: "
                f"investigate the patch application first. Offending declaration: "
                f"{decl_text!r}",
            )
        else:
            PASS(name)


def test_staged_archives(staged: list[tuple[str, Path]]) -> None:
    """All 8 staged real archives exist with size > 1MB, for every target.

    Staging is done by _mingw.sh's cache-warm loop (four-name copy, around
    _mingw.sh:706-718); that loop already enforces an internal 9.5MB byte
    floor per libmingw32.lib (_mingw.sh:687-704) before staging, so a FATAL
    there would abort the build. This 1MB threshold is a much looser,
    independent check at test time (catches a truncated/stub archive, not
    drift) and does not assume this tree's exact member sizes.
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
                f"(_mingw.sh's warm-pair loop is FATAL on failure, see "
                f"_mingw.sh:727-730)",
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
    """Pre-generated import libs per arch (_mingw.sh Steps 1/2/3/4, _mingw.sh:236-334).

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


def test_libpthread_import_lib(staged: list[tuple[str, Path]]) -> None:
    """libpthread.a preserved as a small import lib (NOT overwritten by alias).

    _mingw.sh's four-name copy loop (_mingw.sh:706-718) deliberately excludes
    libpthread.a (see its comment): libpthread.a is the small dlltool-generated
    import lib for libwinpthread-1.dll, and overwriting it with the big static
    archive would silently switch consumers from dynamic to static threading.

    Checked on ALL THREE staging dirs. Absence is a WARN (never asserted per-arch
    before); size violations FAIL -- that is the invariant.
    """
    print("--- libpthread.a import lib (all staged arches) ---")
    for target, lib_dir in staged:
        pthread_a = lib_dir / "libpthread.a"
        if not pthread_a.is_file():
            WARN(f"libpthread.a exists ({target})",
                 f"missing: {pthread_a} -- confirm from this log whether "
                 f"generation writes it here for this arch")
            continue
        size = pthread_a.stat().st_size
        if size == 0:
            FAIL(f"libpthread.a nonempty ({target})",
                 "0 bytes (dlltool failed -- see _mingw.sh WARNING output)")
        elif size > 5000:
            FAIL(f"libpthread.a size ({target})",
                 f"{size} bytes (import lib should be <5KB; was it overwritten "
                 f"by the big static archive? that silently switches consumers "
                 f"from dynamic to static threading)")
        else:
            PASS(f"libpthread.a size ({target})", f"{size} bytes")


def test_libmingw32_members(staged: list[tuple[str, Path]]) -> None:
    """Key source members present in libmingw32.lib via `zig ar t`.

    Runs the member listing for all three staged dirs -- an unreadable
    archive or a listing with zero members is arch-independent and always
    a FAIL. The specific ucrt_*/thread/mutex member names are asserted
    (FAIL on absence) only for x86_64-windows-gnu (lib-common); for
    libarm64/lib32 any mismatch only WARNs, printing the actual matching
    member lines so they can be confirmed from CI and hardened to FAIL
    later. 0.17 has no member-COUNT floor (unlike the byte-size floor at
    _mingw.sh:699) so only presence, never a specific count, is asserted.
    """
    print("--- libmingw32.lib source member check (zig ar t) ---")
    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        FAIL("libmingw32.lib member check",
             "no <arch>-w64-mingw32-zig binary found on PATH (xc_w64 lanes always ship it)")
        return

    expected_members = ("ucrt_snprintf", "ucrt_vsnprintf", "thread", "mutex")
    for target, lib_dir in staged:
        libmingw32 = lib_dir / "libmingw32.lib"
        result = _run([zig_exe, "ar", "t", str(libmingw32)], timeout=_AR_LIST_TIMEOUT_S)
        if result.returncode == -1 and result.stderr == "TIMEOUT":
            FAIL(f"zig ar t ({target})", f"TIMEOUT after {_AR_LIST_TIMEOUT_S}s")
            continue
        if result.returncode != 0:
            FAIL(f"zig ar t ({target})", f"rc={result.returncode}: {result.stderr[:400]}")
            continue

        member_lines = result.stdout.splitlines()
        if not member_lines:
            FAIL(f"zig ar t ({target}) member count", "archive lists 0 members")
            continue
        PASS(f"zig ar t ({target}) member count", f"{len(member_lines)} members")

        # Both .o (Unix archive convention) and .obj (Windows COFF) possible.
        for member in expected_members:
            found = any(
                f"{member}.o" in line or f"{member}.obj" in line
                for line in member_lines
            )
            name = f"libmingw32.lib member {member} ({target})"
            if found:
                PASS(name)
            elif target == "x86_64-windows-gnu":
                FAIL(name, "not found in ar t output")
            else:
                WARN(name, "not confirmed for this arch; see PASS lines above for actual members")


def test_gui_subsystem_link_probes() -> None:
    """Diagnostic: does the GUI-subsystem startup path link?

    We stage crt2win.o (built from crtexewin.c with -D_WINDOWS at
    _mingw.sh:496-504) but nothing else here exercises it -- the console
    probes above pull crt2.o. This links a minimal WinMain with -mwindows.
    """
    print("--- GUI-subsystem (crt2win.o) link probes ---")
    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        FAIL("gui link probes",
             "no <arch>-w64-mingw32-zig binary found on PATH (xc_w64 lanes always ship it)")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "gui_probe.c"
        src.write_text(_GUI_PROBE_C)
        for target in _PROBE_TARGETS:
            name = f"gui link probe ({target})"
            out = Path(td) / f"gui_probe_{target}.exe"
            t0 = time.monotonic()
            result = _run(
                [zig_exe, "cc", "-target", target, "-mwindows",
                 "-o", str(out), str(src)],
                timeout=_PROBE_TIMEOUT_S,
            )
            elapsed = time.monotonic() - t0
            if result.returncode == -1 and result.stderr == "TIMEOUT":
                WARN(f"{name} [{elapsed:.1f}s]", f"TIMEOUT ({_PROBE_TIMEOUT_S}s)")
            elif result.returncode == 0 and out.is_file():
                PASS(f"{name} [{elapsed:.1f}s]")
            else:
                FAIL(f"{name} [{elapsed:.1f}s]",
                     f"rc={result.returncode} stderr={result.stderr[:400]!r}")


def test_alias_archive_identity(staged: list[tuple[str, Path]]) -> None:
    """The four staged CRT names are ONE archive under four spellings.

    _mingw.sh's cache-warm loop (_mingw.sh:713-717) copies a single
    zig-built archive to libmingw32 / libucrt / libmingwex / libwinpthread,
    each as .lib and .a, so consumers spelling -lucrt / -lmingwex /
    -lwinpthread all resolve. Identical byte sizes across the four names
    are therefore EXPECTED, not a bug.
    """
    print("--- Staged CRT alias identity (four names, one archive) ---")
    alias_names = ["libmingw32", "libucrt", "libmingwex", "libwinpthread"]
    for target, lib_dir in staged:
        if not lib_dir.is_dir():
            continue
        digests: dict[str, str] = {}
        for base in alias_names:
            for ext in (".lib", ".a"):
                p = lib_dir / f"{base}{ext}"
                if p.is_file():
                    digests[p.name] = hashlib.sha256(p.read_bytes()).hexdigest()
        if not digests:
            FAIL(f"alias identity ({target})", "no staged alias archives found")
            continue
        unique = sorted(set(digests.values()))
        if len(unique) == 1:
            PASS(f"alias identity ({target})",
                 f"{len(digests)} files, one digest {unique[0][:12]}")
        else:
            detail = ", ".join(f"{n}={d[:12]}" for n, d in sorted(digests.items()))
            FAIL(f"alias identity ({target})",
                 f"{len(unique)} distinct digests across {len(digests)} staged "
                 f"names, expected 1 (see the _mingw.sh four-name copy loop): "
                 f"{detail}")


def main() -> int:
    prefix = resolve_test_prefix("Library/lib/zig" if _build_is_win else "lib/zig")
    if not prefix.exists():
        FAIL("CONDA_PREFIX set", "not set or missing")

    # mingw root differs between Windows-layout and Unix-layout conda envs
    if _build_is_win:
        mingw_dir = prefix / "Library" / "lib" / "zig" / "libc" / "mingw"
    else:
        mingw_dir = prefix / "lib" / "zig" / "libc" / "mingw"

    # Staging dir per warm target, matching _mingw.sh's cache-warm loop (:656-719).
    staged = [
        ("x86_64-windows-gnu", mingw_dir / "lib-common"),
        ("aarch64-windows-gnu", mingw_dir / "libarm64"),
        ("x86-windows-gnu", mingw_dir / "lib32"),
    ]

    test_staged_archives(staged)
    test_alias_archive_identity(staged)
    test_prebuilt_implibs(staged)
    test_libpthread_import_lib(staged)
    test_libmingw32_members(staged)

    zig_exe, _triplet = _find_zig_exe()
    if zig_exe is None:
        FAIL("cross-target link probes",
             "no <arch>-w64-mingw32-zig binary found on PATH (xc_w64 lanes always ship it)")
    else:
        probe_failures = test_cross_target_link_probes(zig_exe)
        if probe_failures:
            FAIL("cross-target link probes", "; ".join(probe_failures))
        else:
            PASS("cross-target link probes", f"all {len(_PROBE_TARGETS)} targets linked")

    test_gui_subsystem_link_probes()
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
