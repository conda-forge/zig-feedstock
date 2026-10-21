#!/usr/bin/env python3
"""
<triplet>-zig-cxx on linux-gnu must link C++ against conda-forge's GCC
libstdc++ (zig-cc-unix.c STEP 10a), not zig's bundled libc++.

  ARGV:     wrapper execs `zig cc -nostdlib++ ... <gccdir>/libstdc++.so`
  OPTOUT:   ZIG_CXX_RUNTIME=zig keeps `zig c++`
  BUILD:    a throwing .so and an exe (catch across the .so, std::thread,
            dynamic_cast) compile and link through the wrapper
  NEEDED:   DT_NEEDED has libstdc++.so.6 and libgcc_s.so.1, no libc++
  NOLIBCXX: no std::__1 (St3__1) symbols in either output
  RUN:      exe runs and prints CAUGHT/OK (only when the target is runnable)

x86_64-w64-mingw32 on a windows host (_main_win) links libstdc++.dll.a:
  ARGV/OPTOUT/BUILD as above; IMPORTS (llvm-objdump -p: libstdc++-6.dll,
  libgcc_s_seh-1.dll) replaces NEEDED; NOLIBCXX via llvm-nm -C; RUN uses PATH.

Exit codes: 0 = all cases passed or skipped, 1 = at least one FAIL.
"""

from __future__ import annotations

import os
import platform
import shutil
import struct
import sys
import tempfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from _test_utils import (
    _run,
    can_execute_target,
    resolve_test_prefix,
    setup_zig_global_cache_dir,
    timed_out,
)
from test_glibc_as_needed import read_dt_needed

setup_zig_global_cache_dir()

_host = os.environ.get("CONDA_ZIG_HOST", "")
_xtriplet = _host.removesuffix("-zig")
# Only emulated lanes run a foreign wrapper; cross-compiler lanes run a build-arch one.
_triplet = _xtriplet if os.environ.get("QEMU_EXECVE") else ""
_LINK_TIMEOUT_S = 900

_THROWER = (
    '#include <stdexcept>\n'
    '#include <string>\n'
    'struct Base { virtual ~Base() {} };\n'
    'struct Derived : Base { int v = 42; };\n'
    '__attribute__((visibility("default")))\n'
    'void thrower(int x) { throw std::runtime_error("boom" + std::to_string(x)); }\n'
    '__attribute__((visibility("default")))\n'
    'Base* make_base() { return new Derived(); }\n'
)

_MAIN = (
    '#include <iostream>\n'
    '#include <memory>\n'
    '#include <stdexcept>\n'
    '#include <thread>\n'
    'struct Base { virtual ~Base() {} };\n'
    'struct Derived : Base { int v = 42; };\n'
    'void thrower(int);\n'
    'Base* make_base();\n'
    'int main() {\n'
    '  try { thrower(1); } catch (const std::exception& e) {\n'
    '    std::cout << "CAUGHT " << e.what() << std::endl;\n'
    '  }\n'
    '  int n = 0;\n'
    '  std::thread t([&] { n = 3; });\n'
    '  t.join();\n'
    '  bool tok = false;\n'
    '  std::thread t2([&] {\n'
    '    try { throw std::runtime_error("t"); } catch (const std::exception&) { tok = true; }\n'
    '  });\n'
    '  t2.join();\n'
    '  if (tok) std::cout << "THREAD OK" << std::endl;\n'
    '  std::unique_ptr<Base> b(make_base());\n'
    '  auto* d = dynamic_cast<Derived*>(b.get());\n'
    '  if (!d || d->v != 42 || n != 3) return 2;\n'
    '  std::cout << "OK" << std::endl;\n'
    '  return 0;\n'
    '}\n'
)

_failed = False


def _report(case: str, ok: bool, detail: str) -> bool:
    global _failed
    print(f"LIBSTDCXX-{case}: {'PASS' if ok else 'FAIL'} ({detail})")
    if not ok:
        _failed = True
    return ok


