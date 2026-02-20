#!/usr/bin/env python
"""
Test script for zig wrapper validation.
Validates triplet-prefixed wrappers (zig_$TG_).

Tests:
1. Wrapper existence and functionality
2. Compilation with wrapper
3. Archive creation

NOTE: No conda-zig-* generic wrappers (unlike OCaml, zig doesn't bake paths).
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run_command(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run command and capture output."""
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def get_bin_dir() -> Path:
    """Get the bin directory for the current platform."""
    prefix = Path(os.environ["CONDA_PREFIX"])
    if sys.platform == "win32":
        return prefix / "Library" / "bin"
    return prefix / "bin"


def find_available_wrappers() -> dict[str, Path]:
    """Find available zig wrappers in the environment."""
    bin_dir = get_bin_dir()
    wrappers = {}

    # Check for triplet-prefixed wrappers (from zig_$TG_)
    # Look for patterns like x86_64-conda-linux-gnu-zig-cc
    for f in bin_dir.iterdir():
        if f.is_file():
            name = f.name
            if sys.platform == "win32":
                name = name.replace(".bat", "").replace(".cmd", "")
            if "-zig-cc" in name:
                wrappers["triplet-cc"] = f
            elif "-zig-c++" in name:
                wrappers["triplet-cxx"] = f
            elif "-zig-ar" in name:
                wrappers["triplet-ar"] = f

    return wrappers


def test_wrapper_version(name: str, path: Path) -> bool:
    """Test that wrapper can execute --version."""
    try:
        result = run_command([str(path), "--version"], check=False)
        success = result.returncode == 0 and "zig" in result.stdout.lower()
        print(f"  {'✓' if success else '✗'} {name} --version")
        if not success:
            print(f"      stdout: {result.stdout[:100]}")
            print(f"      stderr: {result.stderr[:100]}")
        return success
    except Exception as e:
        print(f"  ✗ {name} failed: {e}")
        return False


def test_compilation(cc_path: Path) -> bool:
    """Test compilation with a zig cc wrapper."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Create a simple C file
        c_file = tmpdir / "test.c"
        c_file.write_text("int main(void) { return 0; }\n")

        obj_file = tmpdir / "test.o"

        try:
            result = run_command([str(cc_path), "-c", str(c_file), "-o", str(obj_file)], check=False)
            success = result.returncode == 0 and obj_file.exists()
            print(f"  {'✓' if success else '✗'} {cc_path.name} can compile C code")
            if not success:
                print(f"      returncode: {result.returncode}")
                print(f"      stderr: {result.stderr[:200]}")
            return success
        except Exception as e:
            print(f"  ✗ Compilation test failed: {e}")
            return False


def test_archive_creation(cc_path: Path, ar_path: Path) -> bool:
    """Test archive creation with zig ar wrapper."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # First create an object file
        c_file = tmpdir / "test.c"
        c_file.write_text("int foo(void) { return 42; }\n")
        obj_file = tmpdir / "test.o"

        try:
            # Compile to object
            result = run_command([str(cc_path), "-c", str(c_file), "-o", str(obj_file)], check=False)
            if result.returncode != 0 or not obj_file.exists():
                print("  ✗ Archive test: prerequisite compilation failed")
                return False

            # Create archive
            archive_file = tmpdir / "test.a"
            result = run_command([str(ar_path), "rcs", str(archive_file), str(obj_file)], check=False)
            success = result.returncode == 0 and archive_file.exists()
            print(f"  {'✓' if success else '✗'} {ar_path.name} can create archives")
            if not success:
                print(f"      returncode: {result.returncode}")
                print(f"      stderr: {result.stderr[:200]}")
            return success
        except Exception as e:
            print(f"  ✗ Archive test failed: {e}")
            return False


def main():
    print("=" * 60)
    print("Zig Wrapper Validation Tests")
    print("=" * 60)

    if "CONDA_PREFIX" not in os.environ:
        print("ERROR: CONDA_PREFIX not set. Run this in an activated conda environment.")
        return 1

    print(f"\nCONDA_PREFIX: {os.environ['CONDA_PREFIX']}")
    print(f"Platform: {sys.platform}")

    # Find available wrappers
    wrappers = find_available_wrappers()

    if not wrappers:
        print("\nERROR: No zig wrappers found!")
        return 1

    print(f"\nFound wrappers: {list(wrappers.keys())}")

    results = []

    # Test version for cc/cxx wrappers
    print("\n--- Test 1: Wrapper Version ---")
    for name, path in wrappers.items():
        if "cc" in name.lower() or "cxx" in name.lower():
            results.append(("version", name, test_wrapper_version(name, path)))

    # Test compilation
    print("\n--- Test 2: Compilation ---")
    cc_path = wrappers.get("triplet-cc")
    if cc_path:
        results.append(("compile", cc_path.name, test_compilation(cc_path)))
    else:
        print("  ⊘ No cc wrapper found, skipping compilation test")

    # Test archive creation
    print("\n--- Test 3: Archive Creation ---")
    ar_path = wrappers.get("triplet-ar")
    if cc_path and ar_path:
        results.append(("archive", ar_path.name, test_archive_creation(cc_path, ar_path)))
    else:
        print("  ⊘ Missing cc or ar wrapper, skipping archive test")

    # Summary
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)

    passed = sum(1 for _, _, success in results if success)
    total = len(results)

    print(f"\nPassed: {passed}/{total}")

    if passed == total:
        print("\n✓ All tests passed!")
        return 0
    else:
        print("\n✗ Some tests failed:")
        for test_type, wrapper, success in results:
            if not success:
                print(f"  - {test_type}: {wrapper}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
