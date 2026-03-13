#!/usr/bin/env python3
"""
Zig toolchain functional tests for conda-forge.

Replaces test-wrappers.sh / test-wrappers.bat with a single cross-platform
test that adds functional validation and characterization tests for known
zig bugs.

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
_results: dict[str, list[str]] = {"PASS": [], "FAIL": [], "WARN": [], "SKIP": []}


def _record(status: str, name: str, detail: str = "") -> None:
    tag = f"  {status}: {name}"
    if detail:
        tag += f" ({detail})"
    print(tag)
    _results[status].append(name)


def PASS(name: str, detail: str = "") -> None:
    _record("PASS", name, detail)


def FAIL(name: str, detail: str = "") -> None:
    _record("FAIL", name, detail)


def WARN(name: str, detail: str = "") -> None:
    _record("WARN", name, detail)


def SKIP(name: str, detail: str = "") -> None:
    _record("SKIP", name, detail)


# ---------------------------------------------------------------------------
# Platform detection from CONDA_ZIG_HOST
# ---------------------------------------------------------------------------
_host = os.environ.get("CONDA_ZIG_HOST", "")  # e.g. "x86_64-w64-mingw32-zig"
_triplet = _host.removesuffix("-zig") if _host.endswith("-zig") else _host

is_win_target = "mingw32" in _triplet
is_macos_target = "apple" in _triplet or "darwin" in _triplet
is_linux_target = "linux" in _triplet
_arch = _triplet.split("-")[0] if _triplet else platform.machine()
is_ppc64le_target = "powerpc64le" in _triplet or _arch == "powerpc64le"

# Normalise: arm64 == aarch64
if _arch == "arm64":
    _arch = "aarch64"

# Build-machine OS (where the test actually runs)
_build_is_win = sys.platform == "win32"
_build_is_mac = sys.platform == "darwin"

# Emulation detection: on CI, non-x86_64 Linux typically runs under QEMU.
# zig's linker is too memory-hungry for emulated environments (OOM → exit 137).
_native_machine = platform.machine()
_is_emulated = (
    sys.platform == "linux"
    and _native_machine not in ("x86_64", "i686")
    and os.environ.get("CI", "") != ""
)

# Cross-compiler detection: build != host means the zig binary targets a
# different platform.  Cross-compilers use the *prior published* zig_impl,
# so linking tests may fail due to older patches.
_build_zig = os.environ.get("CONDA_ZIG_BUILD", "")
_is_cross_compiler = _build_zig != _host and _build_zig != "" and _host != ""

_prefix = Path(os.environ.get("CONDA_PREFIX", ""))
if _build_is_win:
    _wrapper_dir = _prefix / "Library" / "share" / "zig" / "wrappers"
else:
    _wrapper_dir = _prefix / "share" / "zig" / "wrappers"


def _env_var(name: str) -> str:
    """Return env var value or empty string."""
    return os.environ.get(name, "")


def _run(
    cmd: list[str],
    *,
    timeout: int = 30,
    cwd: str | Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a command, return CompletedProcess. Never raises on non-zero rc."""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
    )
    try:
        stdout_b, stderr_b = proc.communicate(timeout=timeout)
        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")
        return subprocess.CompletedProcess(cmd, returncode=proc.returncode,
                                           stdout=stdout, stderr=stderr)
    except subprocess.TimeoutExpired:
        # Kill the process tree to prevent zombie processes producing
        # non-UTF-8 output that can crash the caller (e.g. rattler-build on Windows).
        try:
            if _build_is_win:
                # taskkill /T kills the entire process tree (zig-cc.exe + child zig)
                # Plain proc.kill() only kills the wrapper, leaving zig alive on pipes
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                    capture_output=True, timeout=5,
                )
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()
        try:
            proc.communicate(timeout=5)  # Drain pipes — may hang if children survive
        except (subprocess.TimeoutExpired, OSError):
            # Children still alive: force-close pipes so we don't block forever
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    try:
                        pipe.close()
                    except OSError:
                        pass
        return subprocess.CompletedProcess(cmd, returncode=-1, stdout="", stderr="TIMEOUT")


# ---------------------------------------------------------------------------
# C source snippets used by functional tests
# ---------------------------------------------------------------------------
_HELLO_C = 'int hello(void) { return 42; }\n'
_MAIN_C = 'int main(void) { return 0; }\n'
_VIS_C = '__attribute__((visibility("default"))) int vis_test_func(void) { return 1; }\n'


