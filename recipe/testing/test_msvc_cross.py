"""Probe: linux-hosted x86_64-pc-windows-msvc wrapper compiles and links C and C++.

Needs CONDA_BUILD_WINSDK (accepts the Microsoft licences) and the activation
env (ZIG_CC, ZIG_CXX, ZIG_MSVC_LIBC_FILE). The exe cannot run on linux, so the
COFF import table is checked instead.
"""

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TIMEOUT_S = 900
STDERR_LINES = 20
CHRONO_FLAGS = ("-isystem", "-I", "-iquote", "-nostdinc", "-nostdlibinc", "--sysroot", "-target")

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


def _diag_file(path):
    p = Path(path)
    if not os.path.lexists(p):
        print("MSVC-CROSS diag: %s exists=False" % p)
        return
    link = os.readlink(p) if p.is_symlink() else None
    print("MSVC-CROSS diag: %s exists=True symlink=%s target=%s size=%d"
          % (p, p.is_symlink(), link, p.stat().st_size if p.exists() else -1))
    if p.is_file():
        with open(p, errors="replace") as fh:
            for line in [fh.readline() for _ in range(3)]:
                print("MSVC-CROSS diag:   | %r" % line)


def _diag_cxx(driver, src_name, td):
    """Diagnostics for the cxx link failure; output only, never raises."""
    try:
        libc = os.environ.get("ZIG_MSVC_LIBC_FILE", "")
        extra = os.environ.get("ZIG_MSVC_EXTRA_INCLUDES", "")
        first = extra.split(os.pathsep)[0].split(";")[0] if extra else ""
        sdk = Path(first).parent.parent if first else Path(".")
        print("MSVC-CROSS diag: libc_file=%s sdk=%s extra_includes=%s" % (libc, sdk, extra))
        if libc and os.path.isfile(libc):
            for line in Path(libc).read_text(errors="replace").splitlines():
                print("MSVC-CROSS diag: libc| %s" % line)
        inc = sdk / "include"
        for name in ("windows.h", "Windows.h"):
            _diag_file(inc / "um" / name)
        if inc.is_dir():
            print("MSVC-CROSS diag: include subdirs: %s"
                  % sorted(d.name for d in inc.iterdir() if d.is_dir()))
        hits = [os.path.join(r, f) for r, _, fs in os.walk(inc) for f in fs
                if f.lower() == "winapifamily.h"]
        for h in hits[:10]:
            print("MSVC-CROSS diag: winapifamily.h at %s" % h)
        if not hits:
            print("MSVC-CROSS diag: winapifamily.h NONE under %s" % inc)
        proc = subprocess.run([driver, "-v", "-o", "cxx.exe", src_name], cwd=td,
                              capture_output=True, text=True, timeout=300,
                              env=dict(os.environ, ZIG_VERBOSE_CC="1"))
        lines = ((proc.stderr or "") + "\n" + (proc.stdout or "")).splitlines()
        chrono = 0
        for line in lines:
            if "chrono.cpp" in line and chrono < 2:
                chrono += 1
                try:
                    toks = shlex.split(line)
                except ValueError:
                    toks = line.split()
                for i, tok in enumerate(toks[:-1]):
                    if tok in CHRONO_FLAGS:
                        print("MSVC-CROSS diag: chrono| %s %s" % (tok, toks[i + 1]))
                print("MSVC-CROSS diag: chrono| line %s" % line[:300])
        inlist, cc1 = False, 0
        for line in lines:
            if line.startswith("#include <...> search starts here"):
                inlist = True
            elif line.startswith("End of search list."):
                inlist = False
            elif inlist:
                print("MSVC-CROSS diag: search| %s" % line.strip())
            elif "-cc1" in line and cc1 < 6:
                cc1 += 1
                print("MSVC-CROSS diag: cc1| %s" % line[:400])
    except Exception as exc:  # noqa: BLE001 - diagnostics must never raise
        print("MSVC-CROSS diag: error %s" % exc)


def _check(label, driver, src_name, src, extra, td):
    Path(td, src_name).write_text(src)
    exe = "%s.exe" % label
    proc = _run("%s link" % label, [driver, "-o", exe, src_name], td)
    if proc is None or proc.returncode != 0:
        if label == "cxx":
            _diag_cxx(driver, src_name, td)
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
        ok_cxx = _check("cxx", cxx, "hello.cpp", CXX_SRC, ("msvcp140",), td)
    return 0 if (ok_c and ok_cxx) else 1


if __name__ == "__main__":
    sys.exit(main())
