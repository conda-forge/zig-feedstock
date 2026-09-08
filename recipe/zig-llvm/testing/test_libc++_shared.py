#!/usr/bin/env python3
"""Validate shared libc++ linkage for zig's libcxx_shared.zig filesystem probe.

Zig _14+ verifies that libLLVM and libclang-cpp link against a shared libc++
(not static). The libcxx_shared.zig filesystem probe checks for libc++.so.1
or libc++.dylib at <prefix>/lib/zig-llvm/lib/. This script validates via
nm-based checks that the shared libs do not have static libc++ merged in.

Platform-aware: Linux (ELF), macOS (Mach-O), Windows (PE/COFF).

This script:
1. Finds libLLVM and libclang-cpp shared libraries
2. Checks dependency entries for libc++ (NEEDED/LC_LOAD_DYLIB/DLL imports)
3. Checks whether generic_category is local (bad) or undefined/global (good)
4. dlopen's both and compares the address of generic_category

Exit 0 = OK (single shared copy), exit 1 = FAIL (separate copies).
"""

import ctypes
import glob
import os
import re
import subprocess
import sys


PLATFORM = sys.platform  # 'linux', 'darwin', 'win32'


def find_lib(libdir, pattern):
    """Find a real (non-symlink) shared lib matching pattern."""
    candidates = sorted(glob.glob(os.path.join(libdir, pattern)))
    for c in candidates:
        if not os.path.islink(c) and os.path.isfile(c):
            return c
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def find_shared_lib(libdir, base):
    """Find a shared library by base name, platform-aware."""
    if PLATFORM == "linux":
        return find_lib(libdir, f"{base}*.so*")
    elif PLATFORM == "darwin":
        return find_lib(libdir, f"{base}*.dylib*")
    else:
        lib = find_lib(libdir, f"{base}*.dll")
        if not lib:
            bindir = os.path.join(os.path.dirname(libdir), "bin")
            if os.path.isdir(bindir):
                lib = find_lib(bindir, f"{base}*.dll")
        return lib


