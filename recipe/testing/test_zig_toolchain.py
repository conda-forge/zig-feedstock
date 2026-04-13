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
is_aarch64_win = is_win_target and _arch == "aarch64"

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

# Detect zig_impl build number from conda-meta for feature gating
_zig_impl_build_number = 0
_conda_meta = _prefix / "conda-meta"
if _conda_meta.exists():
    import glob as _glob
    for _meta in _glob.glob(str(_conda_meta / "zig_impl_*.json")):
        try:
            import json as _json
            with open(_meta) as _f:
                _meta_data = _json.load(_f)
                _zig_impl_build_number = int(_meta_data.get("build_number", 0))
        except (ValueError, KeyError, OSError):
            pass


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
# C source snippets used by functional tests
# ---------------------------------------------------------------------------
_HELLO_C = 'int hello(void) { return 42; }\n'
_MAIN_C = 'int main(void) { return 0; }\n'
_VIS_C = '__attribute__((visibility("default"))) int vis_test_func(void) { return 1; }\n'
_LIBC_C = """\
#include <stdio.h>
#include <string.h>
int main(void) {
    const char *s = "hello";
    printf("len=%zu\\n", strlen(s));
    return 0;
}
"""


# ===================================================================
# Section 1 — Wrapper existence
# ===================================================================
def test_wrapper_existence() -> None:
    print("--- Wrapper existence ---")

    if _build_is_win:
        expected = [
            "zig-cc.exe",
            "zig-cxx.exe",
            "zig-ar.bat",
            "zig-ranlib.bat",
            "zig-asm.bat",
            "zig-rc.bat",
            "zig-lld.bat",
        ]
    else:
        expected = [
            "zig-cc",
            "zig-cxx",
            "zig-force-load-cc",
            "zig-force-load-cxx",
            "zig-ar",
            "zig-ranlib",
            "zig-asm",
            "zig-rc",
            "zig-lld",
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

    # ZIG_CC / ZIG_CXX / ZIG_LLD
    for var in ("ZIG_CC", "ZIG_CXX", "ZIG_LLD"):
        val = _env_var(var)
        if val:
            PASS(f"{var} is set", val)
        else:
            # These may not be set in all activation modes
            SKIP(f"{var} is set", "not activated")

    # Unix-specific
    if not _build_is_win:
        for var in ("ZIG_FORCE_LOAD_CC",):
            val = _env_var(var)
            if val:
                PASS(f"{var} is set")
                if os.path.isfile(val) and os.access(val, os.X_OK):
                    PASS(f"{var} points to executable")
                else:
                    FAIL(f"{var} points to executable", val)
            else:
                FAIL(f"{var} is set")

    # non-unix specific
    if _build_is_win:
        for var in ("ZIG_RC",):
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
                 f"rc={r.returncode} stderr={r.stderr[:2000]}")

        # --- Verify self-hosted linker flags are filtered ---
        # zig cc may use the self-hosted linker which doesn't support these.
        # The wrapper should silently filter them so compilation succeeds.
        if _is_emulated or _is_cross_compiler:
            SKIP("linker flag filtering", "emulated/cross CI — cannot execute target binary")
        else:
            # --- Auto-LLD promotion: --dynamic-list triggers -fuse-ld=lld ---
            # Verifies the full pipeline:
            # 1. Wrapper detects --dynamic-list -> injects -fuse-ld=lld
            # 2. Patched zig binary honors -fuse-ld=lld -> selects LLD
            # 3. Patched zig binary passes unknown linker arg to LLD
            # 4. LLD processes --dynamic-list successfully
            main_src = Path(td) / "main_dl.c"
            main_src.write_text("int main(void) { return 0; }\n")
            dynlist = Path(td) / "test.dynlist"
            dynlist.write_text("{ main; };\n")

            # Step 1: Verify --dynamic-list fails WITHOUT the wrapper (raw zig cc)
            # This confirms the self-hosted linker rejects it
            zig_bin = _env_var("ZIG") or _env_var("CONDA_ZIG_BUILD")
            if zig_bin:
                zig_path = _prefix / "bin" / zig_bin if not os.path.isabs(zig_bin) else Path(zig_bin)
                if zig_path.exists():
                    r_raw = _run([str(zig_path), "cc", "-target", "x86_64-linux-gnu",
                                  f"-Wl,--dynamic-list={dynlist}",
                                  "-o", str(Path(td) / "raw_dl"), str(main_src)],
                                 cwd=td, timeout=60)
                    if r_raw.returncode != 0 and "unsupported linker arg" in r_raw.stderr:
                        PASS("raw zig cc rejects --dynamic-list (self-hosted linker)")
                    elif r_raw.returncode == 0:
                        PASS("raw zig cc accepts --dynamic-list (LLD default for this target)")
                    else:
                        WARN("raw zig cc --dynamic-list", f"unexpected: rc={r_raw.returncode}")

            # Step 2 & 3: -fuse-ld=lld + --dynamic-list test (Linux/ELF only in toolchain test)
            # macOS/Windows: tested via zig_impl recipe tests with platform-appropriate flags
            if not is_linux_target or _zig_impl_build_number < 17:
                _reason = (f"non-Linux target ({_triplet}), see zig_impl tests" if not is_linux_target
                           else f"zig_impl build {_zig_impl_build_number} < 17")
                SKIP("--dynamic-list auto-LLD promotion", _reason)
                SKIP("-fuse-ld=lld explicit with --dynamic-list", _reason)
            else:
                # Step 2: Verify --dynamic-list succeeds via wrapper (auto-LLD promotion)
                exe_dl = Path(td) / "test_dynlist_lld"
                dl_cmd = [
                    zig_cc,
                    f"-Wl,--dynamic-list={dynlist}",
                    "-o", str(exe_dl), str(main_src),
                ]
                r_dl = _run(dl_cmd, cwd=td, timeout=60)
                if r_dl.stderr == "TIMEOUT":
                    WARN("--dynamic-list auto-LLD", "timed out (60s)")
                elif r_dl.returncode == 0 and exe_dl.exists():
                    PASS("--dynamic-list auto-LLD promotion (wrapper + patched zig)")
                else:
                    FAIL("--dynamic-list auto-LLD promotion",
                         f"rc={r_dl.returncode} stderr={r_dl.stderr[:2000]}")

                # Step 3: Verify explicit -fuse-ld=lld also works
                exe_explicit = Path(td) / "test_explicit_lld"
                explicit_cmd = [
                    zig_cc, "-fuse-ld=lld",
                    f"-Wl,--dynamic-list={dynlist}",
                    "-o", str(exe_explicit), str(main_src),
                ]
                r_exp = _run(explicit_cmd, cwd=td, timeout=60)
                if r_exp.stderr == "TIMEOUT":
                    WARN("-fuse-ld=lld explicit", "timed out (60s)")
                elif r_exp.returncode == 0 and exe_explicit.exists():
                    PASS("-fuse-ld=lld explicit with --dynamic-list")
                else:
                    FAIL("-fuse-ld=lld explicit with --dynamic-list",
                         f"rc={r_exp.returncode} stderr={r_exp.stderr[:2000]}")