def _skip(case: str, why: str) -> None:
    print(f"LIBSTDCXX-{case}: SKIP ({why})")


def _tail(r) -> str:
    return "TIMEOUT" if timed_out(r) else "\n".join(r.stderr.splitlines()[-15:])


def _with_env(extra: dict[str, str | None], fn):
    saved = {k: os.environ.get(k) for k in extra}
    for k, v in extra.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        return fn()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _vkey(p: Path) -> tuple[int, ...]:
    try:
        return tuple(int(x) for x in p.name.split("."))
    except ValueError:
        return (-1,)


def _find_tool(prefix: Path, name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    cand = prefix / "bin" / name
    return str(cand) if cand.is_file() else None


def _gcc_dir(prefix: Path) -> Path | None:
    found = sorted((p.parent.parent for p in
                    prefix.glob(f"lib/gcc/{_xtriplet}/*/include/c++")), key=_vkey)
    return found[-1] if found else None


def _argv_cases(cxx: str, td: Path) -> None:
    def argv(extra: dict[str, str]) -> list[str]:
        env = {"ZIG_WRAPPER_PRINT_ARGV": "1", **extra}
        r = _with_env(env, lambda: _run([cxx, "main.cpp", "-o", "probe"], cwd=td,
                                        timeout=60, target=_triplet or None))
        return r.stdout.splitlines() if r.returncode == 0 else []

    a = argv({"ZIG_CXX_RUNTIME": ""})
    ok = (len(a) > 1 and a[1] == "cc" and "-nostdlib++" in a
          and any(x.endswith("/libstdc++.so") for x in a))
    _report("ARGV", ok, " ".join(a[1:]) or "wrapper failed")

    a = argv({"ZIG_CXX_RUNTIME": "zig"})
    ok = len(a) > 1 and a[1] == "c++" and "-nostdlib++" not in a
    _report("OPTOUT", ok, " ".join(a[1:]) or "wrapper failed")


def _build(cxx: str, td: Path) -> bool:
    for label, args in (
        ("so", ["-std=c++17", "-shared", "-fPIC", "thrower.cpp", "-o", "libthrower.so"]),
        ("exe", ["-std=c++17", "main.cpp", "libthrower.so", "-o", "probe"]),
    ):
        r = _run([cxx, *args], cwd=td, timeout=_LINK_TIMEOUT_S, target=_triplet or None)
        if r.returncode != 0:
            return _report("BUILD", False, f"{label} rc={r.returncode} {_tail(r)}")
    return _report("BUILD", True, "libthrower.so + probe")


def _check_outputs(td: Path) -> None:
    so, exe = td / "libthrower.so", td / "probe"
    n_so, n_exe = read_dt_needed(so), read_dt_needed(exe)
    print(f"  libthrower.so NEEDED: {' '.join(n_so)}")
    print(f"  probe NEEDED: {' '.join(n_exe)}")
    libcxx = [n for n in n_so + n_exe if n.startswith("libc++")]
    ok = ("libstdc++.so.6" in n_so and "libstdc++.so.6" in n_exe
          and "libgcc_s.so.1" in n_so + n_exe and not libcxx)
    _report("NEEDED", ok, f"libc++ entries: {libcxx}" if libcxx
            else "libstdc++.so.6 + libgcc_s.so.1" if ok else "missing GNU runtime")

    hits = [p.name for p in (so, exe) if b"St3__1" in p.read_bytes()]
    _report("NOLIBCXX", not hits, f"St3__1 in {hits}" if hits else "no std::__1 symbols")


def _run_case(td: Path, cc: str | None, gcc: Path) -> None:
    if not can_execute_target(_xtriplet, cc):
        _skip("RUN", f"{_xtriplet} not runnable here; outputs parsed only")
        return
    env = {"LD_LIBRARY_PATH": f"{td}:{gcc}"}
    r = _with_env(env, lambda: _run([str(td / "probe")], cwd=td, timeout=120,
                                    target=_xtriplet))
    ok = r.returncode == 0 and "CAUGHT boom1" in r.stdout and "OK" in r.stdout
    _report("RUN", ok, f"rc={r.returncode} {r.stdout.strip()!r}"
            + ("" if ok else f" {_tail(r)}"))


_WIN_TRIPLET = "x86_64-w64-mingw32"

_THROWER_WIN = (
    '#include <stdexcept>\n'
    '#include <string>\n'
    'struct Base { virtual ~Base() {} };\n'
    'struct Derived : Base { int v = 42; };\n'
    '__declspec(dllexport) void thrower(int x)'
    ' { throw std::runtime_error("boom" + std::to_string(x)); }\n'
    '__declspec(dllexport) Base* make_base() { return new Derived(); }\n'
)

_PLAIN = '#include <iostream>\nint main() { std::cout << "OK" << std::endl; }\n'

_GNU_DLLS = ("libstdc++-6.dll", "libgcc_s_seh-1.dll")


def _find_win_tool(prefix: Path, name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    cand = prefix / "Library" / "bin" / f"{name}.exe"
    return str(cand) if cand.is_file() else None


def _dll_imports(objdump: str, path: Path) -> list[str]:
    r = _run([objdump, "-p", str(path)], timeout=60)
    return [ln.split("DLL Name:", 1)[1].strip().lower()
            for ln in r.stdout.splitlines() if "DLL Name:" in ln]


def _win_argv(cxx: str, td: Path, extra: dict[str, str | None]) -> list[str]:
    env = {"ZIG_WRAPPER_PRINT_ARGV": "1", **extra}
    r = _with_env(env, lambda: _run([cxx, "main.cpp", "-o", "probe.exe"], cwd=td,
                                    timeout=60))
    return [ln.rstrip("\r") for ln in r.stdout.splitlines()] if r.returncode == 0 else []


def _win_default_case(cxx: str, td: Path) -> None:
    a = _win_argv(cxx, td, {"ZIG_CXX_RUNTIME": "", "ZIG_WIN_ABI": None})
    route = [x for x in a if x == "-nostdlib++" or "libstdc++.dll.a" in x]
    ok = (len(a) > 1 and any(x.endswith("-windows-msvc") for x in a) and not route)
    _report("DEFAULT", ok, " ".join(a[1:]) or "wrapper failed")


def _win_argv_optout(cxx: str, td: Path) -> None:
    a = _win_argv(cxx, td, {"ZIG_CXX_RUNTIME": "", "ZIG_WIN_ABI": "gnu"})
    ok = (len(a) > 1 and a[1] == "cc" and "-nostdlib++" in a
          and any(x.replace("\\", "/").endswith("libstdc++.dll.a") for x in a)
          and any(p == "-target" and q == "x86_64-windows-gnu" for p, q in zip(a, a[1:])))
    _report("ARGV", ok, " ".join(a[1:]) or "wrapper failed")

    r = _with_env({"ZIG_CXX_RUNTIME": "zig", "ZIG_WIN_ABI": "gnu"}, lambda: _run(
        [cxx, "-std=c++17", "plain.cpp", "-o", "plain.exe"], cwd=td,
        timeout=_LINK_TIMEOUT_S))
    if r.returncode != 0:
        _report("OPTOUT", False, f"build rc={r.returncode} {_tail(r)}")
    else:
        return _optout_imports(td)


def _optout_imports(td: Path) -> None:
    objdump = _find_win_tool(resolve_test_prefix("Library/bin"), "llvm-objdump")
    if not objdump:
        _skip("OPTOUT", "llvm-objdump not found")
        return
    imps = _dll_imports(objdump, td / "plain.exe")
    _report("OPTOUT", "libstdc++-6.dll" not in imps, f"imports: {' '.join(imps)}")


def _win_build(cxx: str, td: Path) -> bool:
    for label, args in (
        ("dll", ["-std=c++17", "-shared", "thrower.cpp", "-o", "libthrower.dll",
                 "-Wl,--out-implib,libthrower.dll.a"]),
        ("exe", ["-std=c++17", "main.cpp", "libthrower.dll.a", "-o", "probe.exe"]),
    ):
        r = _with_env({"ZIG_WIN_ABI": "gnu"},
                      lambda: _run([cxx, *args], cwd=td, timeout=_LINK_TIMEOUT_S))
        if r.returncode != 0:
            return _report("BUILD", False, f"{label} rc={r.returncode} {_tail(r)}")
    return _report("BUILD", True, "libthrower.dll + probe.exe")


def _win_check_outputs(prefix: Path, td: Path) -> None:
    dll, exe = td / "libthrower.dll", td / "probe.exe"
    objdump = _find_win_tool(prefix, "llvm-objdump")
    if not objdump:
        _skip("IMPORTS", "llvm-objdump not found")
    else:
        i_dll, i_exe = _dll_imports(objdump, dll), _dll_imports(objdump, exe)
        print(f"  libthrower.dll imports: {' '.join(i_dll)}")
        print(f"  probe.exe imports: {' '.join(i_exe)}")
        missing = [d for d in _GNU_DLLS if d not in i_dll + i_exe]
        ok = "libstdc++-6.dll" in i_dll and "libstdc++-6.dll" in i_exe and not missing
        _report("IMPORTS", ok, "libstdc++-6.dll + libgcc_s_seh-1.dll" if ok
                else f"missing {missing or 'libstdc++-6.dll in dll/exe'}")

    nm = _find_win_tool(prefix, "llvm-nm")
    if not nm:
        _skip("NOLIBCXX", "llvm-nm not found")
        return
    hits = [p.name for p in (dll, exe)
            if "std::__1" in _run([nm, "-C", str(p)], timeout=60).stdout]
    _report("NOLIBCXX", not hits, f"std::__1 in {hits}" if hits else "no std::__1 symbols")


def _is_x64_pe(p: Path) -> bool:
    try:
        b = p.read_bytes()[:4096]
        off = struct.unpack_from("<I", b, 0x3C)[0]
        return struct.unpack_from("<H", b, off + 4)[0] == 0x8664
    except (OSError, struct.error):
        return False


def _find_x64_libgcc(prefix: Path) -> tuple[Path | None, list[Path]]:
    lib = prefix / "Library"
    dirs = [lib / "bin", lib / "lib", lib / "x86_64-w64-mingw32" / "sysroot" / "usr" / "bin"]
    gcc = sorted((p.parent.parent for p in
                  lib.glob(f"lib/gcc/{_WIN_TRIPLET}/*/include/c++")), key=_vkey)
    if gcc:
        dirs.append(gcc[-1])
    for d in dirs:
        if _is_x64_pe(d / "libgcc_s_seh-1.dll"):
            return d, dirs
    return None, dirs


def _win_run_case(prefix: Path, td: Path) -> None:
    gdir, searched = _find_x64_libgcc(prefix)
    if gdir is None:
        _skip("RUN", f"no x86_64 libgcc_s_seh-1.dll in {[str(d) for d in searched]}; "
              f"host machine={platform.machine()}")
        return
    path = os.pathsep.join([str(td), str(gdir), str(prefix / "Library" / "bin"),
                            os.environ.get("PATH", "")])
    r = _with_env({"PATH": path, "ZIG_WIN_ABI": "gnu"},
                  lambda: _run([str(td / "probe.exe")], cwd=td, timeout=120))
    ok = (r.returncode == 0 and "CAUGHT boom1" in r.stdout and "THREAD OK" in r.stdout
          and "OK" in r.stdout)
    _report("RUN", ok, f"rc={r.returncode} {r.stdout.strip()!r}"
            + ("" if ok else f" {_tail(r)}"))


_MSVC_PROBE = (
    '#include <iostream>\n'
    '#include <string>\n'
    '#include <thread>\n'
    '#include <stdexcept>\n'
    'int main() {\n'
    '  std::string s = "msvc";\n'
    '  int n = 0;\n'
    '  std::thread t([&] { n = 1; });\n'
    '  t.join();\n'
    '  try { throw std::runtime_error(s); } catch (const std::exception& e) {\n'
    '    std::cout << "CAUGHT " << e.what() << " " << n << std::endl;\n'
    '  }\n'
    '  return 0;\n'
    '}\n'
)


def _msvc_probe(cxx: str, td: Path) -> None:
    """Report-only: never sets _failed."""
    (td / "msvc.cpp").write_text(_MSVC_PROBE)

    def step(label: str, cmd: list[str]) -> bool:
        r = _with_env({"ZIG_WIN_ABI": "msvc"},
                      lambda: _run(cmd, cwd=td, timeout=_LINK_TIMEOUT_S))
        if r.returncode == 0:
            print(f"LIBSTDCXX-MSVC: INFO {label} rc=0 {r.stdout.strip()!r}")
            return True
        err = "TIMEOUT" if timed_out(r) else "\n".join(r.stderr.splitlines()[:20])
        print(f"LIBSTDCXX-MSVC: WARN {label} rc={r.returncode:#x}\n{err}")
        return False

    if step("compile", [cxx, "-std=c++17", "-c", "msvc.cpp", "-o", "msvc.obj"]) and \
            step("link", [cxx, "msvc.obj", "-o", "msvc.exe"]):
        step("run", [str(td / "msvc.exe")])


def _main_win() -> int:
    prefix = resolve_test_prefix("Library/bin")
    cxx = _find_win_tool(prefix, f"{_xtriplet}-zig-cxx")
    if not cxx:
        return int(not _report("WRAPPER", False, f"{_xtriplet}-zig-cxx not found"))
    print(f"  wrapper = {cxx}")
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tds:
        td = Path(tds)
        (td / "thrower.cpp").write_text(_THROWER_WIN)
        (td / "main.cpp").write_text(_MAIN)
        (td / "plain.cpp").write_text(_PLAIN)
        _win_default_case(cxx, td)
        _win_argv_optout(cxx, td)
        if _win_build(cxx, td):
            _win_check_outputs(prefix, td)
            _win_run_case(prefix, td)
        _msvc_probe(cxx, td)
    return 1 if _failed else 0


def main() -> int:
    print("=== zig-cxx GCC libstdc++ runtime tests ===")
    if _xtriplet == _WIN_TRIPLET and os.name == "nt":
        return _main_win()
    if "-linux-gnu" not in _xtriplet:
        _skip("ALL", f"linux-gnu targets only (CONDA_ZIG_HOST={_host!r})")
        return 0
    if _xtriplet.startswith("s390x-"):
        print("LIBSTDCXX: SKIP (no conda-forge libstdcxx-devel for s390x; "
              "zig libc++ kept)")
        return 0
    prefix = resolve_test_prefix("bin")
    cxx = _find_tool(prefix, f"{_xtriplet}-zig-cxx")
    if not cxx:
        return int(not _report("WRAPPER", False, f"{_xtriplet}-zig-cxx not found"))
    gcc = _gcc_dir(resolve_test_prefix("lib/gcc"))
    if not gcc:
        return int(not _report("GCCDIR", False, f"no lib/gcc/{_xtriplet}/*/include/c++"))
    print(f"  wrapper = {cxx}\n  gccdir = {gcc}")
    if _triplet:
        print("  note: emulated lane; the wrapper runs under qemu")

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tds:
        td = Path(tds)
        (td / "thrower.cpp").write_text(_THROWER)
        (td / "main.cpp").write_text(_MAIN)
        _argv_cases(cxx, td)
        if _build(cxx, td):
            _check_outputs(td)
            _run_case(td, _find_tool(prefix, f"{_xtriplet}-zig-cc"), gcc)
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
