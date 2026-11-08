"""Probe: linux-hosted x86_64-pc-windows-msvc wrapper compiles and links C and C++.

Needs CONDA_BUILD_WINSDK (accepts the Microsoft licences) and the activation
env (ZIG_CC, ZIG_CXX, ZIG_MSVC_LIBC_FILE). The exe cannot run on linux, so the
COFF import table is checked instead.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TIMEOUT_S = 900
STDERR_LINES = 20

C_SRC = '#include <stdio.h>\nint main(void) { puts("hi"); return 0; }\n'
CXX_SRC = (
    "#include <iostream>\n"
    "#include <string>\n"
    'int main() { std::string s = "hi"; std::cout << s << std::endl; return 0; }\n'
)
CRT_IMPORTS = ("vcruntime140", "api-ms-win-crt", "ucrtbase")


def _run(name, cmd, cwd):
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        print("MSVC-CROSS %s: FAIL rc=timeout" % name)
        return None
    if proc.returncode == 0:
        print("MSVC-CROSS %s: PASS" % name)
    else:
        print("MSVC-CROSS %s: FAIL rc=%d" % (name, proc.returncode))
        print("\n".join((proc.stderr or "").splitlines()[:STDERR_LINES]))
    return proc


def _imports(exe, td):
    tool = shutil.which("llvm-readobj")
    cmd = [tool, "--coff-imports", exe] if tool else None
    if cmd is None:
        tool = shutil.which("llvm-objdump")
        cmd = [tool, "--private-headers", exe] if tool else None
    if cmd is None:
        print("MSVC-CROSS imports: FAIL no llvm-readobj/llvm-objdump")
        return None
    proc = _run("imports", cmd, td)
    return None if proc is None or proc.returncode != 0 else proc.stdout.lower()


def _winsdk_lacks_winapifamily():
    extra = os.environ.get("ZIG_MSVC_EXTRA_INCLUDES", "")
    first = extra.split(os.pathsep)[0].split(";")[0] if extra else ""
    if not first:
        return False
    inc = Path(first).parent.parent / "include"
    return not any(f.lower() == "winapifamily.h" for _, _, fs in os.walk(inc) for f in fs)


def _check(label, driver, src_name, src, extra, td):
    Path(td, src_name).write_text(src)
    exe = "%s.exe" % label
    proc = _run("%s link" % label, [driver, "-o", exe, src_name], td)
    if proc is None or proc.returncode != 0:
        return False
    out = _imports(exe, td)
    if out is None:
        return False
    wanted = CRT_IMPORTS + extra
    if not any(w in out for w in CRT_IMPORTS) or not all(w in out for w in extra):
        print("MSVC-CROSS %s imports: FAIL none of %s" % (label, wanted))
        return False
    print("MSVC-CROSS %s imports: PASS" % label)
    return True


def main():
    if not os.environ.get("CONDA_BUILD_WINSDK"):
        print("MSVC-CROSS: SKIP CONDA_BUILD_WINSDK unset")
        return 0
    cc = os.environ.get("ZIG_CC")
    cxx = os.environ.get("ZIG_CXX")
    if not (cc and cxx and os.environ.get("ZIG_MSVC_LIBC_FILE")):
        print("MSVC-CROSS: FAIL activation env missing (ZIG_CC/ZIG_CXX/ZIG_MSVC_LIBC_FILE)")
        return 1
    with tempfile.TemporaryDirectory() as td:
        ok_c = _check("c", cc, "hello.c", C_SRC, (), td)
        if _winsdk_lacks_winapifamily():
            print("SKIP cxx link: winsdk has no winapifamily.h (clang-win-activation-feedstock PR 76)")
            ok_cxx = True
        else:
            ok_cxx = _check("cxx", cxx, "hello.cpp", CXX_SRC, ("msvcp140",), td)
    return 0 if (ok_c and ok_cxx) else 1


if __name__ == "__main__":
    sys.exit(main())