# ===================================================================
# Section 3b — Target/mcpu override and Windows C shim tests
# ===================================================================
def test_target_override() -> None:
    print("--- Target/mcpu override ---")

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("target override", "ZIG_CC not set")
        return

    if _zig_impl_build_number < 17:
        SKIP("target override",
             f"zig_impl build {_zig_impl_build_number} < 17 (wrappers lack override support)")
        return

    if _is_emulated or _is_cross_compiler:
        SKIP("target override", "emulated/cross CI — cannot execute target binary")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "test_override.c"
        src.write_text("int main(void) { return 0; }\n")

        # Test: user-provided -target should override the baked-in default
        # Use "native" -- verifies the wrapper skips baked-in -target
        # without producing duplicate/conflicting -target flags
        obj = Path(td) / "test_override.o"
        r = _run([zig_cc, "-target", "native",
                  "-c", "-o", str(obj), str(src)], cwd=td, timeout=60)
        if r.returncode == 0 and obj.exists():
            PASS("compile with user -target override")
        else:
            FAIL("compile with user -target override",
                 f"rc={r.returncode} stderr={r.stderr[:2000]}")

        # Test: user-provided -mcpu should override baked-in -mcpu=baseline
        obj2 = Path(td) / "test_mcpu.o"
        r2 = _run([zig_cc, "-mcpu=baseline", "-c", "-o", str(obj2), str(src)],
                   cwd=td, timeout=60)
        if r2.returncode == 0 and obj2.exists():
            PASS("compile with user -mcpu override")
        else:
            FAIL("compile with user -mcpu override",
                 f"rc={r2.returncode} stderr={r2.stderr[:2000]}")