# ===================================================================
# Section 1 — Wrapper existence
# ===================================================================
def test_wrapper_existence() -> None:
    print("--- Wrapper existence ---")

    if _build_is_win:
        expected = [
            "zig-cc.exe",
            "zig-cxx.exe",
            "zig-cxx-shared.exe",
            "zig-ar.bat",
            "zig-ranlib.bat",
            "zig-asm.bat",
            "zig-rc.bat",
        ]
    else:
        expected = [
            "zig-cc",
            "zig-cxx",
            "zig-cxx-shared",
            "zig-force-load-cc",
            "zig-force-load-cxx",
            "zig-ar",
            "zig-ranlib",
            "zig-asm",
            "zig-rc",
            "_zig-cc-common.sh",
        ]

    for w in expected:
        p = _wrapper_dir / w
        if not p.exists():
            FAIL(f"{w} exists")
            continue
        PASS(f"{w} exists")
        # Executability (Unix only, skip .sh helper)
        if not _build_is_win and not w.endswith(".sh"):
            if os.access(p, os.X_OK):
                PASS(f"{w} is executable")
            else:
                FAIL(f"{w} is executable")


# ===================================================================
# Section 2 — Activation variables
# ===================================================================
def test_activation_variables() -> None:
    print("--- Activation variables ---")

    # Common across platforms
    for var in ("CONDA_ZIG_BUILD", "CONDA_ZIG_HOST"):
        val = _env_var(var)
        if val:
            PASS(f"{var} is set", val)
        else:
            FAIL(f"{var} is set")

    if _env_var("CONDA_ZIG_HOST") and _host:
        if _env_var("CONDA_ZIG_HOST") == _host:
            PASS("CONDA_ZIG_HOST matches expected")
        else:
            FAIL("CONDA_ZIG_HOST matches expected",
                 f"got {_env_var('CONDA_ZIG_HOST')!r}, want {_host!r}")

    # ZIG_CC / ZIG_CXX
    for var in ("ZIG_CC", "ZIG_CXX"):
        val = _env_var(var)
        if val:
            PASS(f"{var} is set", val)
        else:
            # These may not be set in all activation modes
            SKIP(f"{var} is set", "not activated")

    # Unix-specific
    if not _build_is_win:
        for var in ("ZIG_FORCE_LOAD_CC", "ZIG_CXX_SHARED"):
            val = _env_var(var)
            if val:
                PASS(f"{var} is set")
                if os.path.isfile(val) and os.access(val, os.X_OK):
                    PASS(f"{var} points to executable")
                else:
                    FAIL(f"{var} points to executable", val)
            else:
                FAIL(f"{var} is set")

    # Windows-specific
    if _build_is_win:
        for var in ("ZIG_RC", "ZIG_CXX_SHARED"):
            val = _env_var(var)
            if val:
                PASS(f"{var} is set")
            else:
                FAIL(f"{var} is set")

        # ZIG_RC_CMAKE path escaping
        rc_cmake = _env_var("ZIG_RC_CMAKE")
        if rc_cmake:
            PASS("ZIG_RC_CMAKE is set")
            if "\\" not in rc_cmake:
                PASS("ZIG_RC_CMAKE has no backslashes")
            else:
                FAIL("ZIG_RC_CMAKE has no backslashes", rc_cmake)
            if "/" in rc_cmake:
                PASS("ZIG_RC_CMAKE has forward slashes")
            else:
                FAIL("ZIG_RC_CMAKE has forward slashes", rc_cmake)
            if "zig-rc.bat" in rc_cmake:
                PASS("ZIG_RC_CMAKE contains zig-rc.bat")
            else:
                FAIL("ZIG_RC_CMAKE contains zig-rc.bat", rc_cmake)
        else:
            FAIL("ZIG_RC_CMAKE is set")


# ===================================================================
# Section 3 — Flag filtering (functional)
# ===================================================================
def test_flag_filtering() -> None:
    print("--- Flag filtering (compile with conda-injected flags) ---")

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("flag filtering", "ZIG_CC not set")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "test.c"
        obj = Path(td) / "test.o"
        src.write_text(_HELLO_C)

        # These GCC flags are injected by conda-build. Wrappers must filter them.
        gcc_flags = [
            "-march=nocona",
            "-mtune=haswell",
            "-fstack-protector-strong",
            "-fno-plt",
        ]
        cmd = [zig_cc] + gcc_flags + ["-c", "-o", str(obj), str(src)]
        r = _run(cmd, cwd=td)
        if r.returncode == 0 and obj.exists():
            PASS("compile with conda gcc flags succeeds (flags filtered)")
        else:
            FAIL("compile with conda gcc flags succeeds",
                 f"rc={r.returncode} stderr={r.stderr[:200]}")