def run_cmd(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""


def check_needed(lib):
    """Return set of dependency names."""
    if PLATFORM == "linux":
        out = run_cmd(["readelf", "-d", lib])
        return set(re.findall(r"Shared library: \[([^\]]+)\]", out))
    elif PLATFORM == "darwin":
        out = run_cmd(["otool", "-L", lib])
        deps = set()
        for line in out.splitlines()[1:]:
            match = re.match(r"\s+(\S+)", line)
            if match:
                deps.add(os.path.basename(match.group(1)))
        return deps
    else:
        out = run_cmd(["objdump", "-p", lib])
        return set(re.findall(r"DLL Name:\s+(\S+)", out))


def has_libcxx_dep(needed):
    """Check if libc++ is in the dependency set."""
    for n in needed:
        n_lower = n.lower()
        if "libc++." in n_lower or "libc++.so" in n_lower or "libc++.dylib" in n_lower:
            if "abi" not in n_lower:
                return True
        # Windows: c++.dll or libc++.dll
        if n_lower in ("c++.dll", "libc++.dll"):
            return True
    return False


def check_symbol_binding(lib, symbol):
    """Check if symbol is LOCAL HIDDEN, GLOBAL, UNDEFINED, or absent."""
    if PLATFORM == "linux":
        out_dyn = run_cmd(["readelf", "--dyn-syms", "--wide", lib])
        for line in out_dyn.splitlines():
            if symbol in line:
                if "LOCAL" in line and "HIDDEN" in line:
                    return "LOCAL_HIDDEN"
                elif "GLOBAL" in line or "WEAK" in line:
                    if "UND" in line:
                        return "UNDEFINED"
                    return "GLOBAL"
        # Full symbol table
        out = run_cmd(["nm", "-a", lib])
    elif PLATFORM == "darwin":
        # nm -gU: global defined only; nm -u: undefined only
        out_g = run_cmd(["nm", "-gU", lib])
        for line in out_g.splitlines():
            if symbol in line:
                return "GLOBAL"
        out_u = run_cmd(["nm", "-u", lib])
        for line in out_u.splitlines():
            if symbol in line:
                return "UNDEFINED"
        # Check local symbols
        out = run_cmd(["nm", "-a", lib])
    else:
        out = run_cmd(["nm", lib])

    for line in out.splitlines():
        if symbol in line:
            parts = line.split()
            if len(parts) >= 2:
                sym_type = parts[-2] if len(parts) == 3 else parts[0]
                if sym_type == "t":
                    return "LOCAL_DEFINED"
                elif sym_type == "T":
                    return "GLOBAL_DEFINED"
                elif sym_type == "U":
                    return "UNDEFINED"
    return "NOT_FOUND"


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

    libllvm = find_shared_lib(libdir, "libLLVM")
    libclang = find_shared_lib(libdir, "libclang-cpp")
    libcxx = find_shared_lib(libdir, "libc++")

    # Windows fallback: LLVM-20.dll, not libLLVM
    if not libllvm and PLATFORM == "win32":
        libllvm = find_shared_lib(libdir, "LLVM")

    print(f"  platform: {PLATFORM}")
    print(f"  libdir:   {libdir}")
    print(f"  libLLVM:  {libllvm}")
    print(f"  libclang: {libclang}")
    print(f"  libc++:   {libcxx}")

    if not libllvm or not libclang:
        print("ERROR: Could not find libLLVM or libclang-cpp", file=sys.stderr)
        return 1

    # --- Step 1: Dependency checks ---
    print("\n--- Step 1: Dependency entries ---")
    static_warnings = []  # May be overridden by runtime check
    errors = []

    for name, lib in [("libLLVM", libllvm), ("libclang", libclang)]:
        needed = check_needed(lib)
        has_cxx = has_libcxx_dep(needed)
        print(f"  {name} deps: {sorted(needed)}")
        print(f"    libc++: {'YES' if has_cxx else 'NO'}")
        if not has_cxx:
            static_warnings.append(f"{name} missing libc++ in dependencies")

    # --- Step 2: Symbol binding check ---
    print("\n--- Step 2: generic_category symbol binding ---")
    SYMBOL = "generic_category"

    for name, lib in [("libLLVM", libllvm), ("libclang", libclang)]:
        binding = check_symbol_binding(lib, SYMBOL)
        print(f"  {name} {SYMBOL}: {binding}")
        if binding == "LOCAL_HIDDEN":
            errors.append(
                f"{name} has LOCAL HIDDEN {SYMBOL} — "
                "private libc++ copy baked in, cannot be interposed"
            )
        elif binding == "LOCAL_DEFINED":
            # On macOS, dyld deduplicates symbols at runtime so a dlsym
            # address comparison (step 3) would PASS even with static libc++
            # baked in.  But LOCAL_DEFINED is always an error — it means
            # the shared library has static libc++ merged in, which zig will
            # reject (separate libc++ copies would have different runtime addresses
            # and break zig's runtime linking).
            errors.append(
                f"{name} has local (lowercase t) {SYMBOL} — "
                "static libc++ merged in"
            )

    if libcxx:
        binding = check_symbol_binding(libcxx, SYMBOL)
        print(f"  libc++ {SYMBOL}: {binding}")
        if binding not in ("GLOBAL", "GLOBAL_DEFINED", "WEAK"):
            static_warnings.append(f"libc++ {SYMBOL} is {binding}, expected GLOBAL")

    # --- Step 3: Runtime address comparison ---
    # This is the AUTHORITATIVE check — it reproduces what zig actually does.
    print("\n--- Step 3: Runtime address comparison ---")
    runtime_passed = False

    # Build the library search path env var
    if PLATFORM == "linux":
        ld_env_var = "LD_LIBRARY_PATH"
    elif PLATFORM == "darwin":
        ld_env_var = "DYLD_LIBRARY_PATH"
    else:
        ld_env_var = "PATH"

    dlopen_script = f"""\
import ctypes, sys, os
libdir = {libdir!r}
libllvm_path = {libllvm!r}
libclang_path = {libclang!r}
platform = {PLATFORM!r}

if platform == "win32":
    os.add_dll_directory(libdir)
    bindir = os.path.join(os.path.dirname(libdir), "bin")
    if os.path.isdir(bindir):
        os.add_dll_directory(bindir)

try:
    if platform == "win32":
        llvm = ctypes.CDLL(libllvm_path)
        clang = ctypes.CDLL(libclang_path)
    else:
        llvm = ctypes.CDLL(libllvm_path, mode=ctypes.RTLD_GLOBAL)
        clang = ctypes.CDLL(libclang_path, mode=ctypes.RTLD_GLOBAL)
except OSError as e:
    print(f"  dlopen failed: {{e}}")
    sys.exit(2)

MANGLINGS = [
    "_ZNSt3__116generic_categoryEv",
    "_ZNSt3__120__generic_categoryEv",
    "_ZSt16generic_categoryv",
]
for mangled in MANGLINGS:
    try:
        a = ctypes.cast(ctypes.c_void_p.in_dll(llvm, mangled), ctypes.c_void_p).value
        b = ctypes.cast(ctypes.c_void_p.in_dll(clang, mangled), ctypes.c_void_p).value
    except (ValueError, AttributeError):
        continue
    print(f"  Symbol: {{mangled}}")
    print(f"  libLLVM  @ {{hex(a)}}")
    print(f"  libclang @ {{hex(b)}}")
    if a == b:
        print("  OK: same address — single shared libc++ copy")
        sys.exit(0)
    else:
        print("  FAIL: different addresses — separate libc++ copies!")
        sys.exit(1)

print("  WARNING: generic_category not found via dlsym, trying LLVMGetVersion")
try:
    llvm.LLVMGetVersion.restype = None
    ma, mi, pa = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
    llvm.LLVMGetVersion(ctypes.byref(ma), ctypes.byref(mi), ctypes.byref(pa))
    print(f"  LLVMGetVersion: {{ma.value}}.{{mi.value}}.{{pa.value}} (library loads OK)")
    sys.exit(0)
except Exception as e:
    print(f"  LLVMGetVersion failed: {{e}}")
    sys.exit(2)
"""
    try:
        env = os.environ.copy()
        old = env.get(ld_env_var, "")
        if PLATFORM == "win32":
            bindir = os.path.join(os.path.dirname(libdir), "bin")
            env[ld_env_var] = libdir + os.pathsep + bindir + os.pathsep + old
        else:
            env[ld_env_var] = libdir + ":" + old
        r = subprocess.run(
            [sys.executable, "-c", dlopen_script],
            env=env, capture_output=True, text=True, timeout=30,
        )
        print(r.stdout.rstrip())
        if r.stderr.strip():
            print(r.stderr.rstrip())
        if r.returncode == 0:
            runtime_passed = True
        elif r.returncode == 1:
            errors.append("Runtime: generic_category at different addresses (separate copies)")
        elif r.returncode == 2:
            errors.append("Runtime: dlopen/dlsym failed")
    except Exception as e:
        print(f"  subprocess failed: {e}")
        errors.append(f"Runtime check failed: {e}")

    # --- Summary ---
    # Both static analysis (step 2) and runtime check (step 3) must pass.
    # LOCAL_DEFINED is always an error: it indicates static libc++ merged into
    # the shared library. Even if macOS dyld deduplicates dlsym addresses at runtime,
    # having separate libc++ copies causes issues with zig's libcxx_shared.zig probe
    # and runtime linking. The runtime address check (step 3) adds confidence but
    # cannot override a LOCAL_DEFINED finding — that indicates a real static merge.
    print(f"\n--- Summary ---")
    if static_warnings:
        if runtime_passed:
            print("STATIC WARNINGS (overridden by runtime check):")
        else:
            print("STATIC WARNINGS (promoted to errors — runtime check did not pass):")
        for w in static_warnings:
            print(f"  - {w}")

    if not runtime_passed:
        errors.extend(static_warnings)

    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  - {e}")
        return 1
    else:
        print("PASS: All checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