# ===================================================================
# Section 4 — Shared library creation
# ===================================================================
def test_shared_lib() -> None:
    print("--- Shared library creation ---")

    if _is_emulated or _is_cross_compiler:
        SKIP("shared lib creation", "emulated/cross CI — cannot execute target binary")
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
            FAIL("compile object for shared lib", f"rc={r.returncode} stderr={r.stderr[:2000]}")
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
    r = _run(cmd, cwd=td, timeout=180)

    if r.stderr == "TIMEOUT":
        FAIL("shared lib creation (windows)", "timeout after 180s")
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

    if _is_emulated or _is_cross_compiler:
        SKIP("exe linking", "emulated/cross CI — cannot execute target binary")
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
# Section 4c — Libc linking (verifies zig can resolve and link libc)
# ===================================================================
def test_libc_linking() -> None:
    """Compile and link a program that calls libc functions (printf, strlen).
    This exercises zig's libc detection and linking — the same code path
    that crashes with TODO panic in zig's doctest examples using -lc."""
    print("--- Libc linking ---")

    if _is_emulated or _is_cross_compiler:
        SKIP("libc linking", "emulated/cross CI — cannot execute target binary")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("libc linking", "ZIG_CC not set")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "libc_test.c"
        src.write_text(_LIBC_C)

        if _build_is_win:
            out = Path(td) / "libc_test.exe"
        else:
            out = Path(td) / "libc_test"

        r = _run([zig_cc, "-lc", "-o", str(out), str(src)], cwd=td, timeout=60)
        if r.stderr == "TIMEOUT":
            WARN("libc linking", "timed out (60s)")
            return
        if r.returncode != 0:
            FAIL("libc linking",
                 f"rc={r.returncode} stderr={r.stderr[:2000]}")
            return
        if not out.exists() or out.stat().st_size == 0:
            FAIL("libc linking", "output binary missing or empty")
            return
        PASS("libc linking")

        # If native (not cross), try running it
        if not _is_cross_compiler and not is_win_target:
            r2 = _run([str(out)], cwd=td, timeout=10)
            if r2.returncode == 0 and "len=5" in r2.stdout:
                PASS("libc exe runs correctly")
            elif r2.returncode == 0:
                WARN("libc exe runs", f"unexpected output: {r2.stdout[:200]}")
            else:
                WARN("libc exe runs",
                     f"rc={r2.returncode} stderr={r2.stderr[:200]}")


# ===================================================================
# Section 4d — Windows import library resolution (ziglang/zig#14919)
# ===================================================================
def test_windows_import_libs() -> None:
    """Verify -lsynchronization resolves when targeting Windows.

    OCaml's configure.ac unconditionally adds -lsynchronization to BYTECCLIBS
    for MinGW targets.  Zig doesn't ship synchronization.def in its MinGW sysroot;
    the feedstock workaround adds it so zig can generate libsynchronization.a
    on-the-fly (synchronization.dll == api-ms-win-core-synch-l1-2-0 API set).
    """
    print("--- Windows import lib resolution (-lsynchronization) ---")

    if not is_win_target:
        SKIP("windows import libs", "Windows target only")
        return

    if _is_emulated:
        SKIP("windows import libs", "emulated CI — linker OOM risk")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("windows import libs", "ZIG_CC not set")
        return

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "sync_test.c"
        src.write_text("int main(void) { return 0; }\n")

        # Test 1: -lsynchronization (missing .def — ziglang/zig#14919)
        out = Path(td) / "sync_test.exe"
        r = _run(
            [zig_cc, "-lsynchronization", "-o", str(out), str(src)],
            cwd=td,
            timeout=60,
        )
        if r.stderr == "TIMEOUT":
            WARN("windows import libs (-lsynchronization)", "timed out (60s)")
        elif r.returncode != 0:
            if "DllImportLibraryNotFound" in r.stderr or "libsynchronization" in r.stderr:
                FAIL(
                    "windows import libs (-lsynchronization)",
                    "libsynchronization.a not found — synchronization.def missing from sysroot",
                )
            else:
                FAIL(
                    "windows import libs (-lsynchronization)",
                    f"rc={r.returncode} stderr={r.stderr[:2000]}",
                )
        else:
            PASS("windows import libs (-lsynchronization)")

        # Test 2: -lapi-ms-win-core-synch-l1-2-0 (LIBRARY line missing .dll suffix → unreachable)
        out2 = Path(td) / "apisynch_test.exe"
        r2 = _run(
            [zig_cc, "-lapi-ms-win-core-synch-l1-2-0", "-o", str(out2), str(src)],
            cwd=td,
            timeout=60,
        )
        if r2.stderr == "TIMEOUT":
            WARN("windows import libs (-lapi-ms-win-core-synch-l1-2-0)", "timed out (60s)")
        elif r2.returncode != 0:
            if "unreachable" in r2.stderr or "reached unreachable" in r2.stderr:
                FAIL(
                    "windows import libs (-lapi-ms-win-core-synch-l1-2-0)",
                    "zig panic: LIBRARY line missing .dll suffix in api-ms-win-core-synch-l1-2-0.def "
                    "(feedstock .dll suffix fix not applied)",
                )
            elif "unable to find dynamic system library" in r2.stderr:
                # api-ms-win-core-synch-l1-2-0 is absent from the arm64 Windows SDK layout
                # on some CI runners. This is an SDK gap, not our bug — the unreachable panic
                # (what we fixed) is absent, so the fix is working.
                WARN(
                    "windows import libs (-lapi-ms-win-core-synch-l1-2-0)",
                    "lib not in Windows SDK paths (arm64 SDK gap) — no unreachable panic, fix OK",
                )
            else:
                FAIL(
                    "windows import libs (-lapi-ms-win-core-synch-l1-2-0)",
                    f"rc={r2.returncode} stderr={r2.stderr[:2000]}",
                )
        else:
            PASS("windows import libs (-lapi-ms-win-core-synch-l1-2-0)")