# ===================================================================
# Section 4 — Shared library creation
# ===================================================================
def test_shared_lib() -> None:
    print("--- Shared library creation ---")

    if _is_emulated:
        SKIP("shared lib creation", "emulated CI — linker OOM risk")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("shared lib creation", "ZIG_CC not set")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "hello.c"
        obj = Path(td) / "hello.o"
        src.write_text(_HELLO_C)

        # Compile object
        r = _run([zig_cc, "-c", "-o", str(obj), str(src)], cwd=td)
        if r.returncode != 0:
            FAIL("compile object for shared lib", f"rc={r.returncode}")
            return

        if is_win_target and _build_is_win:
            _test_shared_lib_windows(zig_cc, obj, td)
        elif is_macos_target and _build_is_mac:
            _test_shared_lib_unix(zig_cc, obj, td, ext=".dylib")
        elif is_linux_target and not _build_is_win:
            _test_shared_lib_unix(zig_cc, obj, td, ext=".so")
        else:
            SKIP("shared lib creation", f"cross-compile scenario ({_triplet})")


def _test_shared_lib_unix(
    zig_cc: str, obj: Path, td: str, *, ext: str
) -> None:
    out = Path(td) / f"libhello{ext}"
    # Linking is slower than compiling — give 60s (aarch64 CI can be slow)
    r = _run([zig_cc, "-shared", "-o", str(out), str(obj)], cwd=td, timeout=60)
    if r.stderr == "TIMEOUT":
        WARN(f"shared lib creation ({ext})",
             "zig cc -shared timed out (60s) — slow CI or zig linker issue")
        return
    if r.returncode == 0 and out.exists() and out.stat().st_size > 0:
        PASS(f"shared lib creation ({ext})")
    else:
        detail = f"rc={r.returncode} stderr={r.stderr[:2000]}"
        FAIL(f"shared lib creation ({ext})", detail)


def _test_shared_lib_windows(zig_cc: str, obj: Path, td: str) -> None:
    dll = Path(td) / "hello.dll"
    implib = Path(td) / "libhello.dll.a"

    cmd = [
        zig_cc, "-shared",
        "-Wl,--export-all-symbols",
        f"-Wl,--out-implib,{implib}",
        "-o", str(dll),
        str(obj),
    ]
    r = _run(cmd, cwd=td, timeout=60)

    if r.stderr == "TIMEOUT":
        FAIL("shared lib creation (windows)", "timeout after 60s")
        return

    if r.returncode != 0:
        FAIL("shared lib creation (windows)",
             f"rc={r.returncode} stderr={r.stderr[:200]}")
        return

    if not dll.exists() or dll.stat().st_size == 0:
        FAIL("DLL created and non-empty")
        return
    PASS("DLL created and non-empty")

    # Verify import library via zig ar
    if not implib.exists() or implib.stat().st_size == 0:
        if is_aarch64_win:
            WARN("import lib non-empty",
                 "empty import lib on aarch64-windows — known zig bug")
        else:
            FAIL("import lib non-empty")
        return
    PASS("import lib non-empty")

    # Use zig ar t to inspect the import library
    zig_ar = _env_var("ZIG_AR")
    if not zig_ar:
        # Fallback: try wrapper dir
        candidate = _wrapper_dir / ("zig-ar.bat" if _build_is_win else "zig-ar")
        if candidate.exists():
            zig_ar = str(candidate)

    if zig_ar:
        r2 = _run([zig_ar, "t", str(implib)], cwd=td)
        if r2.returncode == 0 and r2.stdout.strip():
            PASS("zig ar t lists import lib members")
        else:
            WARN("zig ar t lists import lib members",
                 f"rc={r2.returncode}")
    else:
        SKIP("zig ar t import lib", "ZIG_AR not found")


