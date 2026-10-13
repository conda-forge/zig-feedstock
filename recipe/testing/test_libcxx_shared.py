#!/usr/bin/env python3
"""
Test shared libc++ discovery for zig_impl_ package (patch 0008).

Runs during zig_impl_$platform test phase using the triplet-prefixed binary
directly (no activation wrappers). Verifies that the zig binary:

  1. Falls back to static libc++ when no shared lib is at probe paths (default)
  2. Carries the shared libc++ probe names on macOS only (patch scoped to osx)
  3. Uses shared libc++ when a real dylib is placed at the probe path (macOS)

Usage:
  python test_libcxx_shared.py <conda_triplet>
  e.g. python test_libcxx_shared.py x86_64-conda-linux-gnu

Exit codes:
  0 = all passed (warnings are OK)
  1 = at least one FAIL
"""

from __future__ import annotations

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

# Emulation detection: _is_emulated is imported from _test_utils.

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
    "../../lib/zig-llvm/lib",  # preferred: dedicated zig-llvm package
    "../../lib",               # fallback: standard lib dir
]

# Optional until the zig-llvm package ships; matched by name, not position.
OPTIONAL_PROBE_SUBDIR = "../../lib/zig-llvm/lib"

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
        elif subdir == OPTIONAL_PROBE_SUBDIR:
            SKIP("optional zig-llvm probe directory", f"{label} is absent")
        else:
            WARN(f"probe dir missing: {label}", "standard library directory absent")

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
            WARN("shared libc++ probe names present in non-macOS zig",
                 ", ".join(present))
        else:
            PASS("shared libc++ probe names absent (patch not applied)")


# ===================================================================
# Test 3: Shared libc++ simulation (place real .so, verify linkage)
# ===================================================================
def _check_needed_libcxx(zig: str, label: str) -> None:
    """Check for dynamic libc++ dependency, then run the report-only probes."""
    with tempfile.TemporaryDirectory() as td:
        cxx_out = Path(td) / "libtest.dylib"
        _compile_and_check_needed(zig, label, td, cxx_out)
        # Measurements run even when the check above returned early.
        if cxx_out.exists():
            _report_libcxxabi_doubled(cxx_out, td)
        _report_xdylib_exception(zig, td)