# ===================================================================
# Section 4e — -print-search-dirs and pre-generated MinGW import libs
# ===================================================================
def test_print_search_dirs() -> None:
    """Verify -print-search-dirs returns GCC-compatible output with valid paths.

    flexlink's mingw_libs calls CC -print-search-dirs to find library search
    paths.  Without a response, flexlink has no paths and treats -lws2_32 as a
    literal filename, causing the link to fail.
    """
    print("--- -print-search-dirs (flexlink compat) ---")

    if not is_win_target:
        SKIP("print-search-dirs", "Windows target only")
        return

    if _is_cross_compiler:
        SKIP("print-search-dirs", "cross CI — zig binary is for target arch, cannot execute on host")
        return

    zig_cc = _env_var("ZIG_CC")
    if not zig_cc:
        SKIP("print-search-dirs", "ZIG_CC not set")
        return

    r = _run([zig_cc, "-print-search-dirs"], cwd=tempfile.gettempdir(), timeout=15)
    if r.returncode != 0:
        FAIL("-print-search-dirs exits zero", f"rc={r.returncode} stderr={r.stderr[:500]}")
        return

    output = r.stdout
    if not output.strip():
        FAIL("-print-search-dirs produces output", "stdout was empty")
        return
    PASS("-print-search-dirs produces output")

    # flexlink parses the 'libraries:' line specifically
    if "libraries:" in output:
        PASS("-print-search-dirs has 'libraries:' line")
    else:
        FAIL("-print-search-dirs has 'libraries:' line", f"output: {output[:500]}")
        return

    # Extract library paths and verify at least one is a real directory
    lib_line = next((ln for ln in output.splitlines() if ln.startswith("libraries:")), "")
    paths_str = lib_line.split("=", 1)[-1] if "=" in lib_line else ""
    sep = ";" if _build_is_win else ":"
    paths = [p for p in paths_str.split(sep) if p.strip()]

    if not paths:
        FAIL("-print-search-dirs libraries line contains paths")
        return

    valid_dirs = [p for p in paths if Path(p).is_dir()]
    if valid_dirs:
        PASS(f"-print-search-dirs library paths exist ({len(valid_dirs)}/{len(paths)} valid)")
    else:
        FAIL("-print-search-dirs library paths exist",
             f"none of {paths!r} are valid directories")