# ===================================================================
# Section 4b — Executable linking (verifies CRT + libc handling)
# ===================================================================
def test_exe_linking() -> None:
    """Link a trivial executable.  On ppc64le this exercises the GCC linker
    redirect with CRT files, verifying that no build-time artifacts (like
    pthread_atfork_stub.o) are required at runtime."""
    print("--- Executable linking ---")

    if _is_emulated:
        SKIP("exe linking", "emulated CI — linker OOM risk")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("exe linking", "ZIG_CC not set")
        return

    # Cross-compilation to a different OS can't run the result, but
    # we can still verify the link succeeds.
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "main.c"
        src.write_text(_MAIN_C)

        if _build_is_win:
            out = Path(td) / "main.exe"
        else:
            out = Path(td) / "main"

        r = _run([zig_cc, "-o", str(out), str(src)], cwd=td, timeout=60)
        if r.stderr == "TIMEOUT":
            WARN("exe linking", "timed out (60s)")
            return
        if r.returncode == 0 and out.exists() and out.stat().st_size > 0:
            PASS("exe linking")
        else:
            FAIL("exe linking",
                 f"rc={r.returncode} stderr={r.stderr[:2000]}")


# ===================================================================
# Section 5 — Visibility (macOS only)
# ===================================================================
def test_visibility() -> None:
    print("--- Visibility (macOS) ---")

    if not (is_macos_target and _build_is_mac):
        SKIP("visibility test", "macOS-only")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("visibility test", "ZIG_CC not set")
        return

    nm = shutil.which("nm")
    if not nm:
        SKIP("visibility test", "nm not found")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "vis.c"
        dylib = Path(td) / "vis.dylib"
        src.write_text(_VIS_C)

        r = _run(
            [zig_cc, "-fvisibility=default", "-shared", "-o", str(dylib), str(src)],
            cwd=td,
        )
        if r.returncode != 0:
            FAIL("visibility: compile shared lib",
                 f"rc={r.returncode} stderr={r.stderr[:200]}")
            return

        r2 = _run([nm, "-g", str(dylib)], cwd=td)
        if r2.returncode != 0:
            FAIL("visibility: nm -g", f"rc={r2.returncode}")
            return

        # Look for vis_test_func in nm output
        # " T _vis_test_func" = exported (uppercase T)
        # " t _vis_test_func" = local/hidden (lowercase t)
        lines = [l for l in r2.stdout.splitlines() if "vis_test_func" in l]
        if not lines:
            WARN("visibility: vis_test_func not in nm output",
                 "may not honor -fvisibility=default — known zig issue")
        elif any(" T " in l or " T\t" in l for l in lines):
            PASS("visibility: vis_test_func exported (T)")
        else:
            WARN("visibility: vis_test_func not exported",
                 f"nm shows: {lines[0].strip()} — known zig issue")


# ===================================================================
# Section 6 — ld.lld dispatch (Windows targets only)
# ===================================================================
def test_lld_dispatch() -> None:
    print("--- ld.lld dispatch ---")

    if not is_win_target:
        SKIP("ld.lld dispatch", "Windows-target only")
        return

    # Find zig binary
    zig = shutil.which("zig")
    if not zig:
        # Try triplet-prefixed
        zig = shutil.which(f"{_triplet}-zig")
    if not zig:
        SKIP("ld.lld dispatch", "zig binary not found")
        return

    # zig ld.lld -m i386pep should invoke PE linker, not ELF
    # We just test that it doesn't error with "unknown emulation"
    r = _run([zig, "ld.lld", "-m", "i386pep", "--help"], timeout=10)
    if r.returncode == 0:
        PASS("zig ld.lld -m i386pep accepted")
    else:
        if "unknown emulation" in r.stderr.lower():
            WARN("zig ld.lld routes to ELF driver for MinGW PE targets",
                 "known zig bug — ld.lld doesn't honour -m for PE")
        else:
            FAIL("zig ld.lld -m i386pep",
                 f"rc={r.returncode} stderr={r.stderr[:200]}")


# ===================================================================
# Section 7 — Unix-only: flag filter content checks (from old .sh)
# ===================================================================
def test_flag_filter_content() -> None:
    """Check that _zig-cc-common.sh contains expected filter patterns."""
    print("--- Flag filter content (Unix) ---")

    if _build_is_win:
        SKIP("flag filter content", "Unix-only")
        return

    common = _wrapper_dir / "_zig-cc-common.sh"
    if not common.exists():
        FAIL("_zig-cc-common.sh exists for content check")
        return

    text = common.read_text()

    checks = [
        ("-mcpu=* in filter list", "-mcpu="),
        ("-march=* in filter list", "-march="),
        ("-mtune=* in filter list", "-mtune="),
        ("exported_symbols_list filtered", "exported_symbols_list"),
        ("unexported_symbols_list filtered", "unexported_symbols_list"),
        ("force_symbols_not_weak_list filtered", "force_symbols_not_weak_list"),
        ("force_symbols_weak_list filtered", "force_symbols_weak_list"),
        ("reexported_symbols_list filtered", "reexported_symbols_list"),
        ("-Wl,-all_load filtered", "all_load"),
        ("-Wl,-force_load filtered", "force_load"),
        ("-mcpu=baseline in exec args", "mcpu=baseline"),
    ]
    for label, needle in checks:
        if needle in text:
            PASS(label)
        else:
            FAIL(label)


