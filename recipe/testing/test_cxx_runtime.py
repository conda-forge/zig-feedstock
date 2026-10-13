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

Exit codes: 0 = all cases passed or skipped, 1 = at least one FAIL.
"""

from __future__ import annotations

import os
import shutil
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


def _with_env(extra: dict[str, str], fn):
    saved = {k: os.environ.get(k) for k in extra}
    os.environ.update(extra)
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


def main() -> int:
    print("=== zig-cxx GCC libstdc++ runtime tests ===")
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

    with tempfile.TemporaryDirectory() as tds:
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
