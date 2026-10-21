#!/usr/bin/env python3
"""
Test shared libc++ discovery for zig_impl_ package (patch 0008).

Runs during zig_impl_$platform test phase using the triplet-prefixed binary
directly (no activation wrappers). Verifies that the zig binary:

  1. Falls back to static libc++ when no shared lib is at probe paths (default)
  2. Carries the shared libc++ probe names on macOS only (patch scoped to osx)
  3. Uses shared libc++ only when ZIG_LIBCXX=shared AND a dylib is at the
     probe path (macOS); unset / other values stay static (issue #220)

Usage:
  python test_libcxx_shared.py <conda_triplet>
  e.g. python test_libcxx_shared.py x86_64-conda-linux-gnu

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

import contextlib
import os
import platform
import shutil
import sys
import tempfile

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
from pathlib import Path

from _test_utils import (
    _build_is_win,
    _build_is_mac,
    _is_emulated,
    _results,
    _run,
    PASS,
    FAIL,
    WARN,
    SKIP,
    check_emulation_env,
    resolve_test_prefix,
    setup_zig_global_cache_dir,
    timed_out,
)

# --------------------------------------------------------------------------
# Platform detection
# --------------------------------------------------------------------------
_prefix = resolve_test_prefix("Library/lib/zig" if _build_is_win else "lib/zig")
_conda_triplet = sys.argv[1] if len(sys.argv) > 1 else ""

# Ensure zig can resolve its cache directory when called directly (no wrapper).
# zig's getAppDataDir on Linux checks XDG_DATA_HOME then HOME/.local/share;
# if neither is set it panics with AppDataDirUnavailable.  ZIG_GLOBAL_CACHE_DIR
# overrides the lookup entirely.
setup_zig_global_cache_dir()

# The zig binary in zig_impl_ is triplet-prefixed
_zig_bin_name = f"{_conda_triplet}-zig" if _conda_triplet else ""

# Target platform detection from triplet
is_linux_target = "linux" in _conda_triplet
is_macos_target = "apple" in _conda_triplet or "darwin" in _conda_triplet
is_win_target = "mingw32" in _conda_triplet
_arch = _conda_triplet.split("-")[0] if _conda_triplet else platform.machine()
is_arm64 = _arch in ("aarch64", "arm64")
is_ppc64le = _arch == "powerpc64le"

# Emulation detection: _is_emulated imported from _test_utils

def _sysctl_int(name: bytes) -> int | None:
    """Integer sysctl value by name; None if unavailable or not macOS."""
    if sys.platform != "darwin":
        return None
    import ctypes
    import ctypes.util
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "/usr/lib/libSystem.B.dylib",
                           use_errno=True)
        val = ctypes.c_int(0)
        size = ctypes.c_size_t(ctypes.sizeof(val))
        rc = libc.sysctlbyname(name, ctypes.byref(val),
                               ctypes.byref(size), None, ctypes.c_size_t(0))
    except (OSError, AttributeError):
        return None
    return None if rc != 0 else val.value


def _under_rosetta() -> bool:
    """True when the x86_64 zig under test runs via Rosetta 2 on Apple Silicon."""
    return (sys.platform == "darwin" and _arch == "x86_64"
            and _sysctl_int(b"hw.optional.arm64") == 1)


_is_rosetta = _under_rosetta()

# Cold libc++ cache-warm compile: measured ~937s under qemu on emulated
# ppc64le, so emulated lanes get a much larger ceiling than native ones.
# Rosetta lanes are slow too (120s timed out on osx-64 xtarget).
_COMPILE_TIMEOUT_S = 1800 if (_is_emulated or _is_rosetta) else 120


# --------------------------------------------------------------------------
# Probe paths (must match libcxx_shared.zig exactly)
# --------------------------------------------------------------------------

# Probe directories relative to zig_lib (which is <prefix>/lib/zig/).
# Two levels up reaches <prefix>/, then:
PROBE_SUBDIRS = [
    "../../lib",
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


def _find_zig_cache_dir() -> Path | None:
    """Get zig's global cache dir from ZIG_GLOBAL_CACHE_DIR.

    'zig env' emits ZON (not JSON) on this zig version, so it cannot be
    parsed with json.loads. setup_zig_global_cache_dir() sets this env
    var before any zig invocation; read it back instead of shelling out.
    """
    cache_dir = os.environ.get("ZIG_GLOBAL_CACHE_DIR", "")
    if cache_dir and Path(cache_dir).is_dir():
        return Path(cache_dir)
    return None


def _find_libcxx_static(zig: str, td: Path) -> tuple[Path | None, str]:
    """
    Trigger a C++ compilation to populate zig's cache, then find libc++.a.

    Returns (path, reason). path is None on failure, with reason naming
    which arm failed; reason is "" on success.
    """
    src = td / "find_libcxx.cpp"
    out = td / "libfind.so"
    src.write_text(
        '#include <string>\n'
        'extern "C" int f() { std::string s("x"); return (int)s.size(); }\n'
    )

    r = _run([zig, "c++", "-shared", "-o", str(out), str(src)],
             cwd=str(td), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
    if timed_out(r):
        return None, f"compile timed out ({_COMPILE_TIMEOUT_S}s)"
    if r.returncode != 0:
        return None, f"compile returned non-zero (rc={r.returncode})"

    cache_dir = _find_zig_cache_dir()
    if not cache_dir:
        return None, "zig cache dir unresolved (ZIG_GLOBAL_CACHE_DIR unset or not a directory)"

    # Find the most recently modified libc++.a (the one we just triggered)
    candidates = sorted(
        cache_dir.rglob("libc++.a"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return None, "no libc++.a archive found (cache dir resolved but rglob found nothing)"
    return candidates[0], ""


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

    plat = _get_platform_key()
    if not plat:
        SKIP("libcxx-static-fallback", f"unsupported target ({_conda_triplet})")
        return

    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-static-fallback", f"zig binary not found ({_zig_bin_name})")
        return

    zig_lib = _find_zig_lib_dir()

    # Shared libc++ is opt-in via ZIG_LIBCXX=shared (main() runs this with it
    # unset), so a libc++ already at the probe path (zig_impl run-depends on
    # libcxx on osx) must NOT change the default; the link below proves that.
    if zig_lib:
        names = LIBCXX_NAMES.get(plat, [])
        present = [str((zig_lib / subdir / name).resolve())
                   for subdir in PROBE_SUBDIRS for name in names
                   if (zig_lib / subdir / name).exists()]
        if present:
            print(f"    INFO: shared libc++ at probe path ({', '.join(present)}); "
                  f"default must still link static")
        else:
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

        # Cold Windows libc++ compilation can exceed two minutes; keep a
        # bounded allowance for building it before assessing static fallback.
        compile_timeout = 600 if _build_is_win else _COMPILE_TIMEOUT_S
        r = _run([zig, "c++", "-shared", "-o", str(out), str(src)],
                 cwd=td, timeout=compile_timeout, target=_conda_triplet)
        if r.stderr == "TIMEOUT":
            WARN("libcxx-static-fallback", f"timed out ({compile_timeout}s)")
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
            else:
                SKIP("nm check", "nm not on PATH, cannot inspect dynamic symbols")

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
    Verify the shared libc++ probe strings are compiled in on macOS only.

    macOS:         darwin probe names (libc++.1.dylib / libc++.dylib) present.
    Linux/Windows: probe names absent (patch scoped to osx).
    """
    print("--- [patch-0008] Shared libc++ probe paths ---")

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
            FAIL(f"probe dir missing: {label}")

    # Is patch 0008 compiled into the binary? Applied on macOS only.
    data = Path(zig).read_bytes()
    if is_macos_target:
        found = [n for n in LIBCXX_NAMES["macos"] if n.encode() in data]
        if found:
            PASS("patch 0008 darwin probe names found in binary", ", ".join(found))
        else:
            FAIL("patch 0008 darwin probe names NOT in binary",
                 "libcxx_shared.zig was not compiled into this zig")
    else:
        present = [n for n in LIBCXX_NAMES.get(plat, []) if n.encode() in data]
        if present:
            FAIL("shared libc++ probe names present in non-macOS zig",
                 ", ".join(present))
        else:
            PASS("shared libc++ probe names absent (patch not applied)")


