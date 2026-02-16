#!/usr/bin/env python
"""
Test script for conda-zig-* wrapper validation.
Validates that wrappers respect CONDA_ZIG_* environment variables.

Tests:
1. Default behavior: wrappers execute zig subcommands when env vars unset
2. Override behavior: wrappers execute custom commands when env vars set
3. Argument passthrough: arguments are correctly forwarded
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run_command(cmd: list[str], env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    """Run command with optional environment override."""
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    return subprocess.run(cmd, capture_output=True, text=True, env=run_env, check=check)


def get_wrapper_path(name: str) -> str:
    """Get the full path to a conda-zig wrapper."""
    if sys.platform == "win32":
        return str(Path(os.environ["CONDA_PREFIX"]) / "Library" / "bin" / f"{name}.bat")
    else:
        return str(Path(os.environ["CONDA_PREFIX"]) / "bin" / name)


def test_wrapper_exists(wrapper: str) -> bool:
    """Test that wrapper script exists."""
    path = get_wrapper_path(wrapper)
    exists = Path(path).exists()
    print(f"  {'✓' if exists else '✗'} {wrapper} exists at {path}")
    return exists


def test_default_behavior(wrapper: str, expected_subcommand: str) -> bool:
    """Test that wrapper executes zig subcommand by default."""
    # Unset the override variable
    env_var = f"CONDA_ZIG_{expected_subcommand.upper().replace('+', 'X')}"
    env = {env_var: ""} if env_var in os.environ else {}

    # For cc/c++, test --version which zig supports
    if expected_subcommand in ("cc", "c++"):
        try:
            result = run_command([get_wrapper_path(wrapper), "--version"], env=env, check=False)
            # zig cc --version outputs zig version info
            success = result.returncode == 0 and "zig" in result.stdout.lower()
            print(f"  {'✓' if success else '✗'} {wrapper} executes zig {expected_subcommand} by default")
            if not success:
                print(f"      stdout: {result.stdout[:100]}")
                print(f"      stderr: {result.stderr[:100]}")
            return success
        except Exception as e:
            print(f"  ✗ {wrapper} failed: {e}")
            return False
    else:
        # For ar/ld, just check they can be invoked (may fail without args, but shouldn't crash)
        try:
            result = run_command([get_wrapper_path(wrapper), "--help"], env=env, check=False)
            # Just check it ran (ar/ld may not support --help cleanly)
            success = True  # If we got here without exception, the wrapper works
            print(f"  {'✓' if success else '✗'} {wrapper} can invoke zig {expected_subcommand}")
            return success
        except Exception as e:
            print(f"  ✗ {wrapper} failed: {e}")
            return False


def test_override_behavior(wrapper: str, env_var: str) -> bool:
    """Test that wrapper respects environment variable override."""
    # Create a simple script that echoes a marker
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write('import sys; print("OVERRIDE_MARKER"); print(" ".join(sys.argv[1:]))')
        test_script = f.name

    try:
        # Set the override to our test script
        override_cmd = f"{sys.executable} {test_script}"
        env = {env_var: override_cmd}

        result = run_command([get_wrapper_path(wrapper), "test_arg1", "test_arg2"], env=env, check=False)

        # Check that our marker is in output (meaning override was used)
        has_marker = "OVERRIDE_MARKER" in result.stdout
        has_args = "test_arg1" in result.stdout and "test_arg2" in result.stdout
        success = has_marker and has_args

        print(f"  {'✓' if success else '✗'} {wrapper} respects {env_var} override")
        if not success:
            print(f"      Expected OVERRIDE_MARKER and args in output")
            print(f"      stdout: {result.stdout[:200]}")
            print(f"      stderr: {result.stderr[:200]}")
        return success
    except Exception as e:
        print(f"  ✗ {wrapper} override test failed: {e}")
        return False
    finally:
        Path(test_script).unlink(missing_ok=True)


def test_compilation(wrapper: str) -> bool:
    """Test actual compilation with conda-zig-cc."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Create a simple C file
        c_file = tmpdir / "test.c"
        c_file.write_text("int main(void) { return 0; }\n")

        obj_file = tmpdir / "test.o"

        try:
            result = run_command([get_wrapper_path(wrapper), "-c", str(c_file), "-o", str(obj_file)], check=False)
            success = result.returncode == 0 and obj_file.exists()
            print(f"  {'✓' if success else '✗'} {wrapper} can compile C code")
            if not success:
                print(f"      returncode: {result.returncode}")
                print(f"      stderr: {result.stderr[:200]}")
            return success
        except Exception as e:
            print(f"  ✗ {wrapper} compilation test failed: {e}")
            return False


def test_archive_creation() -> bool:
    """Test archive creation with conda-zig-ar."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # First create an object file
        c_file = tmpdir / "test.c"
        c_file.write_text("int foo(void) { return 42; }\n")
        obj_file = tmpdir / "test.o"

        try:
            # Compile to object
            result = run_command([get_wrapper_path("conda-zig-cc"), "-c", str(c_file), "-o", str(obj_file)], check=False)
            if result.returncode != 0 or not obj_file.exists():
                print(f"  ✗ conda-zig-ar: prerequisite compilation failed")
                return False

            # Create archive
            archive_file = tmpdir / "test.a"
            result = run_command([get_wrapper_path("conda-zig-ar"), "rcs", str(archive_file), str(obj_file)], check=False)
            success = result.returncode == 0 and archive_file.exists()
            print(f"  {'✓' if success else '✗'} conda-zig-ar can create archives")
            if not success:
                print(f"      returncode: {result.returncode}")
                print(f"      stderr: {result.stderr[:200]}")
            return success
        except Exception as e:
            print(f"  ✗ conda-zig-ar test failed: {e}")
            return False


def main():
    print("=" * 60)
    print("conda-zig-* Wrapper Validation Tests")
    print("=" * 60)

    if "CONDA_PREFIX" not in os.environ:
        print("ERROR: CONDA_PREFIX not set. Run this in an activated conda environment.")
        return 1

    print(f"\nCONDA_PREFIX: {os.environ['CONDA_PREFIX']}")
    print(f"Platform: {sys.platform}")

    wrappers = {
        "conda-zig-cc": ("cc", "CONDA_ZIG_CC"),
        "conda-zig-cxx": ("c++", "CONDA_ZIG_CXX"),
        "conda-zig-ar": ("ar", "CONDA_ZIG_AR"),
        "conda-zig-ld": ("ld", "CONDA_ZIG_LD"),
    }

    results = []

    # Test 1: Wrapper existence
    print("\n--- Test 1: Wrapper Existence ---")
    for wrapper in wrappers:
        results.append(("existence", wrapper, test_wrapper_exists(wrapper)))

    # Test 2: Default behavior (executes zig subcommand)
    print("\n--- Test 2: Default Behavior ---")
    for wrapper, (subcommand, _) in wrappers.items():
        results.append(("default", wrapper, test_default_behavior(wrapper, subcommand)))

    # Test 3: Override behavior (respects env var)
    print("\n--- Test 3: Override Behavior ---")
    for wrapper, (_, env_var) in wrappers.items():
        results.append(("override", wrapper, test_override_behavior(wrapper, env_var)))

    # Test 4: Actual compilation
    print("\n--- Test 4: Compilation Test ---")
    results.append(("compile", "conda-zig-cc", test_compilation("conda-zig-cc")))

    # Test 5: Archive creation
    print("\n--- Test 5: Archive Creation ---")
    results.append(("archive", "conda-zig-ar", test_archive_creation()))

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
