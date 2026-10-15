"""Probe: x86_64-windows-msvc C++17 (string, thread, exception) compiles, links, runs.

Invokes the build-arch zig directly (no triplet wrapper); link builds libc++.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET = "x86_64-windows-msvc"
TIMEOUT_S = 900
STDERR_LINES = 20

SOURCE = r"""
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

int main() {
    std::string s = "msvc";
    std::thread t([&s] { s += "-thread"; });
    t.join();
    if (s != "msvc-thread") return 1;
    try {
        throw std::runtime_error("boom");
    } catch (const std::runtime_error& e) {
        if (std::string(e.what()) != "boom") return 2;
    }
    std::cout << "OK " << s << std::endl;
    return 0;
}
"""


def _has_msvc():
    if sys.platform != "win32":
        return True
    if os.environ.get("VCINSTALLDIR") or os.environ.get("VSINSTALLDIR"):
        return True
    pf = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    return (Path(pf) / "Microsoft Visual Studio").is_dir()


def _step(name, cmd, cwd):
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT_S
        )
    except subprocess.TimeoutExpired:
        print("MSVC-LIBCXX %s: FAIL rc=timeout" % name)
        return None
    if proc.returncode == 0:
        print("MSVC-LIBCXX %s: PASS" % name)
    else:
        print("MSVC-LIBCXX %s: FAIL rc=%d" % (name, proc.returncode))
        lines = (proc.stderr or "").replace("\r\n", "\n").splitlines()
        print("\n".join(lines[:STDERR_LINES]))
    return proc


def main():
    build_zig = os.environ.get("CONDA_ZIG_BUILD")
    if not build_zig:
        print("MSVC-LIBCXX: SKIP CONDA_ZIG_BUILD unset")
        return 0
    zig = shutil.which(build_zig)
    if not zig:
        print("MSVC-LIBCXX: SKIP %s not on PATH" % build_zig)
        return 0
    if not _has_msvc():
        print("MSVC-LIBCXX: SKIP no Visual Studio installation detected")
        return 0

    with tempfile.TemporaryDirectory() as td:
        Path(td, "msvc.cpp").write_text(SOURCE)
        base = [zig, "c++", "-target", TARGET, "-std=c++17"]

        proc = _step("compile", base + ["-c", "msvc.cpp", "-o", "msvc.obj"], td)
        if proc is None or proc.returncode != 0:
            return 1
        proc = _step("link", base + ["msvc.obj", "-o", "msvc.exe"], td)
        if proc is None or proc.returncode != 0:
            return 1

        exe = str(Path(td, "msvc.exe"))
        proc = _step("run", [exe], td)
        if proc is None or proc.returncode != 0:
            return 1
        out = (proc.stdout or "").replace("\r\n", "\n")
        if "OK msvc-thread" not in out:
            print("MSVC-LIBCXX run: FAIL rc=0 unexpected output: %r" % out[:200])
            return 1
        print(out.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