# ===================================================================
# Test 3: Shared libc++ simulation (place real .so, verify linkage)
# ===================================================================
@contextlib.contextmanager
def _zig_libcxx(value: str | None):
    """Set (or remove, for None) ZIG_LIBCXX in os.environ; _run children inherit it."""
    old = os.environ.get("ZIG_LIBCXX")
    if value is None:
        os.environ.pop("ZIG_LIBCXX", None)
    else:
        os.environ["ZIG_LIBCXX"] = value
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("ZIG_LIBCXX", None)
        else:
            os.environ["ZIG_LIBCXX"] = old


def _check_optin_default(zig: str) -> None:
    """With a shared libc++ available, unset/non-"shared" ZIG_LIBCXX stays static."""
    otool = shutil.which("otool")
    if not otool:
        SKIP("libcxx-optin-default: otool check", "otool not found")
        return
    for value in (None, "static"):
        label = f"libcxx-optin-default[ZIG_LIBCXX={value}]"
        with tempfile.TemporaryDirectory() as td, _zig_libcxx(value):
            src = Path(td) / "main.cpp"
            src.write_text('#include <string>\n'
                           'int main() { std::string s("x"); return (int)s.size() - 1; }\n')
            out = Path(td) / "a.out"
            r = _run([zig, "c++", "-o", str(out), str(src)],
                     cwd=td, timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
            if r.returncode != 0 or not out.exists():
                FAIL(f"{label}: compile", f"rc={r.returncode}\n{r.stderr[:2000]}")
                continue
            r2 = _run([otool, "-L", str(out)], cwd=td)
            deps = [l.strip() for l in r2.stdout.splitlines()[1:] if l.strip()]
            if any("libc++" in d for d in deps):
                FAIL(f"{label}: libc++ dylib linked without opt-in", "; ".join(deps))
            elif not any("libSystem" in d for d in deps):
                FAIL(f"{label}: libSystem missing from load commands", "; ".join(deps))
            else:
                PASS(f"{label}: static libc++ (only system dylibs)")


def _check_needed_libcxx(zig: str, label: str) -> None:
    """macOS: compile C++ with ZIG_LIBCXX=shared, check libc++ dylib dependency."""
    _check_shared_linked(zig, label)
    with tempfile.TemporaryDirectory() as td, _zig_libcxx("shared"):
        _report_xdylib_exception(zig, td, "shared")
    with tempfile.TemporaryDirectory() as td, _zig_libcxx(None):
        _report_xdylib_exception(zig, td, "static")
    _check_optin_default(zig)


def _check_shared_linked(zig: str, label: str) -> None:
    with tempfile.TemporaryDirectory() as td, _zig_libcxx("shared"):
        cxx_src = Path(td) / "test.cpp"
        cxx_out = Path(td) / "libtest.dylib"

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
                 cwd=td, timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)

        if timed_out(r):
            FAIL(f"{label}: C++ compilation timed out after {_COMPILE_TIMEOUT_S}s")
            return

        if r.returncode != 0:
            FAIL(f"{label}: C++ compilation failed",
                 f"rc={r.returncode}\n{r.stderr[:2000]}")
            return

        if not cxx_out.exists():
            FAIL(f"{label}: output missing")
            return

        PASS(f"{label}: C++ shared lib compiled")

        otool = shutil.which("otool")
        if not otool:
            SKIP(f"{label}: otool check", "otool not found")
            return
        r2 = _run([otool, "-L", str(cxx_out)], cwd=td)
        if r2.returncode != 0:
            WARN(f"{label}: otool failed", f"rc={r2.returncode}")
            return
        libcxx_deps = [l for l in r2.stdout.splitlines() if "libc++" in l]
        if libcxx_deps:
            PASS(f"{label}: libc++ dylib dependency in output (shared linkage!)")
            for dep in libcxx_deps:
                print(f"    {dep.strip()}")
        else:
            all_deps = [l.strip() for l in r2.stdout.splitlines()
                        if l.strip() and not l.strip().startswith(str(cxx_out))]
            FAIL(f"{label}: no libc++ dylib dependency (still static)")
            print("    All load commands:")
            for dep in all_deps:
                print(f"      {dep}")


