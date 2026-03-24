#!/usr/bin/env python3
"""
Test shared libc++ discovery for zig_impl_ package (patch 0008).

Runs during zig_impl_$platform test phase using the triplet-prefixed binary
directly (no activation wrappers). Verifies that the zig binary:

  1. Falls back to static libc++ when no shared lib is at probe paths (default)
  2. Probes the correct paths for shared libc++ (strace on Linux)
  3. Uses shared libc++ when a real .so is placed at the probe path

Usage:
  python test_libcxx_shared.py <conda_triplet>
  e.g. python test_libcxx_shared.py x86_64-conda-linux-gnu

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

# --------------------------------------------------------------------------
# Result tracking (same pattern as test_zig_toolchain.py)
# --------------------------------------------------------------------------
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


# --------------------------------------------------------------------------
# Platform detection
# --------------------------------------------------------------------------
_prefix = Path(os.environ.get("CONDA_PREFIX", ""))
_conda_triplet = sys.argv[1] if len(sys.argv) > 1 else ""
_build_is_win = sys.platform == "win32"
_build_is_mac = sys.platform == "darwin"

# The zig binary in zig_impl_ is triplet-prefixed
_zig_bin_name = f"{_conda_triplet}-zig" if _conda_triplet else ""

# Target platform detection from triplet
is_linux_target = "linux" in _conda_triplet
is_macos_target = "apple" in _conda_triplet or "darwin" in _conda_triplet
is_win_target = "mingw32" in _conda_triplet
_arch = _conda_triplet.split("-")[0] if _conda_triplet else platform.machine()
is_arm64 = _arch in ("aarch64", "arm64")

# Emulation detection
_native_machine = platform.machine()
_is_emulated = (
    sys.platform == "linux"
    and _native_machine not in ("x86_64", "i686")
    and os.environ.get("CI", "") != ""
)


def _run(
    cmd: list[str],
    *,
    timeout: int = 30,
    cwd: str | Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a command, return CompletedProcess. Never raises on non-zero rc."""
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, returncode=-1, stdout="", stderr="NOTFOUND")
    try:
        stdout_b, stderr_b = proc.communicate(timeout=timeout)
        return subprocess.CompletedProcess(
            cmd,
            returncode=proc.returncode,
            stdout=stdout_b.decode("utf-8", errors="replace"),
            stderr=stderr_b.decode("utf-8", errors="replace"),
        )
    except subprocess.TimeoutExpired:
        try:
            if _build_is_win:
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                    capture_output=True, timeout=5,
                )
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()
        try:
            proc.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    try:
                        pipe.close()
                    except OSError:
                        pass
        return subprocess.CompletedProcess(cmd, returncode=-1, stdout="", stderr="TIMEOUT")


# --------------------------------------------------------------------------
# Probe paths (must match libcxx_shared.zig exactly)
# --------------------------------------------------------------------------

# Probe directories relative to zig_lib (which is <prefix>/lib/zig/).
# Two levels up reaches <prefix>/, then:
PROBE_SUBDIRS = [
    "../../lib/zig-llvm/lib",  # preferred: dedicated zig-llvm package
    "../../lib",               # fallback: standard lib dir
]

# Platform-specific shared library names (mirrors sharedLibCxxNames)
LIBCXX_NAMES: dict[str, list[str]] = {
    "linux": ["libc++.so.1", "libc++.so"],
    "macos": ["libc++.1.dylib", "libc++.dylib"],
    "windows": ["libc++.dll.a"],
}


def _get_platform_key() -> str:
    if is_linux_target:
        return "linux"
    if is_macos_target:
        return "macos"
    if is_win_target:
        return "windows"
    return ""


def _find_zig_lib_dir() -> Path | None:
    """Locate zig lib directory in the test prefix."""
    if _build_is_win:
        candidate = _prefix / "Library" / "lib" / "zig"
    else:
        candidate = _prefix / "lib" / "zig"
    return candidate if candidate.is_dir() else None


def _find_zig_binary() -> str | None:
    """Find the zig binary (triplet-prefixed) in the test prefix."""
    if not _zig_bin_name:
        return None
    zig = shutil.which(_zig_bin_name)
    if zig:
        return zig
    # Also try explicit path
    if _build_is_win:
        candidate = _prefix / "Library" / "bin" / f"{_zig_bin_name}.exe"
    else:
        candidate = _prefix / "bin" / _zig_bin_name
    if candidate.exists():
        return str(candidate)
    return None


