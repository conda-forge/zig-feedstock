"""Shared test utilities for zig-feedstock test scripts.

Extracted from test_zig_toolchain.py and test_libcxx_shared.py to eliminate
duplication. Import from this module rather than redefining locally.
"""

from __future__ import annotations

import os
import platform as _platform
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

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
# Build-machine OS (needed by _run for Windows process-kill path)
# ---------------------------------------------------------------------------
_build_is_win = sys.platform == "win32"
_build_is_mac = sys.platform == "darwin"

# ---------------------------------------------------------------------------
# ZIG_GLOBAL_CACHE_DIR setup
# ---------------------------------------------------------------------------
# NOTE: same fallback logic is duplicated in recipe/scripts/activate.sh ZIG_GLOBAL_CACHE_DIR block.
# Keep both implementations in sync until the cross-language duplication is consolidated.
def setup_zig_global_cache_dir() -> None:
    """Set ZIG_GLOBAL_CACHE_DIR in os.environ if not already set.

    zig's getAppDataDir on Linux checks XDG_DATA_HOME then HOME/.local/share;
    ZIG_GLOBAL_CACHE_DIR overrides the lookup entirely.  Call this so direct
    zig invocations work in CI envs without HOME.
    """
    if "ZIG_GLOBAL_CACHE_DIR" not in os.environ:
        _xdg_data = os.environ.get("XDG_DATA_HOME", "")
        _home = os.environ.get("HOME", "")
        if _xdg_data:
            os.environ["ZIG_GLOBAL_CACHE_DIR"] = f"{_xdg_data}/zig/zig-cache"
        elif _home:
            os.environ["ZIG_GLOBAL_CACHE_DIR"] = f"{_home}/.local/share/zig/zig-cache"
        else:
            _uid = str(os.getuid()) if hasattr(os, "getuid") else "0"
            os.environ["ZIG_GLOBAL_CACHE_DIR"] = os.path.join(
                tempfile.gettempdir(), f"zig-cache-{_uid}"
            )


# ---------------------------------------------------------------------------
# Emulation detection
# ---------------------------------------------------------------------------
_native_machine = _platform.machine()
_is_emulated = (
    sys.platform == "linux"
    and _native_machine not in ("x86_64", "i686")
    and os.environ.get("CI", "") != ""
)


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------
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
        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")
        return subprocess.CompletedProcess(cmd, returncode=proc.returncode,
                                           stdout=stdout, stderr=stderr)
    except subprocess.TimeoutExpired:
        # Kill the process tree to prevent zombie processes producing
        # non-UTF-8 output that can crash the caller (e.g. rattler-build on non-unix).
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
# Build-29 helpers — COFF/PE inspection, RC sources, nm, wrapper probe
# ---------------------------------------------------------------------------
import shutil
import struct

COFF_MACHINE_X86_64 = 0x8664
COFF_MACHINE_AARCH64 = 0xAA64
COFF_MACHINE_I386 = 0x014C


def get_zig_wrapper(suffix: str) -> Path:
    """Return Path to the triplet-prefixed zig wrapper for *suffix*.

    Resolves the triplet from CONDA_ZIG_HOST (same env var used by
    test_zig_toolchain.py) and the wrapper directory from CONDA_PREFIX.
    Returns the Path whether or not it exists — callers must check .exists().
    """
    host = os.environ.get("CONDA_ZIG_HOST", "")
    triplet = host.removesuffix("-zig") if host.endswith("-zig") else host
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    exe_suffix = ".exe" if sys.platform == "win32" else ""
    if sys.platform == "win32":
        wrapper_dir = prefix / "Library" / "bin"
    else:
        wrapper_dir = prefix / "bin"
    name = f"{triplet}-zig-{suffix}{exe_suffix}"
    return wrapper_dir / name


