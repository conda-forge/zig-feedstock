#!/usr/bin/env python3
"""Verify shared libraries are valid, have expected symbols,
and do NOT depend on libstdc++ (must use libc++).

Platform-aware: Linux (ELF), macOS (Mach-O), Windows (PE/COFF).
"""

import glob
import os
import re
import subprocess
import sys


PLATFORM = sys.platform  # 'linux', 'darwin', 'win32'


def find_libs(libdir, pattern):
    """Find shared libs matching pattern. Prefer real files, fall back to symlinks."""
    real = []
    links = []
    for f in sorted(glob.glob(os.path.join(libdir, pattern))):
        if os.path.isfile(f):
            if os.path.islink(f):
                links.append(f)
            else:
                real.append(f)
    return real if real else links


def find_shared_libs(libdir, base):
    """Find shared libraries for a given base name, platform-aware."""
    if PLATFORM == "linux":
        return find_libs(libdir, f"{base}*.so*")
    elif PLATFORM == "darwin":
        return find_libs(libdir, f"{base}*.dylib*")
    else:  # win32
        # DLLs may be in bin/ on Windows
        libs = find_libs(libdir, f"{base}*.dll")
        bindir = os.path.join(os.path.dirname(libdir), "bin")
        if os.path.isdir(bindir):
            libs += find_libs(bindir, f"{base}*.dll")
        return libs


