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
    target: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a command, return CompletedProcess. Never raises on non-zero rc.

    When `target` is a conda triplet whose arch is foreign to this machine,
    the command is prefixed with the qemu-execve emulator. Default None
    preserves prior behaviour exactly.
    """
    if target is not None:
        cmd = emulation_prefix(target) + cmd
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
            proc.communicate(timeout=5)  # Drain pipes -- may hang if children survive
        except (subprocess.TimeoutExpired, OSError):
            # Children still alive: force-close pipes so we don't block forever
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    try:
                        pipe.close()
                    except OSError:
                        pass
        return subprocess.CompletedProcess(cmd, returncode=-1, stdout="", stderr="TIMEOUT")


def timed_out(proc: subprocess.CompletedProcess[str]) -> bool:
    """True when `proc` is _run's timeout sentinel."""
    return proc.stderr == "TIMEOUT"


# ---------------------------------------------------------------------------
# Target executability probe (measured, not inferred)
# ---------------------------------------------------------------------------
_can_execute_cache: dict[tuple[str, str | None], bool] = {}


def can_execute_target(triplet: str, zig_cc: str | None = None) -> bool:
    """Measure -- don't infer -- whether a `triplet` binary can run here.

    Compiles a trivial program with `zig_cc` and executes it through `_run`'s
    `target=` routing (qemu-execve when foreign). Cached per (triplet, zig_cc).
    """
    key = (triplet, zig_cc)
    if key in _can_execute_cache:
        return _can_execute_cache[key]
    if not zig_cc:
        _can_execute_cache[key] = False
        return False
    result = False
    try:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "probe.c"
            exe = Path(td) / "probe"
            src.write_text("int main(void) { return 0; }\n")
            # target= on the compile too: on an unhosted lane zig_cc is itself a
            # target-arch binary and needs the emulator.
            r_compile = _run([zig_cc, "-o", str(exe), str(src)], cwd=td,
                             target=triplet, timeout=120)
            produced = exe if exe.exists() else exe.with_suffix(".exe")
            if r_compile.returncode == 0 and produced.exists():
                r_exec = _run([str(produced)], target=triplet, timeout=120)
                result = r_exec.returncode == 0
    except Exception:
        result = False
    _can_execute_cache[key] = result
    return result


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


# ---------------------------------------------------------------------------
# Target emulation (qemu-execve)
# ---------------------------------------------------------------------------
def _canonical_arch(arch: str) -> str:
    """Normalise arch aliases (amd64/arm64/ppc64le) to their triplet spelling."""
    aliases = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "ppc64le": "powerpc64le",
    }
    return aliases.get(arch.lower(), arch.lower())


def target_arch_from_triplet(triplet: str) -> str:
    """'powerpc64le-conda-linux-gnu' -> 'powerpc64le'."""
    return triplet.split("-", 1)[0] if triplet else ""


def is_foreign_target(triplet: str) -> bool:
    """True when triplet's arch differs from the native machine (alias-aware).

    Linux-only: the qemu-user + QEMU_LD_PREFIX mechanism this feeds is
    Linux-ELF-specific, mirroring recipe.yaml's `if: linux` gating. Windows and
    macOS cross targets are never run under it.

    This predicate is correct under BOTH interpreter models. While the whole
    interpreter runs under qemu, _native_machine already reports the target
    arch, so nothing is reported foreign and no second prefix is added. Once
    the harness runs natively, the target reads foreign and the prefix applies.
    """
    if "linux" not in triplet:
        return False
    arch = target_arch_from_triplet(triplet)
    if not arch:
        return False
    return _canonical_arch(arch) != _canonical_arch(_native_machine)


def _qemu_binary_arch(arch: str) -> str:
    """Canonical triplet arch -> qemu-execve-<arch> package naming."""
    canonical = _canonical_arch(arch)
    return "ppc64le" if canonical == "powerpc64le" else canonical


def emulation_prefix(triplet: str) -> list[str]:
    """Emulator argv prefix for running a `triplet` binary, or [] if native."""
    if not is_foreign_target(triplet):
        return []
    arch = _qemu_binary_arch(target_arch_from_triplet(triplet))
    qemu_execve = os.environ.get("QEMU_EXECVE", "")
    # $QEMU_EXECVE is target_platform-keyed and there is one per lane, so it is
    # honoured only when it names the arch actually requested; otherwise fall
    # through to the triplet-keyed lookup. Using it unconditionally would
    # silently emulate with the wrong arch, which is harder to debug than a
    # missing emulator.
    if qemu_execve and os.access(qemu_execve, os.X_OK) and arch in Path(qemu_execve).name:
        return [qemu_execve]
    found = shutil.which(f"qemu-execve-{arch}")
    return [found] if found else []


def check_emulation_env(triplet: str) -> bool:
    """Preflight emulation setup. True if safe to proceed (native is a no-op).

    Not yet called anywhere in this tree; present so the mechanism matches the
    0.17 track.
    """
    if not is_foreign_target(triplet):
        return True

    arch = _qemu_binary_arch(target_arch_from_triplet(triplet))
    if not emulation_prefix(triplet):
        WARN(
            "qemu emulation binary",
            f"qemu-execve-{arch} not found -- relying on binfmt_misc",
        )

    ld_prefix = os.environ.get("QEMU_LD_PREFIX", "")
    if not ld_prefix:
        FAIL("QEMU_LD_PREFIX is set", "unset -- loader resolves against the host root")
        return False
    if not Path(ld_prefix).is_dir():
        FAIL("QEMU_LD_PREFIX directory exists", f"{ld_prefix} does not exist")
        return False
    if not list(Path(ld_prefix).glob("lib*/ld*.so*")):
        WARN("QEMU_LD_PREFIX loader glob", f"no lib*/ld*.so* under {ld_prefix}")
    return True