def get_bare_zig_wrapper(fallback_to_cc: bool = True) -> Path | None:
    """Return Path to the bare ``<triplet>-zig[.exe]`` binary, or None if not found.

    Resolves the triplet from CONDA_ZIG_HOST (stripping the trailing ``-zig``
    suffix if present) and the wrapper directory from CONDA_PREFIX.

    When *fallback_to_cc* is True (default) and the bare binary does not exist,
    falls back to the ``<triplet>-zig-cc`` wrapper.  Returns None if neither
    is found.
    """
    host = os.environ.get("CONDA_ZIG_HOST", "")
    triplet = host.removesuffix("-zig") if host.endswith("-zig") else host
    prefix = Path(os.environ.get("CONDA_PREFIX", ""))
    exe_suffix = ".exe" if sys.platform == "win32" else ""
    if sys.platform == "win32":
        wrapper_dir = prefix / "Library" / "bin"
    else:
        wrapper_dir = prefix / "bin"
    bare = wrapper_dir / f"{triplet}-zig{exe_suffix}"
    if bare.exists():
        return bare
    if fallback_to_cc:
        cc = wrapper_dir / f"{triplet}-zig-cc{exe_suffix}"
        if cc.exists():
            return cc
    return None


def skip_if_no_wrapper(suffix: str) -> None:
    """Skip (via pytest) if the wrapper binary for *suffix* is not installed.

    Calls get_zig_wrapper(suffix); if the path does not exist, calls
    pytest.skip() so the test is marked SKIP rather than FAIL.
    """
    import pytest  # only imported when needed — pytest must be available

    wrapper = get_zig_wrapper(suffix)
    if not wrapper.exists():
        pytest.skip(f"wrapper {suffix} not found — needs build env")


def compile_minimal_rc(tmpdir: Path) -> Path:
    """Write a minimal .rc file (and a 1-byte dummy .ico) into *tmpdir*.

    Returns the Path of the .rc file.  The .ico file is created alongside so
    that RC compilers that open the referenced file do not error.
    """
    ico_path = Path(tmpdir) / "test.ico"
    ico_path.write_bytes(b"\x00")
    rc_path = Path(tmpdir) / "test.rc"
    rc_path.write_text('1 ICON "test.ico"\n', encoding="utf-8")
    return rc_path


def compile_minimal_winmain_c(tmpdir: Path) -> Path:
    """Write a minimal wmain C source file into *tmpdir*.

    Returns the Path of the .c file.
    """
    src_path = Path(tmpdir) / "winmain.c"
    src_path.write_text(
        "int wmain(int argc, wchar_t **argv) { (void)argc; (void)argv; return 0; }\n",
        encoding="utf-8",
    )
    return src_path


def coff_machine_type(file_path: Path) -> int:
    """Read the first 2 bytes of a COFF object file and return the machine type.

    The machine type is a little-endian uint16 at offset 0 in a COFF header.
    Returns 0 on any read failure.
    """
    try:
        data = Path(file_path).read_bytes()
        if len(data) < 2:
            return 0
        return struct.unpack("<H", data[:2])[0]
    except OSError:
        return 0


def pe_machine_type(file_path: Path) -> int:
    """Read a PE binary and return the machine type from the PE header.

    Locates the PE header offset at bytes 60-64 (little-endian uint32),
    seeks to offset+4 (skipping the "PE\\0\\0" signature), then reads
    2 bytes as little-endian uint16 machine type.
    Returns 0 on any parse failure.
    """
    try:
        data = Path(file_path).read_bytes()
        if len(data) < 64:
            return 0
        pe_offset = struct.unpack("<I", data[60:64])[0]
        # Signature is 4 bytes ("PE\0\0"), machine type immediately follows
        mtype_offset = pe_offset + 4
        if len(data) < mtype_offset + 2:
            return 0
        return struct.unpack("<H", data[mtype_offset : mtype_offset + 2])[0]
    except (OSError, struct.error):
        return 0


def nm_symbols(archive_or_obj: Path) -> dict[str, str]:
    """Invoke ``llvm-nm`` on *archive_or_obj* and return a symbol→type mapping.

    The returned dict maps symbol name to the single-letter type (e.g. ``"T"``
    for defined text, ``"U"`` for undefined).  If ``llvm-nm`` is not on PATH
    or the invocation fails, an empty dict is returned silently.
    """
    llvm_nm = shutil.which("llvm-nm")
    if llvm_nm is None:
        return {}
    result = _run([llvm_nm, str(archive_or_obj)], timeout=30)
    if result.returncode != 0 or not result.stdout:
        return {}
    symbols: dict[str, str] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        # llvm-nm output: [address] <type> <name>  OR  <type> <name>
        if len(parts) == 3:
            _, type_letter, name = parts
        elif len(parts) == 2:
            type_letter, name = parts
        else:
            continue
        symbols[name] = type_letter
    return symbols