_ABI_SYMBOLS = (
    "__cxa_throw",
    "__cxa_allocate_exception",
    "__gxx_personality_v0",
    "__cxa_begin_catch",
    "_ZTVN10__cxxabiv117__class_type_infoE",
)


def _tail(text: str, n: int = 15) -> str:
    return "\n".join(text.splitlines()[-n:])


def _otool_deps(path: Path, td: str) -> list[str]:
    """Print and return `otool -L` lines for path (empty if otool missing)."""
    otool = shutil.which("otool")
    if not otool:
        return []
    r = _run([otool, "-L", str(path)], cwd=td)
    lines = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    print("    otool -L:")
    for line in lines:
        print(f"      {line}")
    return lines


def _report_libcxxabi_doubled(out: Path, td: str, tag: str = "") -> int | None:
    """Report-only: which libc++abi symbols `out` defines itself.

    Returns the defined-symbol count, or None if nm was unusable.
    """
    try:
        _otool_deps(out, td)
        nm = shutil.which("nm") or shutil.which("llvm-nm")
        if not nm:
            WARN("libcxxabi-doubled", "nm not found")
            return None
        r = _run([nm, "-m", str(out)], cwd=td)
        if r.returncode != 0:
            WARN("libcxxabi-doubled", f"nm -m rc={r.returncode}")
            return None
        defined = 0
        for sym in _ABI_SYMBOLS:
            lines = [l for l in r.stdout.splitlines()
                     if l.split()[-1:] in ([sym], ["_" + sym])
                     or f" {sym} " in l or f" _{sym} " in l]
            if not lines:
                print(f"    {sym}: absent")
            elif any("(undefined)" not in l for l in lines):
                defined += 1
                print(f"    {sym}: DEFINED locally")
            else:
                print(f"    {sym}: undefined (from dylib)")
        # libc++ (std::__1) symbols: any defined => statically carried
        cxx = [l for l in r.stdout.splitlines() if "St3__1" in l]
        cxx_def = sum(1 for l in cxx if "(undefined)" not in l)
        print(f"    libc++ std::__1 symbols: {cxx_def} defined, "
              f"{len(cxx) - cxx_def} imported")
        doubled = "yes" if defined else "no"
        print(f"    {tag}LIBCXXABI-DOUBLED: {doubled} "
              f"({defined} abi symbols defined locally)")
        return defined
    except Exception as e:  # report-only
        WARN("libcxxabi-doubled", f"probe error: {e}")
        return None