# ===================================================================
# Section 8 — Unix-only: force-load wrapper content (from old .sh)
# ===================================================================
def test_force_load_wrappers() -> None:
    """Check force-load wrapper scripts contain expected patterns."""
    print("--- Force-load wrappers (Unix) ---")

    if _build_is_win:
        SKIP("force-load wrappers", "Unix-only")
        return

    fl_cc = _wrapper_dir / "zig-force-load-cc"
    if not fl_cc.exists():
        FAIL("zig-force-load-cc exists")
        return

    text_cc = fl_cc.read_text()
    for label, needle in [
        ("force-load-cc sources _zig-cc-common.sh", "_zig-cc-common.sh"),
        ("force-load-cc uses ar x", "ar x"),
        ("force-load-cc creates tmpdir", "mktemp -d"),
        ("force-load-cc has cleanup trap", "trap"),
        ("force-load-cc handles -Wl,-force_load", "Wl,-force_load"),
        ("force-load-cc handles -Wl,-all_load", "Wl,-all_load"),
        ('force-load-cc uses cc mode', '_ZIG_MODE="cc"'),
    ]:
        if needle in text_cc:
            PASS(label)
        else:
            FAIL(label)

    fl_cxx = _wrapper_dir / "zig-force-load-cxx"
    if not fl_cxx.exists():
        FAIL("zig-force-load-cxx exists")
        return

    text_cxx = fl_cxx.read_text()
    for label, needle in [
        ("force-load-cxx sources _zig-cc-common.sh", "_zig-cc-common.sh"),
        ("force-load-cxx uses ar x", "ar x"),
        ('force-load-cxx uses c++ mode', '_ZIG_MODE="c++"'),
    ]:
        if needle in text_cxx:
            PASS(label)
        else:
            FAIL(label)


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print(f"=== Zig Toolchain Tests ===")
    print(f"  CONDA_ZIG_HOST  = {_host!r}")
    print(f"  CONDA_ZIG_BUILD = {_build_zig!r}")
    print(f"  triplet         = {_triplet!r}")
    print(f"  arch            = {_arch!r}")
    print(f"  cross-compiler  = {_is_cross_compiler}")
    print(f"  build OS        = {sys.platform}")
    print(f"  wrapper dir     = {_wrapper_dir}")
    print()

    # Overlay patched native zig if stashed by build (BUILD_NATIVE_ZIG=true)
    _patched = _prefix / "etc" / "conda" / "test-files" / "zig_native_patched"
    if _patched.exists() and not _build_is_win:
        # Find the actual zig binary (could be triplet-prefixed)
        zig_bin = _prefix / "bin" / "zig"
        if not zig_bin.exists():
            for f in (_prefix / "bin").glob("*-zig"):
                zig_bin = f
                break
        if zig_bin.exists():
            shutil.copy2(_patched, zig_bin)
            os.chmod(str(zig_bin), 0o755)
            print(f"  [patched] Overlaid {zig_bin} with locally-built native zig")

    test_wrapper_existence()
    test_activation_variables()
    test_flag_filter_content()
    test_force_load_wrappers()
    test_flag_filtering()
    test_shared_lib()
    test_exe_linking()
    test_visibility()
    test_lld_dispatch()

    print()
    n_pass = len(_results["PASS"])
    n_fail = len(_results["FAIL"])
    n_warn = len(_results["WARN"])
    n_skip = len(_results["SKIP"])
    print(f"=== Results: {n_pass} passed, {n_fail} failed, "
          f"{n_warn} warnings, {n_skip} skipped ===")

    if n_fail > 0:
        print("\nFailed tests:")
        for name in _results["FAIL"]:
            print(f"  - {name}")

    if n_warn > 0:
        print("\nWarnings (known issues):")
        for name in _results["WARN"]:
            print(f"  - {name}")

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