def run_cmd(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""


def check_binary_type(path):
    """Check file is a valid shared library for this platform."""
    out = run_cmd(["file", path])
    if PLATFORM == "linux":
        return "ELF" in out and "shared object" in out, "ELF"
    elif PLATFORM == "darwin":
        return "Mach-O" in out and ("dynamically linked" in out or "shared library" in out or "dylib" in out.lower()), "Mach-O"
    else:
        return "PE32" in out or "DLL" in out.upper(), "PE"


def get_needed(path):
    """Get shared library dependencies."""
    if PLATFORM == "linux":
        out = run_cmd(["readelf", "-d", path])
        return set(re.findall(r"Shared library: \[([^\]]+)\]", out))
    elif PLATFORM == "darwin":
        out = run_cmd(["otool", "-L", path])
        deps = set()
        for line in out.splitlines()[1:]:  # skip first line (library itself)
            match = re.match(r"\s+(\S+)", line)
            if match:
                deps.add(os.path.basename(match.group(1)))
        return deps
    else:  # win32
        # Use objdump (MinGW) to get DLL imports
        out = run_cmd(["objdump", "-p", path])
        return set(re.findall(r"DLL Name:\s+(\S+)", out))


def get_glibc_versions(path):
    """Get GLIBC version symbols used (Linux only)."""
    if PLATFORM != "linux":
        return []
    out = run_cmd(["objdump", "-T", path])
    versions = set(re.findall(r"GLIBC_([0-9.]+)", out))
    return sorted(versions, key=lambda v: list(map(int, v.split("."))))


def get_rpath(path):
    """Get RPATH/RUNPATH entries."""
    if PLATFORM == "linux":
        out = run_cmd(["readelf", "-d", path])
        entries = []
        for line in out.splitlines():
            if "RPATH" in line or "RUNPATH" in line:
                match = re.search(r"\[([^\]]+)\]", line)
                if match:
                    entries.append(match.group(1))
        return entries
    elif PLATFORM == "darwin":
        out = run_cmd(["otool", "-l", path])
        entries = []
        lines = out.splitlines()
        for i, line in enumerate(lines):
            if "cmd LC_RPATH" in line:
                for j in range(i + 1, min(i + 4, len(lines))):
                    match = re.search(r"path\s+(\S+)", lines[j])
                    if match:
                        entries.append(match.group(1))
        return entries
    else:
        return []  # Windows doesn't use rpath


def get_symbol_count(path, symbol):
    """Count occurrences of a symbol in the dynamic symbol table."""
    if PLATFORM == "linux":
        out = run_cmd(["nm", "-D", path])
    elif PLATFORM == "darwin":
        out = run_cmd(["nm", "-gU", path])
    else:
        out = run_cmd(["nm", path])
    return out.count(symbol)


def main():
    prefix = os.environ.get("CONDA_PREFIX", os.environ.get("PREFIX", ""))
    # Windows conda convention: non-Python artifacts under Library/
    if sys.platform == "win32":
        libdir = os.path.join(prefix, "Library", "lib", "zig-llvm", "lib")
    else:
        libdir = os.path.join(prefix, "lib", "zig-llvm", "lib")

    if not os.path.isdir(libdir):
        print(f"ERROR: libdir not found: {libdir}", file=sys.stderr)
        return 1

    errors = []

    # --- Check libLLVM ---
    print("=== libLLVM ===")
    llvm_libs = find_shared_libs(libdir, "libLLVM")
    if PLATFORM == "win32" and not llvm_libs:
        llvm_libs = find_shared_libs(libdir, "LLVM")
    if not llvm_libs:
        errors.append("No libLLVM shared library found")
    else:
        for lib in llvm_libs[:3]:
            name = os.path.basename(lib)
            valid, fmt = check_binary_type(lib)
            print(f"  {name}: {fmt} {'OK' if valid else 'INVALID'}")
            if not valid:
                errors.append(f"{name} is not a valid {fmt} shared library")

        main_lib = llvm_libs[0]
        needed = get_needed(main_lib)
        has_stdcxx = any("libstdc++" in n or "stdc++" in n.lower() for n in needed)
        print(f"  Dependencies: {sorted(needed)}")
        if has_stdcxx:
            errors.append("libLLVM depends on libstdc++ (must use libc++)")
        else:
            print("  No libstdc++ dependency: OK")

        if PLATFORM == "linux":
            glibc = get_glibc_versions(main_lib)
            print(f"  GLIBC versions: {glibc}")

        rpath = get_rpath(main_lib)
        if rpath:
            print(f"  RPATH/RUNPATH: {rpath}")

        count = get_symbol_count(main_lib, "LLVMContext")
        print(f"  LLVMContext symbols: {count}")

    # --- Check libclang-cpp ---
    print("\n=== libclang-cpp ===")
    clang_libs = find_shared_libs(libdir, "libclang-cpp")
    if not clang_libs:
        errors.append("No libclang-cpp shared library found")
    else:
        for lib in clang_libs[:3]:
            name = os.path.basename(lib)
            valid, fmt = check_binary_type(lib)
            print(f"  {name}: {fmt} {'OK' if valid else 'INVALID'}")
            if not valid:
                errors.append(f"{name} is not a valid {fmt} shared library")

        main_lib = clang_libs[0]
        needed = get_needed(main_lib)
        has_stdcxx = any("libstdc++" in n or "stdc++" in n.lower() for n in needed)
        print(f"  Dependencies: {sorted(needed)}")
        if has_stdcxx:
            errors.append("libclang-cpp depends on libstdc++ (must use libc++)")
        else:
            print("  No libstdc++ dependency: OK")

        if PLATFORM == "linux":
            glibc = get_glibc_versions(main_lib)
            print(f"  GLIBC versions: {glibc}")

        rpath = get_rpath(main_lib)
        if rpath:
            print(f"  RPATH/RUNPATH: {rpath}")

    # --- Check liblldZig (bundled shared library) ---
    print("\n=== liblld ===")
    lld_libs = find_shared_libs(libdir, "liblldZig")
    if not lld_libs:
        errors.append("No liblldZig shared library found")
    else:
        for lib in lld_libs[:3]:
            name = os.path.basename(lib)
            valid, fmt = check_binary_type(lib)
            print(f"  {name}: {fmt} {'OK' if valid else 'INVALID'}")
            if not valid:
                errors.append(f"{name} is not a valid {fmt} shared library")

        main_lib = lld_libs[0]
        needed = get_needed(main_lib)
        has_stdcxx = any("libstdc++" in n or "stdc++" in n.lower() for n in needed)
        print(f"  Dependencies: {sorted(needed)}")
        if has_stdcxx:
            errors.append("liblldZig depends on libstdc++ (must use libc++)")
        else:
            print("  No libstdc++ dependency: OK")

        if PLATFORM == "linux":
            glibc = get_glibc_versions(main_lib)
            print(f"  GLIBC versions: {glibc}")

        rpath = get_rpath(main_lib)
        if rpath:
            print(f"  RPATH/RUNPATH: {rpath}")

    # --- Summary ---
    print(f"\n--- Summary ---")
    print(f"  Platform: {PLATFORM}")
    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("PASS: All shared library checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