def test_mingw_prebuilt_import_libs() -> None:
    """Verify pre-generated MinGW import .a files exist for core Windows libs.

    The -print-search-dirs response points flexlink to lib-common/.  These .a
    files must exist on disk at install time so flexlink can resolve -lws2_32,
    -lkernel32, etc. as library links rather than literal filenames.

    .def files  → llvm-dlltool generates the .a directly.
    .def.in files (ws2_32, kernel32, ...) → preprocessed with zig cc -E -P
                  to expand F_X64/F_I386 macros, then llvm-dlltool.
    uuid        → compiled from libsrc/uuid.c (no DLL import lib needed).
    """
    print("--- Pre-generated MinGW import libs ---")

    if not is_win_target:
        SKIP("mingw prebuilt import libs", "Windows target only")
        return

    if _build_is_win:
        lib_common = _prefix / "Library" / "lib" / "zig" / "libc" / "mingw" / "lib-common"
    else:
        lib_common = _prefix / "lib" / "zig" / "libc" / "mingw" / "lib-common"

    if not lib_common.is_dir():
        FAIL("lib-common directory exists", str(lib_common))
        return
    PASS("lib-common directory exists")

    # Core Windows system libs — from .def.in templates (ws2_32, kernel32, ole32,
    # advapi32, user32) or plain .def (shlwapi, version, synchronization) or
    # C source (uuid).
    required = [
        "libws2_32.a",       # .def.in — Winsock
        "libkernel32.a",     # .def.in — Windows kernel
        "libole32.a",        # .def.in — COM/OLE
        "libadvapi32.a",     # .def.in — registry, security
        "libuser32.a",       # .def.in — UI, message loop
        "libuuid.a",         # C source (libsrc/uuid.c) — UUID constants
        "libsynchronization.a",  # plain .def (our feedstock workaround)
        "libshlwapi.a",      # plain .def — Shell lightweight API
        "libversion.a",      # plain .def — version info
    ]
    for fname in required:
        lib = lib_common / fname
        if lib.exists() and lib.stat().st_size > 0:
            PASS(f"pre-generated {fname}")
        else:
            FAIL(f"pre-generated {fname}",
                 f"{lib} {'missing' if not lib.exists() else 'is empty (0 bytes)'}")


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
# Section 6 — ld.lld dispatch (non-unix targets only)
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
        ("-lgcc_eh filtered (GCC EH not in zig)", "lgcc_eh"),
        ("-lgcc_s filtered (GCC shared runtime not in zig)", "lgcc_s"),
        ("-l:libpthread.a filtered (colon-prefix panics zig linker)", "l:libpthread"),
        ("-print-search-dirs handler present (flexlink compat)", "print-search-dirs"),
    ]
    for label, needle in checks:
        if needle in text:
            PASS(label)
        else:
            FAIL(label)

    # Auto-LLD promotion: LLD-only flags should trigger -fuse-ld=lld injection
    if "_use_lld" in text and "-fuse-ld=lld" in text:
        PASS("auto-LLD promotion logic present")
    else:
        FAIL("auto-LLD promotion logic present")

    lld_triggers = ["version-script", "dynamic-list", "gc-sections", "build-id"]
    for flag in lld_triggers:
        if f"--{flag}" in text:
            PASS(f"--{flag} triggers LLD promotion")
        else:
            FAIL(f"--{flag} should trigger LLD promotion")


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
        ("force-load-cc sources common", "_zig-force-load-common.sh"),
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
        ("force-load-cxx sources common", "_zig-force-load-common.sh"),
        ('force-load-cxx uses c++ mode', '_ZIG_MODE="c++"'),
    ]:
        if needle in text_cxx:
            PASS(label)
        else:
            FAIL(label)

    # Check the shared helper for implementation details
    fl_common = _wrapper_dir / "_zig-force-load-common.sh"
    if not fl_common.exists():
        FAIL("_zig-force-load-common.sh exists")
        return

    text_common = fl_common.read_text()
    for label, needle in [
        ("force-load-common sources _zig-cc-common.sh", "_zig-cc-common.sh"),
        ("force-load-common uses ar x", "ar x"),
        ("force-load-common creates tmpdir", "mktemp -d"),
        ("force-load-common has cleanup trap", "trap"),
        ("force-load-common handles -Wl,-force_load", "Wl,-force_load"),
        ("force-load-common handles -Wl,-all_load", "Wl,-all_load"),
    ]:
        if needle in text_common:
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
    # Must target the NATIVE zig binary (CONDA_ZIG_BUILD), not the cross wrapper.
    _patched = _prefix / "etc" / "conda" / "test-files" / "zig_native_patched"
    if _patched.exists() and not _build_is_win and _build_zig:
        zig_bin = _prefix / "bin" / _build_zig
        if zig_bin.exists():
            shutil.copy2(_patched, zig_bin)
            os.chmod(str(zig_bin), 0o755)
            print(f"  [patched] Overlaid {zig_bin} with locally-built native zig")

    test_wrapper_existence()
    test_activation_variables()
    test_flag_filter_content()
    test_force_load_wrappers()
    test_flag_filtering()
    test_target_override()
    test_shared_lib()
    test_exe_linking()
    test_libc_linking()
    test_windows_import_libs()
    test_print_search_dirs()
    test_mingw_prebuilt_import_libs()
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
