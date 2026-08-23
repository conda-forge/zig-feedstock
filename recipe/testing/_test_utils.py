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
# QEMU_EXECVE is exported by recipe.yaml only under
# `linux and build_platform != target_platform`, i.e. exactly the unhosted
# cross lane where target binaries must run under qemu-user. Deriving from it
# keys emulation off the BUILD/TARGET RELATIONSHIP rather than off host
# hardware identity.
#
# The previous definition tested `_platform.machine() not in ("x86_64","i686")`,
# which was wrong twice over: it reported True on the NATIVE linux_aarch64
# runners (no emulation at all), and it would silently invert the day a lane
# builds x86-64 on aarch64 hardware. Never reintroduce a machine allowlist here.
#
# Note recipe.yaml assigns `${QEMU_EXECVE:-$(command -v qemu-<arch> || true)}`,
# so the variable can legitimately be the empty string -- test for non-empty.
_is_emulated = bool(os.environ.get("QEMU_EXECVE", ""))


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
            # own session+pgid: the killpg below must not target our own group
            start_new_session=True,
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
# Test-env prefix resolution
# ---------------------------------------------------------------------------
def resolve_test_prefix(marker: str = "bin") -> Path:
    """Resolve the prefix that actually holds the package under test.

    rattler-build spins up a separate BUILD env whenever a test block declares
    `requirements: build:`.  CONDA_PREFIX then resolves to that test BUILD env
    while the package under test is installed in the RUN env (PREFIX).

    Pass the subpath the CALLER actually consumes as `marker`: it is used purely
    to discriminate which env is the right one, and is never appended to the
    return value -- callers keep computing their own subpaths from the prefix.
    Using a marker the caller does not consume can return an env that satisfies
    the marker but not the real lookup, reproducing the silent skip this exists
    to prevent.

    Falls back to CONDA_PREFIX unchanged when neither candidate matches, so a
    lane that works today cannot regress.
    """
    for var in ("PREFIX", "CONDA_PREFIX"):
        candidate = os.environ.get(var, "")
        if candidate and (Path(candidate) / marker).is_dir():
            print(f"  prefix source = {var} (marker {marker!r})")
            return Path(candidate)
    print(f"  prefix source = CONDA_PREFIX (fallback, no env had {marker!r})")
    return Path(os.environ.get("CONDA_PREFIX", ""))
