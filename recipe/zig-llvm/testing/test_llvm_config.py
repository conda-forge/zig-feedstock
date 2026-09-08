#!/usr/bin/env python3
"""Verify llvm-config works and returns valid paths."""

import os
import subprocess
import sys


def _zig_llvm_prefix():
    """Get the zig-llvm install prefix (handles Windows Library/ convention)."""
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    if sys.platform == "win32":
        return os.path.join(prefix, "Library", "lib", "zig-llvm")
    return os.path.join(prefix, "lib", "zig-llvm")


def _find_llvm_config():
    """Find llvm-config, handling Windows where it may be a bash wrapper script."""
    base = os.path.join(_zig_llvm_prefix(), "bin", "llvm-config")
    # Try exact name first, then with .exe
    for candidate in [base, base + ".exe"]:
        if os.path.isfile(candidate):
            return candidate
    return base  # return base for error reporting


def _find_msys2_bash():
    """Find MSYS2 bash from m2-bash package (not WSL bash.exe)."""
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    # m2-bash installs to Library/usr/bin/bash.exe
    msys_bash = os.path.join(prefix, "Library", "usr", "bin", "bash.exe")
    if os.path.isfile(msys_bash):
        return msys_bash
    # Fallback: bare "bash" (may resolve to WSL — caller should check)
    return "bash"


def run_llvm_config(*args):
    llvm_config = _find_llvm_config()
    # On Windows, llvm-config may be a bash wrapper script — invoke via MSYS2 bash.
    # IMPORTANT: bare "bash" on Windows resolves to WSL bash (C:\Windows\System32\bash.exe),
    # not MSYS2 bash. We must use the explicit m2-bash path.
    if sys.platform == "win32" and not llvm_config.endswith(".exe"):
        bash = _find_msys2_bash()
        cmd = [bash, llvm_config, *args]
    else:
        cmd = [llvm_config, *args]
    try:
        r = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=10,
        )
    except FileNotFoundError as exc:
        print(f"  llvm-config {' '.join(args)} FAILED: {exc}", file=sys.stderr)
        print(f"  cmd: {cmd}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"  llvm-config {' '.join(args)} FAILED (rc={r.returncode})", file=sys.stderr)
        print(f"  stderr: {r.stderr.strip()}", file=sys.stderr)
        print(f"  stdout: {r.stdout.strip()}", file=sys.stderr)
        print(f"  cmd: {cmd}", file=sys.stderr)
        return None
    result = r.stdout.strip()
    if not result:
        print(f"  llvm-config {' '.join(args)} returned EMPTY output", file=sys.stderr)
        if r.stderr.strip():
            print(f"  stderr: {r.stderr.strip()}", file=sys.stderr)
        print(f"  cmd: {cmd}", file=sys.stderr)
        return None
    return result


def main():
    errors = []

    # Check llvm-config binary exists
    llvm_config = _find_llvm_config()
    zig_llvm_bin = os.path.join(_zig_llvm_prefix(), "bin")
    print(f"  zig-llvm bin: {zig_llvm_bin}")
    if os.path.isdir(zig_llvm_bin):
        print(f"  contents: {os.listdir(zig_llvm_bin)}")
    print(f"  llvm-config: {llvm_config} (exists={os.path.isfile(llvm_config)})")
    if not os.path.isfile(llvm_config):
        print(f"ERROR: llvm-config not found at {llvm_config}", file=sys.stderr)
        return 1

    # --version
    version = run_llvm_config("--version")
    print(f"  version:    {version}")
    if version is None:
        errors.append("llvm-config --version failed")

    # --prefix
    pfx = run_llvm_config("--prefix")
    print(f"  prefix:     {pfx}")
    if pfx is None:
        errors.append("llvm-config --prefix failed")

    # --libdir
    libdir = run_llvm_config("--libdir")
    print(f"  libdir:     {libdir}")
    if libdir is None:
        errors.append("llvm-config --libdir failed")
    elif not os.path.isdir(libdir):
        errors.append(f"libdir does not exist: {libdir}")

    # --includedir
    incdir = run_llvm_config("--includedir")
    print(f"  includedir: {incdir}")
    if incdir is None:
        errors.append("llvm-config --includedir failed")
    elif not os.path.isdir(incdir):
        errors.append(f"includedir does not exist: {incdir}")

    # --components (just check it returns something)
    components = run_llvm_config("--components")
    if components:
        comp_list = components.split()
        print(f"  components: {len(comp_list)} ({', '.join(comp_list[:10])}...)")
    else:
        errors.append("llvm-config --components returned nothing")

    if errors:
        print("\nERRORS:")
        for e in errors:
            print(f"  - {e}")
        # Diagnostic: try running llvm-config.real directly
        for suffix in [".real", ".real.exe"]:
            real = os.path.join(_zig_llvm_prefix(), "bin", f"llvm-config{suffix}")
            if os.path.isfile(real):
                print(f"\n  Diagnostic: trying {real} directly:")
                try:
                    r = subprocess.run(
                        [real, "--version"],
                        capture_output=True, text=True, timeout=10,
                    )
                    print(f"    rc={r.returncode} stdout={r.stdout.strip()!r} stderr={r.stderr.strip()!r}")
                except Exception as exc:
                    print(f"    FAILED: {exc}")
                break
        return 1

    print("PASS: llvm-config works correctly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