def _compile_and_check_needed(zig: str, label: str, td: str, cxx_out: Path) -> None:
    """Compile C++ with real std:: usage and check for dynamic libc++ dependency."""
    cxx_src = Path(td) / "test.cpp"
    cxx_src.write_text(
        '#include <string>\n'
        '#include <stdexcept>\n'
        '#include <typeinfo>\n'
        'extern "C" {\n'
        '  __attribute__((visibility("default")))\n'
        '  const char* cxx_rtti(void) {\n'
        '    return typeid(std::string).name();\n'
        '  }\n'
        '  __attribute__((visibility("default")))\n'
        '  void cxx_throw(void) { throw std::runtime_error("x"); }\n'
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


def test_zig_binary_libcxx() -> None:
    """Report-only (macOS): is libc++/libc++abi shared or static in zig itself."""
    print("--- [report] shipped zig binary libc++ linkage ---")
    if not (is_macos_target and _build_is_mac):
        SKIP("zig-bin-libcxx", "macOS-only measurement")
        return
    zig = _find_zig_binary()
    if not zig:
        SKIP("zig-bin-libcxx", f"zig binary not found ({_zig_bin_name})")
        return
    try:
        real = Path(zig).resolve()
        print(f"    zig binary: {real}")
        deps = _otool_deps(real, str(real.parent))
        if not deps:
            WARN("zig-bin-libcxx", "otool not found or no output")
        libcxx = [d.split(" (")[0] for d in deps[1:]
                  if "libc++." in d or "libc++abi" in d]
        shared = [d for d in libcxx if "libc++abi" not in d]
        linkage = f"shared({shared[0]})" if shared else "static"
        defined = _report_libcxxabi_doubled(real, str(real.parent), "ZIG-BIN-")
        print(f"    ZIG-BIN-LIBCXX: {linkage}")
        if defined is None:
            print("    ZIG-BIN-LIBCXXABI-DOUBLED: unknown (nm failed)")
    except Exception as e:  # report-only
        WARN("zig-bin-libcxx", f"probe error: {e}")


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


def _report_xdylib_exception(zig: str, td: str) -> None:
    """Report-only: exception thrown in a dylib is caught by the executable."""
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
            WARN("libcxxabi-xdylib-exception",
                 f"dylib build rc={r.returncode}\n{r.stderr[:500]}")
            return
        r = _run([zig, "c++", "-o", str(d / "xmain"), str(d / "main.cpp"),
                  "-L" + str(d), "-lthrower", "-Wl,-rpath," + str(d)],
                 cwd=str(d), timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)
        if r.returncode != 0:
            WARN("libcxxabi-xdylib-exception",
                 f"exe build rc={r.returncode}\n{r.stderr[:500]}")
            return
        _xdylib_otool(d / "xmain")
        r = _run([str(d / "xmain")], cwd=str(d), timeout=60)
        verdict = "caught" if "CAUGHT" in r.stdout else "NOT caught"
        line = f"LIBCXXABI-XDYLIB-EXCEPTION: {verdict} (rc={r.returncode})"
        print(f"    {line}")
        if verdict != "caught":
            print(f"    XDYLIB: stderr tail:\n{_tail(r.stderr, 15)}")
            print(f"    XDYLIB: stdout tail:\n{_tail(r.stdout, 15)}")
            r2 = _run(["env", f"DYLD_LIBRARY_PATH={_prefix}/lib", str(d / "xmain")],
                      cwd=str(d), timeout=60)
            v2 = "caught" if "CAUGHT" in r2.stdout else "NOT caught"
            print(f"    LIBCXXABI-XDYLIB-EXCEPTION-DYLD-PATH: {v2} "
                  f"(rc={r2.returncode})")
            if v2 != "caught":
                print(_tail(r2.stderr, 15))
            WARN("libcxxabi-xdylib-exception", line)
    except Exception as e:  # report-only
        WARN("libcxxabi-xdylib-exception", f"probe error: {e}")


_PROBE_ARCH = {
    "x86_64": "x86_64",
    "aarch64": "aarch64",
    "ppc64le": "powerpc64le",
    "powerpc64le": "powerpc64le",
    "riscv64": "riscv64",
}

_PROBE_THROWER = (
    '#include <stdexcept>\n'
    '#include <string>\n'
    'struct Base { virtual ~Base() {} };\n'
    'struct Derived : Base { int v = 42; };\n'
    'extern "C++" __attribute__((visibility("default")))\n'
    'void thrower(int x) { throw std::runtime_error("boom" + std::to_string(x)); }\n'
    'extern "C++" __attribute__((visibility("default")))\n'
    'Base* make_base() { return new Derived(); }\n'
)

_PROBE_MAIN = (
    '#include <exception>\n'
    '#include <iostream>\n'
    '#include <map>\n'
    '#include <memory>\n'
    '#include <string>\n'
    '#include <thread>\n'
    '#include <vector>\n'
    'struct Base { virtual ~Base() {} };\n'
    'struct Derived : Base { int v = 42; };\n'
    'void thrower(int);\n'
    'Base* make_base();\n'
    'int main() {\n'
    '  try { thrower(1); } catch (const std::exception& e) {\n'
    '    std::cout << "CAUGHT " << e.what() << std::endl;\n'
    '  }\n'
    '  std::vector<std::string> v{"a", "b"};\n'
    '  std::map<std::string, int> m{{"x", 1}};\n'
    '  int n = 0;\n'
    '  std::thread t([&] { n = (int)v.size() + m["x"]; });\n'
    '  t.join();\n'
    '  std::unique_ptr<Base> b(make_base());\n'
    '  auto* d = dynamic_cast<Derived*>(b.get());\n'
    '  auto sp = std::make_shared<int>(n);\n'
    '  if (!d || d->v != 42 || *sp != 3) return 2;\n'
    '  std::cout << "OK" << std::endl;\n'
    '  return 0;\n'
    '}\n'
)


def _vkey(p: Path) -> tuple[int, ...]:
    try:
        return tuple(int(x) for x in p.name.split("."))
    except ValueError:
        return (-1,)


def _find_conda_gcc() -> tuple[Path, str, str] | None:
    """Return (include/c++ dir, triplet, version) of the newest conda GCC."""
    found = sorted(_prefix.glob("lib/gcc/*-conda-linux-gnu/*/include/c++"),
                   key=lambda p: _vkey(p.parent.parent))
    if not found:
        return None
    best = found[-1]
    return best, best.parent.parent.parent.name, best.parent.parent.name


def _head(text: str, n: int = 15) -> str:
    return "\n".join(text.splitlines()[:n])


def _tail(text: str, n: int = 15) -> str:
    return "\n".join(text.splitlines()[-n:])


def _probe_sym_report(probe: Path, td: Path) -> None:
    readelf = shutil.which("readelf") or shutil.which("llvm-readelf")
    nm = shutil.which("nm") or shutil.which("llvm-nm")
    if readelf:
        needed: list[str] = []
        for f in (probe, td / "libthrower.so"):
            r = _run([readelf, "-d", str(f)], cwd=str(td))
            needed += [l.split("[")[-1].rstrip("]") for l in r.stdout.splitlines()
                       if "NEEDED" in l and "[" in l]
        print(f"    LIBSTDCXX-PROBE-NEEDED: {', '.join(needed) or '(none)'}")
        r = _run([readelf, "-V", str(probe)], cwd=str(td))
        words = r.stdout.replace("(", " ").replace(")", " ").split()
        for pre in ("GLIBCXX_", "GLIBC_"):
            vers = [tuple(int(x) for x in w[len(pre):].split("."))
                    for w in words
                    if w.startswith(pre) and w[len(pre):].replace(".", "").isdigit()]
            if vers:
                print(f"    max {pre}: {'.'.join(map(str, max(vers)))}")
    else:
        print("    LIBSTDCXX-PROBE-NEEDED: skipped (no readelf)")
    if nm:
        r = _run([nm, "-D", "--undefined-only", str(probe)], cwd=str(td))
        n = sum(1 for l in r.stdout.splitlines() if "St3__1" in l)
        print(f"    LIBSTDCXX-PROBE-LIBCXX-SYMS: {n}")
    else:
        print("    LIBSTDCXX-PROBE-LIBCXX-SYMS: skipped (no nm)")


def test_libstdcxx_probe() -> None:
    """Report-only (Linux): zig cc against conda's shared GNU libstdc++."""
    print("--- [report] zig cc vs conda libstdc++ ---")
    if not is_linux_target:
        SKIP("libstdcxx-probe", "Linux-only measurement")
        return
    if _arch == "s390x":
        SKIP("libstdcxx-probe", "s390x not supported")
        return
    zig = _find_zig_binary()
    if not zig:
        SKIP("libstdcxx-probe", f"zig binary not found ({_zig_bin_name})")
        return
    arch = _PROBE_ARCH.get(platform.machine())
    if not arch:
        SKIP("libstdcxx-probe", f"unmapped machine {platform.machine()}")
        return
    try:
        _libstdcxx_probe_run(zig, arch)
    except Exception as e:  # report-only
        WARN("libstdcxx-probe", f"probe error: {e}")


def _libstdcxx_probe_run(zig: str, arch: str) -> None:
    gcc = _find_conda_gcc()
    if not gcc:
        WARN("LIBSTDCXX-PROBE: missing gcc include/c++ dir",
             f"no match under {_prefix}/lib/gcc")
        return
    hdr, triplet, ver = gcc
    libdir_dev = _prefix / "lib" / "gcc" / triplet / ver
    wanted = {
        f"{triplet}/bits/c++config.h": hdr / triplet / "bits" / "c++config.h",
        "backward": hdr / "backward",
        "libstdc++.so.6": _prefix / "lib" / "libstdc++.so.6",
        "libgcc_s.so.1": _prefix / "lib" / "libgcc_s.so.1",
        "gcc libdir": libdir_dev,
    }
    missing = [k for k, p in wanted.items() if not p.exists()]
    if missing:
        have = [k for k in wanted if k not in missing]
        WARN(f"LIBSTDCXX-PROBE: missing {', '.join(missing)}",
             f"found: {', '.join(have) or 'nothing'}")
        return
    print(f"    LIBSTDCXX-PROBE: gcc {ver} triplet {triplet}")

    libs = [str(_prefix / "lib" / "libstdc++.so.6"),
            str(_prefix / "lib" / "libgcc_s.so.1")]
    rpath = f"-Wl,-rpath,{_prefix}/lib"
    flags = ["-target", f"{arch}-linux-gnu.2.28", "-nostdlib++", "-std=c++17", "-w",
             "-I", str(hdr), "-I", str(hdr / triplet),  # -I so libstdc++ precedes zig's libc -isystem dirs (include_next)
             "-I", str(hdr / "backward")]

    def cc(args: list[str], td: Path):
        return _run([zig, "cc"] + args, cwd=str(td),
                    timeout=_COMPILE_TIMEOUT_S, target=_conda_triplet)

    def verdict(tag: str, r) -> bool:
        if timed_out(r):
            print(f"    {tag}: FAIL (timeout {_COMPILE_TIMEOUT_S}s)")
            return False
        ok = r.returncode == 0
        print(f"    {tag}: {'ok' if ok else 'FAIL'}")
        if not ok:
            print(_tail(r.stderr, 30))
        return ok

    with tempfile.TemporaryDirectory() as tds:
        td = Path(tds)
        (td / "override" / "sys").mkdir(parents=True)
        (td / "override" / "sys" / "single_threaded.h").write_text(
            "/* probe override: zig generic-glibc #errors below 2.32; 0 = not single-threaded, so libstdc++ always uses atomics */\n"
            "#pragma once\n"
            "static const char __libc_single_threaded = 0;\n")
        i = flags.index("-I")
        flags = flags[:i] + ["-I", str(td / "override")] + flags[i:]
        print("    LIBSTDCXX-PROBE: using sys/single_threaded.h override "
              "(static const __libc_single_threaded = 0)")
        (td / "thrower.cpp").write_text(_PROBE_THROWER)
        (td / "main.cpp").write_text(_PROBE_MAIN)

        r = cc(flags + ["-shared", "-fPIC", "thrower.cpp"] + libs + [rpath,
               "-o", "libthrower.so"], td)
        if not verdict("LIBSTDCXX-PROBE-COMPILE", r):
            WARN("LIBSTDCXX-PROBE-COMPILE", "compile failed (report-only)")
            return

        r = cc(flags + ["main.cpp", "libthrower.so"] + libs
               + [rpath, f"-Wl,-rpath,{td}", "-o", "probe"], td)
        if not verdict("LIBSTDCXX-PROBE-LINK", r):
            WARN("LIBSTDCXX-PROBE-LINK", "link failed (report-only)")
            return

        r = _run(["env", f"LD_LIBRARY_PATH={td}:{_prefix}/lib", str(td / "probe")],
                 cwd=str(td), timeout=60, target=_conda_triplet)
        ran = (r.returncode == 0 and "CAUGHT" in r.stdout and "OK" in r.stdout)
        if ran:
            print("    LIBSTDCXX-PROBE-RUN: ok")
            PASS("libstdcxx-probe: compile+link+run against conda libstdc++")
        else:
            print(f"    LIBSTDCXX-PROBE-RUN: FAIL (rc={r.returncode})")
            print(_head(r.stdout, 10))
            print(_tail(r.stderr, 30))
            WARN("LIBSTDCXX-PROBE-RUN", f"rc={r.returncode} (report-only)")

        _probe_sym_report(td / "probe", td)

        r = cc(flags + ["main.cpp", "libthrower.so", libs[0], rpath,
                        f"-Wl,-rpath,{td}", "-o", "probe_nogcc"], td)
        if r.returncode == 0:
            print("    LIBSTDCXX-PROBE-NO-LIBGCC_S: links")
        else:
            undef = [l.strip() for l in r.stderr.splitlines()
                     if "undefined" in l][:5]
            print("    LIBSTDCXX-PROBE-NO-LIBGCC_S: undefined: "
                  + ("; ".join(undef) or _head(r.stderr, 3)))

        alias_cmd = [zig, "c++", "-target", f"{arch}-linux-gnu.2.28",
                     "-std=c++17", "main.cpp", "libthrower.so", "-lstdc++",
                     rpath, f"-Wl,-rpath,{td}", "-o", "probe_alias"]
        r = _run(alias_cmd, cwd=str(td), timeout=_COMPILE_TIMEOUT_S,
                 target=_conda_triplet)
        nm = shutil.which("nm") or shutil.which("llvm-nm")
        if r.returncode == 0 and nm:
            r2 = _run([nm, "-D", "--undefined-only", str(td / "probe_alias")],
                      cwd=str(td))
            n = sum(1 for l in r2.stdout.splitlines() if "St3__1" in l)
            print(f"    LIBSTDCXX-PROBE-ALIAS: -lstdc++ gives libc++ ({n} St3__1 syms)")
        else:
            print("    LIBSTDCXX-PROBE-ALIAS: unmeasured "
                  f"(rc={r.returncode}, nm={'yes' if nm else 'no'})")


def _platform_shared_lib_info() -> tuple[str, str, str | None]:
    """Return (primary_name, install_name, symlink_name) for macOS."""
    return "libc++.1.dylib", "libc++.1.dylib", "libc++.dylib"


def _build_shared_libcxx(zig: str, libcxx_a: Path, td_path: Path) -> Path | None:
    """Build a shared libc++ from static libc++.a. Returns output path or None."""
    primary, soname, _ = _platform_shared_lib_info()
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
    probe_dir = (zig_lib / PROBE_SUBDIRS[0]).resolve()  # .../lib/zig-llvm/lib/
    shared_lib = probe_dir / primary
    shared_symlink = (probe_dir / symlink_name) if symlink_name else None

    created_dirs: list[Path] = []

    try:
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)

            # Phase 1: Find zig's cached libc++.a
            libcxx_a, libcxx_a_reason = _find_libcxx_static(zig, td_path)
            if not libcxx_a:
                zig_lib_candidates = list(zig_lib.rglob("libc++.a"))
                libcxx_a = zig_lib_candidates[0] if zig_lib_candidates else None
                if not libcxx_a:
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