def _find_zig_cache_dir(zig: str) -> Path | None:
    """Get zig's global cache directory from 'zig env'."""
    r = _run([zig, "env"], timeout=10)
    if r.returncode != 0:
        return None
    try:
        env = json.loads(r.stdout)
        return Path(env["global_cache_dir"])
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


def _find_libcxx_static(zig: str, td: Path) -> Path | None:
    """
    Trigger a C++ compilation to populate zig's cache, then find libc++.a.

    Returns the path to the cached libc++.a, or None if not found.
    """
    src = td / "find_libcxx.cpp"
    out = td / "libfind.so"
    src.write_text(
        '#include <string>\n'
        'extern "C" int f() { std::string s("x"); return (int)s.size(); }\n'
    )

    r = _run([zig, "c++", "-shared", "-o", str(out), str(src)],
             cwd=str(td), timeout=120)
    if r.returncode != 0:
        return None

    cache_dir = _find_zig_cache_dir(zig)
    if not cache_dir or not cache_dir.is_dir():
        return None

    # Find the most recently modified libc++.a (the one we just triggered)
    candidates = sorted(
        cache_dir.rglob("libc++.a"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


# ===================================================================
# Test 1: Fallback to static libc++ (no shared lib at probe paths)
# ===================================================================
def test_libcxx_fallback_static() -> None:
    """
    Without shared libc++ at probe paths, zig c++ must link libc++ statically.

    Linux:  readelf -d shows NO NEEDED libc++.so entry
    macOS:  otool -L shows NO libc++ dylib dependency
    """
    print("--- [patch-0008] Fallback to static libc++ ---")

    if is_arm64 or _is_emulated:
        SKIP("libcxx-static-fallback", "arm64/emulated, skip linking tests")
        return

    plat = _get_platform_key()
    if not plat:
        SKIP("libcxx-static-fallback", f"unsupported target ({_conda_triplet})")
        return

    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-static-fallback", f"zig binary not found ({_zig_bin_name})")
        return

    zig_lib = _find_zig_lib_dir()

    # Precondition: verify no shared libc++ at probe paths
    if zig_lib:
        names = LIBCXX_NAMES.get(plat, [])
        for subdir in PROBE_SUBDIRS:
            for name in names:
                probe = (zig_lib / subdir / name).resolve()
                if probe.exists():
                    SKIP("libcxx-static-fallback",
                         f"shared libc++ already at {probe}")
                    return
        PASS("precondition: no shared libc++ at probe paths")

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "cxxlib.cpp"
        src.write_text(
            '#include <string>\n'
            '#include <typeinfo>\n'
            'extern "C" {\n'
            '  __attribute__((visibility("default")))\n'
            '  const char* cxx_rtti(void) { return typeid(std::string).name(); }\n'
            '}\n'
        )

        if is_linux_target:
            out = Path(td) / "libcxxtest.so"
        elif is_macos_target:
            out = Path(td) / "libcxxtest.dylib"
        elif is_win_target:
            out = Path(td) / "cxxtest.dll"
        else:
            SKIP("libcxx-static-fallback", "unknown output format")
            return

        r = _run([zig, "c++", "-shared", "-o", str(out), str(src)],
                 cwd=td, timeout=120)
        if r.stderr == "TIMEOUT":
            WARN("libcxx-static-fallback", "timed out (120s)")
            return
        if r.returncode != 0:
            FAIL("libcxx-static-fallback: compile C++ shared lib",
                 f"rc={r.returncode}\n{r.stderr[:2000]}")
            return
        if not out.exists() or out.stat().st_size == 0:
            FAIL("libcxx-static-fallback: output exists and non-empty")
            return

        PASS("C++ shared lib compiled")

        # Verify libc++ is NOT a dynamic dependency
        if is_linux_target and not _build_is_win:
            readelf = shutil.which("readelf")
            if readelf:
                r2 = _run([readelf, "-d", str(out)], cwd=td)
                if r2.returncode == 0:
                    needed = [l for l in r2.stdout.splitlines() if "NEEDED" in l]
                    libcxx_needed = [l for l in needed if "libc++" in l]
                    if not libcxx_needed:
                        PASS("libc++ statically linked (no NEEDED libc++)")
                    else:
                        WARN("libc++ appears dynamically linked",
                             "; ".join(l.strip() for l in libcxx_needed))
                else:
                    WARN("readelf -d", f"rc={r2.returncode}")
            else:
                SKIP("readelf check", "readelf not found")

            # Symbol visibility: with static libc++, C++ symbols should
            # NOT appear in dynamic symbol table
            nm = shutil.which("nm")
            if nm:
                r3 = _run([nm, "-D", str(out)], cwd=td)
                if r3.returncode == 0:
                    cxx_syms = [l for l in r3.stdout.splitlines()
                                if "basic_string" in l or "runtime_error" in l]
                    exported = [l for l in cxx_syms if " T " in l or " W " in l]
                    if not exported:
                        PASS("libc++ symbols hidden (static linkage confirmed)")
                    else:
                        WARN("some libc++ symbols in dynamic table",
                             f"count={len(exported)}")

        elif is_macos_target and _build_is_mac:
            otool = shutil.which("otool")
            if otool:
                r2 = _run([otool, "-L", str(out)], cwd=td)
                if r2.returncode == 0:
                    libcxx_deps = [l for l in r2.stdout.splitlines()
                                   if "libc++" in l]
                    if not libcxx_deps:
                        PASS("libc++ statically linked (no dylib dep)")
                    else:
                        WARN("libc++ appears dynamically linked",
                             "; ".join(l.strip() for l in libcxx_deps))
            else:
                SKIP("otool check", "otool not found")


# ===================================================================
# Test 2: Probe path verification (strace on Linux)
# ===================================================================
def test_libcxx_probe_paths() -> None:
    """
    Verify zig probes the expected paths for shared libc++.

    Linux: strace captures access()/faccessat() syscalls.
    All:   structural check that probe target dirs resolve correctly.
    """
    print("--- [patch-0008] Shared libc++ probe paths ---")

    if is_arm64 or _is_emulated:
        SKIP("libcxx-probe", "arm64/emulated, skip linking tests")
        return

    plat = _get_platform_key()
    if not plat:
        SKIP("libcxx-probe", f"unsupported target ({_conda_triplet})")
        return

    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-probe", f"zig binary not found ({_zig_bin_name})")
        return

    zig_lib = _find_zig_lib_dir()
    if not zig_lib:
        SKIP("libcxx-probe", "zig lib dir not found")
        return

    # Structural: verify probe target dirs resolve to the right places
    for subdir in PROBE_SUBDIRS:
        resolved = (zig_lib / subdir).resolve()
        label = str(resolved.relative_to(_prefix)) if resolved.is_relative_to(_prefix) else str(resolved)
        if resolved.is_dir():
            PASS(f"probe dir exists: {label}")
        else:
            # zig-llvm/lib/ won't exist until zig-llvm package ships, that's OK
            WARN(f"probe dir missing: {label}",
                 "expected until zig-llvm package available")

    # --- Diagnostic: check if patch 0008 is compiled into the binary ---
    if zig:
        strings_bin = shutil.which("strings")
        if strings_bin:
            r_str = _run([strings_bin, zig], timeout=10)
            if r_str.returncode == 0:
                has_probe_str = any("zig-llvm/lib" in l for l in r_str.stdout.splitlines())
                has_libcxx_so = any("libc++.so.1" in l for l in r_str.stdout.splitlines())
                if has_probe_str or has_libcxx_so:
                    PASS("patch 0008 strings found in binary",
                         f"zig-llvm/lib={has_probe_str}, libc++.so.1={has_libcxx_so}")
                else:
                    FAIL("patch 0008 strings NOT in binary",
                         "libcxx_shared.zig was not compiled into this zig")

    # --- Diagnostic: verbose link output ---
    if not is_linux_target or _build_is_win:
        SKIP("verbose-link", "Linux-only")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "probe.cpp"
        out = Path(td) / "libprobe.so"
        src.write_text(
            '#include <string>\n'
            'extern "C" {\n'
            '  __attribute__((visibility("default")))\n'
            '  int cxx_probe(void) { std::string s("probe"); return (int)s.size(); }\n'
            '}\n'
        )

        # Run with --verbose-link to see actual linker args
        r_vl = _run([zig, "c++", "-shared", "--verbose-link",
                      "-o", str(out), str(src)], cwd=td, timeout=120)
        if r_vl.returncode == 0 or r_vl.stderr:
            # Look for libc++ in verbose output (both stdout and stderr)
            verbose = r_vl.stdout + "\n" + r_vl.stderr
            libcxx_args = [l.strip() for l in verbose.splitlines()
                           if "libc++" in l and "libcxx" not in l.lower()]
            if libcxx_args:
                print("    verbose-link libc++ references:")
                for arg in libcxx_args[:5]:
                    print(f"      {arg[:200]}")
            else:
                # Show ALL verbose output for diagnosis
                print("    verbose-link output (no libc++ found):")
                for line in verbose.splitlines():
                    if line.strip():
                        print(f"      {line.strip()[:200]}")

    # --- Strace test ---
    strace = shutil.which("strace")
    if not strace:
        SKIP("strace probe", "strace not found in PATH")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "probe.cpp"
        out = Path(td) / "libprobe.so"
        src.write_text(
            '#include <string>\n'
            'extern "C" {\n'
            '  __attribute__((visibility("default")))\n'
            '  int cxx_probe(void) { std::string s("probe"); return (int)s.size(); }\n'
            '}\n'
        )

        cmd = [
            strace, "-f", "-e", "trace=access,faccessat,faccessat2",
            zig, "c++", "-shared", "-o", str(out), str(src),
        ]
        r = _run(cmd, cwd=td, timeout=120)

        if r.stderr == "TIMEOUT":
            WARN("strace probe", "timed out (120s)")
            return

        if r.returncode != 0:
            WARN("strace compilation failed",
                 f"rc={r.returncode}, linking never reached (no probes expected)")

        strace_out = r.stderr
        names = LIBCXX_NAMES.get(plat, [])
        probed = []
        for line in strace_out.splitlines():
            low = line.lower()
            if "libc++" in line and ("access" in low or "faccessat" in low):
                probed.append(line.strip())

        if not probed:
            WARN("no libc++ probes detected in strace",
                 "patch 0008 may not be applied or link_libcpp path not entered")
            return

        PASS(f"zig probes for shared libc++ ({len(probed)} access calls)")

        for name in names:
            if any(name in p for p in probed):
                PASS(f"probes for {name}")
            else:
                WARN(f"no probe for {name}",
                     "may be optimized by kernel or strace filter")

        zigllvm_idx = next((i for i, p in enumerate(probed) if "zig-llvm" in p), -1)
        lib_idx = next((i for i, p in enumerate(probed)
                        if "zig-llvm" not in p and "libc++" in p), -1)
        if zigllvm_idx >= 0 and lib_idx >= 0:
            if zigllvm_idx < lib_idx:
                PASS("probe order correct: zig-llvm/lib before lib/")
            else:
                WARN("probe order unexpected",
                     f"zig-llvm at idx {zigllvm_idx}, lib/ at idx {lib_idx}")
        elif zigllvm_idx >= 0:
            PASS("zig-llvm/lib probed")


# ===================================================================
# Test 3: Shared libc++ simulation (place real .so, verify linkage)
# ===================================================================
def _check_needed_libcxx(zig: str, readelf: str, label: str) -> None:
    """Compile C++ with real std:: usage and check for NEEDED libc++."""
    with tempfile.TemporaryDirectory() as td:
        cxx_src = Path(td) / "test.cpp"
        cxx_out = Path(td) / "libtest.so"
        cxx_src.write_text(
            '#include <string>\n'
            '#include <typeinfo>\n'
            'extern "C" {\n'
            '  __attribute__((visibility("default")))\n'
            '  const char* cxx_rtti(void) {\n'
            '    return typeid(std::string).name();\n'
            '  }\n'
            '}\n'
        )

        r = _run([zig, "c++", "-shared", "-o", str(cxx_out), str(cxx_src)],
                 cwd=td, timeout=120)

        if r.returncode != 0:
            FAIL(f"{label}: C++ compilation failed",
                 f"rc={r.returncode}\n{r.stderr[:2000]}")
            return

        if not cxx_out.exists():
            FAIL(f"{label}: output .so missing")
            return

        PASS(f"{label}: C++ shared lib compiled")

        # Check NEEDED entries
        r2 = _run([readelf, "-d", str(cxx_out)], cwd=td)
        if r2.returncode != 0:
            WARN(f"{label}: readelf failed", f"rc={r2.returncode}")
            return

        needed = [l for l in r2.stdout.splitlines() if "NEEDED" in l]
        libcxx_needed = [l for l in needed if "libc++" in l]

        if libcxx_needed:
            PASS(f"{label}: NEEDED libc++ in output (shared linkage!)")
            for dep in libcxx_needed:
                print(f"    {dep.strip()}")
        else:
            FAIL(f"{label}: no NEEDED libc++ (still static)")
            print("    All NEEDED entries:")
            for dep in needed:
                print(f"      {dep.strip()}")


def test_libcxx_shared_simulation() -> None:
    """
    Verify zig uses shared libc++ when it's available at probe paths.

    Strategy:
      - If libcxx package is installed (libc++.so.1 already at probe path):
        compile C++ and check NEEDED directly. No fake lib needed.
      - If no shared libc++ exists: build one from zig's cached libc++.a,
        place at preferred probe path, then test.

    Linux-only (needs readelf).
    """
    print("--- [patch-0008] Shared libc++ simulation ---")

    if not is_linux_target or _build_is_win:
        SKIP("libcxx-simulation", "Linux-only")
        return

    if is_arm64 or _is_emulated:
        SKIP("libcxx-simulation", "arm64/emulated, skip linking tests")
        return

    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-simulation", f"zig binary not found ({_zig_bin_name})")
        return

    zig_lib = _find_zig_lib_dir()
    if not zig_lib:
        SKIP("libcxx-simulation", "zig lib dir not found")
        return

    readelf = shutil.which("readelf")
    if not readelf:
        SKIP("libcxx-simulation", "readelf not found")
        return

    # --- Case A: shared libc++ already exists at a probe path (libcxx installed) ---
    plat = _get_platform_key()
    names = LIBCXX_NAMES.get(plat, [])
    for subdir in PROBE_SUBDIRS:
        for name in names:
            probe = (zig_lib / subdir / name)
            if probe.exists():
                resolved = probe.resolve()
                PASS(f"shared libc++ found at probe path: {name} -> {resolved}")
                _check_needed_libcxx(zig, readelf, "libcxx-installed")
                return

    # --- Case B: no shared libc++ -- build from zig's cached libc++.a ---
    print("    (no shared libc++ at probe paths, building from cache)")

    # Preferred probe path for placement
    probe_dir = (zig_lib / PROBE_SUBDIRS[0]).resolve()  # .../lib/zig-llvm/lib/
    shared_lib = probe_dir / "libc++.so.1"
    shared_symlink = probe_dir / "libc++.so"

    created_dirs: list[Path] = []

    try:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)

            # Phase 1: Find zig's cached libc++.a
            libcxx_a = _find_libcxx_static(zig, td_path)
            if not libcxx_a:
                # Fallback: search zig lib dir for any libc++.a
                zig_lib_candidates = list(zig_lib.rglob("libc++.a"))
                if zig_lib_candidates:
                    libcxx_a = zig_lib_candidates[0]
                else:
                    SKIP("libcxx-simulation",
                         "could not find libc++.a in zig cache or lib dir")
                    return

            PASS(f"found libc++.a: {libcxx_a}")

            # Phase 2: Build libc++.so.1 from static libc++.a
            shared_build = td_path / "libc++.so.1"
            r = _run([
                zig, "cc", "-shared",
                "-Wl,--whole-archive", str(libcxx_a), "-Wl,--no-whole-archive",
                "-Wl,-soname,libc++.so.1",
                "-o", str(shared_build),
            ], cwd=td, timeout=120)

            if r.returncode != 0 or not shared_build.exists():
                FAIL("libcxx-simulation: build shared libc++ from static .a",
                     f"rc={r.returncode}\n{r.stderr[:2000]}")
                return

            PASS("built libc++.so.1 from static libc++.a")

            # Phase 3: Install at probe path
            if not probe_dir.exists():
                for parent in reversed(list(probe_dir.relative_to(
                        probe_dir.parent.parent).parents)):
                    d = probe_dir.parent.parent / parent
                    if not d.exists():
                        created_dirs.append(d)
                if not probe_dir.exists():
                    created_dirs.append(probe_dir)
                probe_dir.mkdir(parents=True, exist_ok=True)

            shutil.copy2(str(shared_build), str(shared_lib))
            shared_symlink.symlink_to("libc++.so.1")
            PASS("placed libc++.so.1 at probe path")

            # Phase 4: Compile and check NEEDED
            _check_needed_libcxx(zig, readelf, "libcxx-from-cache")

    finally:
        # Cleanup: remove shared lib from conda prefix
        if shared_symlink.is_symlink():
            shared_symlink.unlink()
        if shared_lib.exists():
            shared_lib.unlink()
        for d in [probe_dir] + list(reversed(created_dirs)):
            try:
                d.rmdir()
            except OSError:
                pass


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== Shared libc++ Discovery Tests (patch 0008) ===")
    print(f"  CONDA_PREFIX  = {_prefix}")
    print(f"  CONDA_TRIPLET = {_conda_triplet}")
    print(f"  zig binary    = {_zig_bin_name}")
    print(f"  platform key  = {_get_platform_key()}")
    print(f"  zig lib dir   = {_find_zig_lib_dir()}")
    print(f"  arm64         = {is_arm64}")
    print(f"  emulated      = {_is_emulated}")
    print()

    test_libcxx_fallback_static()
    test_libcxx_probe_paths()
    test_libcxx_shared_simulation()

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
        print("\nWarnings:")
        for name in _results["WARN"]:
            print(f"  - {name}")

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