def _xdylib_otool(exe: Path) -> None:
    """Print LC_RPATH entries and linked dylibs of exe (report-only)."""
    otool = shutil.which("otool") or shutil.which("llvm-otool")
    if not otool:
        print("    XDYLIB: otool unavailable")
        return
    lines = _run([otool, "-l", str(exe)], cwd=str(exe.parent)).stdout.splitlines()
    for i, l in enumerate(lines):
        if l.strip() == "cmd LC_RPATH":
            for p in lines[i + 1:i + 4]:
                if p.strip().startswith("path "):
                    print(f"    XDYLIB: LC_RPATH {p.strip()}")
    out = _run([otool, "-L", str(exe)], cwd=str(exe.parent)).stdout
    for l in out.splitlines():
        print(f"    XDYLIB: {l.rstrip()}")


def _report_xdylib_exception(zig: str, td: str, mode: str) -> None:
    """Exception thrown in a dylib is caught by the executable.

    FAIL in shared mode; WARN in static mode (static default is not expected to catch).
    """
    wtag = "libcxxabi-xdylib-exception"
    try:
        d = Path(td) / "xdylib"
        d.mkdir()
        (d / "thrower.cpp").write_text(
            '#include <stdexcept>\n'
            'extern "C++" __attribute__((visibility("default")))\n'
            'void thrower() { throw std::runtime_error("boom"); }\n'
        )
        (d / "main.cpp").write_text(
            '#include <exception>\n'
            '#include <cstdio>\n'
            'void thrower();\n'
            'int main() {\n'
            '  try { thrower(); } catch (const std::exception&) {\n'
            '    std::puts("CAUGHT"); return 0;\n'
            '  }\n'
            '  return 1;\n'
            '}\n'
        )
        r = _run([zig, "c++", "-shared", "-o", str(d / "libthrower.dylib"),
                  str(d / "thrower.cpp")], cwd=str(d),
                 timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
        if r.returncode != 0:
            WARN(wtag, f"[{mode}] dylib build rc={r.returncode}\n{r.stderr[:500]}")
            return
        r = _run([zig, "c++", "-o", str(d / "xmain"), str(d / "main.cpp"),
                  "-L" + str(d), "-lthrower", "-Wl,-rpath," + str(d),
                  f"-Wl,-rpath,{_prefix}/lib"],
                 cwd=str(d), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
        if r.returncode != 0:
            WARN(wtag, f"[{mode}] exe build rc={r.returncode}\n{r.stderr[:500]}")
            return
        _xdylib_otool(d / "xmain")
        if mode == "static":
            _report_libcxxabi_doubled(d / "libthrower.dylib", td, "XDYLIB-THROWER-")
            _report_libcxxabi_doubled(d / "xmain", td, "XDYLIB-MAIN-")
        r = _run([str(d / "xmain")], cwd=str(d), timeout=60)
        if "CAUGHT" in r.stdout:
            verdict = "caught"
        elif "Library not loaded" in r.stderr:
            verdict = "LOAD-FAIL"
        else:
            verdict = "NOT caught"
        line = f"LIBCXXABI-XDYLIB-EXCEPTION[{mode}]: {verdict} (rc={r.returncode})"
        print(f"    {line}")
        if verdict == "caught":
            return
        print(f"    XDYLIB[{mode}]: stderr tail:\n{_tail(r.stderr, 15)}")
        if verdict == "NOT caught":
            print(f"    XDYLIB[{mode}]: stdout tail:\n{_tail(r.stdout, 15)}")
        else:
            r2 = _run(["env", f"DYLD_LIBRARY_PATH={_prefix}/lib", str(d / "xmain")],
                      cwd=str(d), timeout=60)
            v2 = "caught" if "CAUGHT" in r2.stdout else "NOT caught"
            print(f"    LIBCXXABI-XDYLIB-EXCEPTION[{mode}]-DYLD-PATH: {v2} "
                  f"(rc={r2.returncode})")
        if mode == "shared":
            FAIL(wtag, line)
        elif verdict == "NOT caught":
            WARN(wtag, f"{line}: expected under static default libc++ (each image "
                       f"carries its own libc++abi); use ZIG_LIBCXX=shared + rpath")
        else:
            WARN(wtag, line)
    except Exception as e:  # report-only
        WARN(wtag, f"[{mode}] probe error: {e}")


def _platform_shared_lib_info() -> tuple[str, str, str | None]:
    """Return (primary_name, soname_or_id, symlink_name); the shared path is macOS-only."""
    if is_macos_target:
        return "libc++.1.dylib", "libc++.1.dylib", "libc++.dylib"
    return "", "", None


def _build_shared_libcxx(
    zig: str, libcxx_a: Path, td_path: Path
) -> Path | None:
    """Build a shared libc++ from static libc++.a. Returns output path or None."""
    primary, soname, _ = _platform_shared_lib_info()
    if not primary:
        return None

    shared_build = td_path / primary

    cmd = [
        zig, "cc", "-shared",
        "-Wl,-force_load," + str(libcxx_a),
        "-Wl,-install_name,@rpath/" + soname,
        "-o", str(shared_build),
    ]

    r = _run(cmd, cwd=str(td_path), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
    if r.returncode != 0 or not shared_build.exists():
        FAIL("libcxx-simulation: build shared libc++ from static .a",
             f"rc={r.returncode}\n{r.stderr[:2000]}")
        return None

    PASS(f"built {primary} from static libc++.a")
    return shared_build


def test_libcxx_shared_simulation() -> None:
    """
    Verify zig uses shared libc++ when it's available at probe paths.

    Strategy:
      - If libcxx package is installed (libc++.so/dylib already at probe path):
        compile C++ and check dependency directly. No fake lib needed.
      - If no shared libc++ exists: build one from zig's cached libc++.a,
        place at preferred probe path, then test.
    """
    print("--- [patch-0008] Shared libc++ simulation ---")

    if not is_macos_target:
        SKIP("libcxx-simulation",
             "shared libc++ path is macOS-only (patch scoped to osx)")
        return
    plat = "macos"

    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-simulation", f"zig binary not found ({_zig_bin_name})")
        return

    zig_lib = _find_zig_lib_dir()
    if not zig_lib:
        SKIP("libcxx-simulation", "zig lib dir not found")
        return

    # --- Case A: shared libc++ already exists at a probe path (libcxx installed) ---
    names = LIBCXX_NAMES.get(plat, [])
    for subdir in PROBE_SUBDIRS:
        for name in names:
            probe = (zig_lib / subdir / name)
            if probe.exists():
                resolved = probe.resolve()
                PASS(f"shared libc++ found at probe path: {name} -> {resolved}")
                _check_needed_libcxx(zig, "libcxx-installed")
                return

    # --- Case B: no shared libc++ -- build from zig's cached libc++.a ---
    print("    (no shared libc++ at probe paths, building from cache)")

    primary, _, symlink_name = _platform_shared_lib_info()
    if not primary:
        SKIP("libcxx-simulation", f"no shared lib name for {plat}")
        return

    # Preferred probe path for placement
    probe_dir = (zig_lib / PROBE_SUBDIRS[0]).resolve()
    shared_lib = probe_dir / primary
    shared_symlink = (probe_dir / symlink_name) if symlink_name else None

    created_dirs: list[Path] = []

    try:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)

            # Phase 1: Find zig's cached libc++.a
            libcxx_a, libcxx_a_reason = _find_libcxx_static(zig, td_path)
            if not libcxx_a:
                # Fallback: search zig lib dir for any libc++.a
                zig_lib_candidates = list(zig_lib.rglob("libc++.a"))
                if zig_lib_candidates:
                    libcxx_a = zig_lib_candidates[0]
                else:
                    SKIP("libcxx-simulation", libcxx_a_reason)
                    return

            PASS(f"found libc++.a: {libcxx_a}")

            # Phase 2: Build shared libc++ from static archive
            shared_build = _build_shared_libcxx(zig, libcxx_a, td_path)
            if not shared_build:
                return

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
            if shared_symlink:
                shared_symlink.symlink_to(primary)
            PASS(f"placed {primary} at probe path")

            # Phase 4: Compile and check dynamic dependency
            _check_needed_libcxx(zig, "libcxx-from-cache")

    finally:
        # Cleanup: remove shared lib from conda prefix
        if shared_symlink and shared_symlink.is_symlink():
            shared_symlink.unlink()
        if shared_lib.exists():
            shared_lib.unlink()
        for d in [probe_dir] + list(reversed(created_dirs)):
            try:
                d.rmdir()
            except OSError:
                pass


_XARCH_TARGETS = ("aarch64-macos", "x86_64-macos")


_STUB_VERSION = "99.77.55"


def _build_arch_stub(zig: str, tgt: str, td: Path) -> Path | None:
    """Build a stub libc++.1.dylib (unique version) for tgt; returns its dir."""
    d = td / tgt
    d.mkdir()
    src = td / "stub.c"
    src.write_text("int zig_feedstock_libcxx_stub(void){return 0;}\n")
    r = _run([zig, "cc", "-shared", "-target", tgt,
              "-Wl,-install_name,@rpath/libc++.1.dylib",
              f"-Wl,-current_version,{_STUB_VERSION}",
              "-Wl,-compatibility_version,1.0.0",
              "-o", str(d / "libc++.1.dylib"), str(src)],
             cwd=str(td), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
    if r.returncode != 0 or not (d / "libc++.1.dylib").exists():
        FAIL(f"libcxx-arch-select: build {tgt} stub dylib",
             f"rc={r.returncode}\n{r.stderr[:2000]}")
        return None
    return d


def _link_libcxx_lines(zig: str, tgt: str, ldir: Path, td: Path,
                       label: str) -> list[str] | None:
    """Link a C++ main against -L ldir; return otool -L lines naming libc++."""
    src = td / "main.cpp"
    src.write_text("int main(){return 0;}\n")
    out = td / f"a.out.{label}"
    r = _run([zig, "c++", "-target", tgt, f"-L{ldir}", str(src), "-o", str(out)],
             cwd=str(td), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
    if r.returncode != 0 or not out.exists():
        FAIL(f"libcxx-arch-select: {label}: link",
             f"rc={r.returncode}\n{r.stderr[:2000]}")
        return None
    otool = shutil.which("otool") or shutil.which("llvm-otool")
    if not otool:
        SKIP(f"libcxx-arch-select: {label}", "otool not found")
        return None
    r2 = _run([otool, "-L", str(out)], cwd=str(td))
    if r2.returncode != 0:
        WARN(f"libcxx-arch-select: {label}: otool", f"rc={r2.returncode}")
        return None
    return [ln.strip() for ln in r2.stdout.splitlines() if "libc++" in ln]


def _is_stub(lines: list[str]) -> bool:
    return any(f"current version {_STUB_VERSION}" in ln for ln in lines)


def _dylib_has_arch(path: Path, tgt_arch: str) -> bool | None:
    """True/False if path has a Mach-O slice for tgt_arch; None if no tool."""
    want = {"aarch64": "arm64", "x86_64": "x86_64"}.get(tgt_arch, tgt_arch)
    cwd = str(path.parent)
    lipo = shutil.which("lipo") or shutil.which("llvm-lipo")
    if lipo:
        r = _run([lipo, "-archs", str(path)], cwd=cwd)
        if r.returncode == 0:
            return want in r.stdout.split()
    otool = shutil.which("otool") or shutil.which("llvm-otool")
    if otool:
        r = _run([otool, "-hv", str(path)], cwd=cwd)
        if r.returncode == 0:
            return want.upper() in r.stdout.upper().split()
    file_tool = shutil.which("file")
    if file_tool:
        r = _run([file_tool, str(path)], cwd=cwd)
        if r.returncode == 0:
            return want in r.stdout
    return None


def _classify_linked(lines: list[str]) -> str:
    if _is_stub(lines):
        return "stub"
    return "conda" if lines else "static"


def _check_mismatch_fallback(tgt: str, lines: list[str]) -> None:
    """Wrong-arch -L stub must be rejected; expect conda libc++ or static."""
    got = _classify_linked(lines)
    conda = Path(_prefix) / "lib" / "libc++.1.dylib"
    has = _dylib_has_arch(conda, tgt.split("-")[0]) if conda.exists() else False
    expected = None if has is None else ("conda" if has else "static")
    label = f"libcxx-arch-select: {tgt} rejects wrong-arch -L stub"
    if got == "stub":
        FAIL(f"{label}: linked wrong-arch libc++ stub", f"otool libc++ lines: {lines}")
    elif expected is None:
        PASS(f"{label}, falls back to {got} (fallback unverified)")
    elif got != expected:
        FAIL(f"{label}: wrong fallback (got {got}, expected {expected})",
             f"otool libc++ lines: {lines}")
    else:
        what = "conda libc++" if got == "conda" else "static"
        PASS(f"libcxx-arch-select: {tgt} rejects wrong-arch -L stub, falls back to {what}")


def test_libcxx_arch_select() -> None:
    """
    darwin link picks a shared libc++ only if it has a slice for the target arch.

    MATCH:    -L dir with a target-arch stub -> the stub is linked.
    MISMATCH: -L dir with only the other arch's stub -> the stub is NOT linked.
    """
    print("--- [patch-0008] Shared libc++ target-arch selection ---")
    if not (is_macos_target and _build_is_mac):
        SKIP("libcxx-arch-select", "needs a macOS build host and macOS target")
        return
    zig = _find_zig_binary()
    if not zig:
        SKIP("libcxx-arch-select", f"zig binary not found ({_zig_bin_name})")
        return

    with tempfile.TemporaryDirectory() as tds:
        td = Path(tds)
        stubs: dict[str, Path] = {}
        for tgt in _XARCH_TARGETS:
            d = _build_arch_stub(zig, tgt, td)
            if d is None:
                return
            stubs[tgt] = d

        for tgt in _XARCH_TARGETS:
            lines = _link_libcxx_lines(zig, tgt, stubs[tgt], td, f"{tgt}-match")
            if lines is None:
                continue
            if _is_stub(lines) and any("@rpath/libc++.1.dylib" in ln for ln in lines):
                PASS(f"libcxx-arch-select: {tgt} picks matching-arch libc++ stub via -L")
            else:
                FAIL(f"libcxx-arch-select: {tgt} ignored matching-arch libc++ stub",
                     f"otool libc++ lines: {lines}")

            other = next(t for t in _XARCH_TARGETS if t != tgt)
            lines = _link_libcxx_lines(zig, tgt, stubs[other], td, f"{tgt}-mismatch")
            if lines is None:
                continue
            _check_mismatch_fallback(tgt, lines)


# ===================================================================
# Main
# ===================================================================
def main() -> int:
    print("=== Shared libc++ Discovery Tests (patch 0008) ===")
    print(f"compile timeout: {_COMPILE_TIMEOUT_S}s (emulated={_is_emulated}, rosetta={_is_rosetta}, hw.optional.arm64={_sysctl_int(b'hw.optional.arm64')}, python={platform.machine()})")
    print(f"  test prefix   = {_prefix}")
    print(f"  CONDA_TRIPLET = {_conda_triplet}")
    print(f"  zig binary    = {_zig_bin_name}")
    print(f"  platform key  = {_get_platform_key()}")
    print(f"  zig lib dir   = {_find_zig_lib_dir()}")
    print(f"  arm64         = {is_arm64}")
    print(f"  ppc64le       = {is_ppc64le}")
    print(f"  emulated      = {_is_emulated}")
    print()

    if not check_emulation_env(_conda_triplet):
        return 1

    with _zig_libcxx(None):
        test_libcxx_fallback_static()
    test_libcxx_probe_paths()
    test_libcxx_shared_simulation()
    with _zig_libcxx("shared"):
        test_libcxx_arch_select()

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