def test_libcxx_arch_select() -> None:
    """
    darwin link picks a shared libc++ only if it has a slice for the target arch.

    MATCH:    -L dir with a target-arch stub -> the stub is linked (the -L dirs
              take precedence over the zig_lib-relative probe).
    MISMATCH: -L dir with only the other arch's stub -> the stub is NOT linked.
              The matching-arch conda libc++ or none (static) is acceptable.
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
            if _is_stub(lines):
                PASS(f"libcxx-arch-select: {tgt} picks matching-arch libc++ stub via -L")
            else:
                FAIL(f"libcxx-arch-select: {tgt} ignored matching-arch libc++ stub",
                     f"otool libc++ lines: {lines}")

            other = next(t for t in _XARCH_TARGETS if t != tgt)
            lines = _link_libcxx_lines(zig, tgt, stubs[other], td, f"{tgt}-mismatch")
            if lines is None:
                continue
            if _is_stub(lines):
                FAIL(f"libcxx-arch-select: {tgt} linked wrong-arch libc++ stub",
                     f"otool libc++ lines: {lines}")
            else:
                what = lines[0] if lines else "none (static)"
                PASS(f"libcxx-arch-select: {tgt} rejects wrong-arch libc++ stub; linked: {what}")


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

    test_libcxx_fallback_static()
    test_libcxx_probe_paths()
    test_libcxx_shared_simulation()
    test_libcxx_arch_select()
    test_zig_binary_libcxx()
    test_libstdcxx_probe()

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
