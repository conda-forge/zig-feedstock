"""Shared test utilities for zig-feedstock test scripts.

Extracted from test_zig_toolchain.py and test_libcxx_shared.py to eliminate
duplication. Import from this module rather than redefining locally.
"""

from __future__ import annotations

import os
import platform as _platform
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
# Test-env prefix resolution
# ---------------------------------------------------------------------------
def resolve_test_prefix(marker: str = "bin") -> Path:
    """Resolve the prefix that actually holds the package under test.

    rattler-build spins up a separate BUILD env whenever a test block
    declares `requirements: build:`. CONDA_PREFIX then resolves to that
    test BUILD env, while the package under test is installed in the RUN
    env (PREFIX). Prefer PREFIX, fall back to CONDA_PREFIX, and pick
    whichever candidate actually has `<candidate>/<marker>` on disk so a
    lane without build requirements (where only CONDA_PREFIX is set/valid)
    keeps working unchanged.

    `marker` must be the subpath the CALLER actually consumes, not just
    any path that happens to exist under the desired prefix. It is used
    purely to discriminate which env is correct and is NEVER appended to
    the returned value -- callers keep computing their own subpaths from
    the returned prefix. Passing a marker the caller does not consume can
    select an env that satisfies the marker but not the real lookup,
    reproducing the silent skip this helper exists to prevent.
    """
    for var in ("PREFIX", "CONDA_PREFIX"):
        candidate = os.environ.get(var, "")
        if candidate and (Path(candidate) / marker).is_dir():
            print(f"  prefix source = {var} (marker {marker!r})")
            return Path(candidate)
    print(f"  prefix source = CONDA_PREFIX (fallback, no env had {marker!r})")
    return Path(os.environ.get("CONDA_PREFIX", ""))


# ---------------------------------------------------------------------------
# Emulation detection
# ---------------------------------------------------------------------------
_native_machine = _platform.machine()
_is_emulated = (
    sys.platform == "linux"
    and _native_machine not in ("x86_64", "i686")
    and os.environ.get("CI", "") != ""
)


def _canonical_arch(arch: str) -> str:
    """Normalise arch aliases (amd64/arm64/ppc64le) to their triplet spelling.

    Case-insensitive: platform.machine() reports "AMD64"/"ARM64" on Windows.
    """
    aliases = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "ppc64le": "powerpc64le",
    }
    arch = arch.lower()
    return aliases.get(arch, arch)


def target_arch_from_triplet(triplet: str) -> str:
    """Extract the machine arch from a conda triplet.

    e.g. 'powerpc64le-conda-linux-gnu' -> 'powerpc64le'.
    """
    return triplet.split("-", 1)[0] if triplet else ""


def is_foreign_target(triplet: str) -> bool:
    """True when triplet's arch differs from the native machine (alias-aware).

    Restricted to Linux triplets: the QEMU-user + binfmt_misc + QEMU_LD_PREFIX
    mechanism this feeds is Linux-ELF-specific (mirrors recipe.yaml's `if:
    linux` gating of QEMU_EXECVE/QEMU_LD_PREFIX). Windows/macOS cross targets
    are never run under it, so they must never be reported as "foreign" here.
    """
    if "linux" not in triplet:
        return False
    arch = target_arch_from_triplet(triplet)
    if not arch:
        return False
    return _canonical_arch(arch) != _canonical_arch(_native_machine)


def _qemu_binary_arch(arch: str) -> str:
    """Map a canonical triplet arch to the qemu-execve-<arch> package's naming.

    Mirrors recipe.yaml's qemu_arch computed value: powerpc64le -> ppc64le,
    every other targeted arch passes through unchanged.
    """
    canonical = _canonical_arch(arch)
    return "ppc64le" if canonical == "powerpc64le" else canonical


def emulation_prefix(triplet: str) -> list[str]:
    """Return the argv prefix needed to run a target-arch binary, or [] if native.

    Uses ONLY qemu-execve-<arch> -- the vanilla qemu-<arch> binary is
    deliberately NOT used here. Both binaries ship in the same
    qemu-execve-<arch> package and a silent fallback to the vanilla one
    would make it ambiguous which emulator actually ran; do not re-add it.
    Returns [] (degrade to binfmt_misc) when no qemu-execve binary can be
    resolved, so callers don't hard-fail on a missing lookup.

    Gate and emulator are both keyed on the TRIPLET. $QEMU_EXECVE is
    target_platform-keyed and there is one per lane, so it is honoured only
    when its basename matches the arch this triplet asks for; otherwise we
    fall through to the PATH lookup. Without that check, a lane handling two
    foreign targets would gate on one arch and emulate with another.
    """
    if not is_foreign_target(triplet):
        return []
    arch = _qemu_binary_arch(target_arch_from_triplet(triplet))
    qemu_execve = os.environ.get("QEMU_EXECVE", "")
    if (
        qemu_execve
        and os.path.basename(qemu_execve) == f"qemu-execve-{arch}"
        and os.access(qemu_execve, os.X_OK)
    ):
        return [qemu_execve]
    found = shutil.which(f"qemu-execve-{arch}")
    return [found] if found else []


def check_emulation_env(triplet: str) -> bool:
    """Preflight QEMU emulation setup for a foreign-target test script.

    Call once per script after the triplet is known, before the first
    target-arch invocation. Returns True if safe to proceed (including the
    native no-op case, where nothing is reported). Returns False after
    reporting FAIL if a hard blocker was found.
    """
    if not is_foreign_target(triplet):
        return True

    arch = _qemu_binary_arch(target_arch_from_triplet(triplet))
    if not emulation_prefix(triplet):
        WARN(
            "qemu emulation binary",
            f"qemu-execve-{arch} not found (QEMU_EXECVE unset/not executable, "
            "not on PATH) -- relying on binfmt_misc for target invocations",
        )

    ld_prefix = os.environ.get("QEMU_LD_PREFIX", "")
    if not ld_prefix:
        FAIL(
            "QEMU_LD_PREFIX is set",
            "unset -- the target binary's loader will resolve against the host root",
        )
        return False

    ld_path = Path(ld_prefix)
    if not ld_path.is_dir():
        detail = f"{ld_prefix} does not exist"
        try:
            parent = ld_path.parent
            if parent.is_dir():
                listing = ", ".join(sorted(p.name for p in parent.iterdir()))
                detail += f"; {parent} contains: {listing}"
        except Exception:
            pass
        FAIL("QEMU_LD_PREFIX directory exists", detail)
        return False

    if not list(ld_path.glob("lib*/ld*.so*")):
        WARN("QEMU_LD_PREFIX loader glob", f"no lib*/ld*.so* found under {ld_prefix}")

    return True


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------
def _run(
    cmd: list[str],
    *,
    timeout: int = 30,
    cwd: str | Path | None = None,
    target: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a command, return CompletedProcess. Never raises on non-zero rc.

    If `target` is a conda triplet, the command is prefixed with
    `emulation_prefix(target)` (a qemu-execve-<arch> wrapper) when the
    triplet's arch is foreign to the native machine. Default None preserves
    prior behaviour exactly.
    """
    if target is not None:
        cmd = emulation_prefix(target) + cmd
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            # POSIX: give the child its own process group so the killpg on the
            # timeout path reaches only the child tree. Without it the child
            # inherits OUR pgid and killpg() SIGKILLs this harness too.
            # No-op on Windows, where False is the default regardless.
            start_new_session=not _build_is_win,
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
