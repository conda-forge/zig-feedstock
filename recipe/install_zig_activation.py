#!/usr/bin/env python
"""
Build script for zig_$TG_ activation package.

For CROSS-COMPILER builds: Installs activation scripts and wrappers.
For NATIVE/CROSS-TARGET builds: No activation needed (just dependency on zig_impl).

Works on both Unix and Windows.
"""

import os
import sys
from pathlib import Path


def main():
    print("=== Installing Zig Activation Package ===")

    prefix = Path(os.environ.get("PREFIX", sys.prefix))
    recipe_dir = Path(os.environ.get("RECIPE_DIR", Path(__file__).parent))
    zig_triplet = os.environ.get("ZIG_TRIPLET", "native")
    cross_compiler = os.environ.get("CROSS_COMPILER", "false")

    # Check target triplet for Unix vs non-Unix (mingw32 = non-Unix)
    target_triplet = os.environ.get("CONDA_TRIPLET", "")
    is_nonunix = "mingw32" in target_triplet

    print(f"PKG_NAME: {os.environ.get('PKG_NAME', 'unknown')}")
    print(f"zig_triplet: {zig_triplet}")
    print(f"CROSS_COMPILER: {cross_compiler}")
    print(f"Platform: {'Non-Unix' if is_nonunix else 'Unix'}")

    if cross_compiler == "true":
        # Cross-compiler: install activation scripts and wrappers
        # target_triplet already set from CONDA_TRIPLET above
        native_triplet = os.environ.get("NATIVE_TRIPLET", "x86_64-conda-linux-gnu")

        print(f"Native triplet: {native_triplet}")
        print(f"Target triplet: {target_triplet}")

        install_activation_scripts(prefix, recipe_dir, target_triplet, is_nonunix)

        if is_nonunix:
            install_nonunix_cross_wrappers(prefix, native_triplet, target_triplet, zig_triplet)
        else:
            install_unix_cross_wrappers(prefix, native_triplet, target_triplet, zig_triplet)
    else:
        # Native or cross-target: no activation scripts needed
        # The package just provides dependency on zig_impl
        print("Native/cross-target build: no activation scripts needed")

    print("=== Zig Activation Package Installation Complete ===")


def install_activation_scripts(prefix: Path, recipe_dir: Path, target_triplet: str, is_nonunix: bool):
    """Install activation/deactivation scripts for cross-compiler builds."""
    activate_dir = prefix / "etc" / "conda" / "activate.d"
    deactivate_dir = prefix / "etc" / "conda" / "deactivate.d"
    activate_dir.mkdir(parents=True, exist_ok=True)
    deactivate_dir.mkdir(parents=True, exist_ok=True)

    scripts_dir = recipe_dir / "scripts"

    if is_nonunix:
        activate_src = scripts_dir / "activate.bat"
        deactivate_src = scripts_dir / "deactivate.bat"
        activate_dst = activate_dir / "zig_activate.bat"
        deactivate_dst = deactivate_dir / "zig_deactivate.bat"
    else:
        activate_src = scripts_dir / "activate.sh"
        deactivate_src = scripts_dir / "deactivate.sh"
        activate_dst = activate_dir / "zig_activate.sh"
        deactivate_dst = deactivate_dir / "zig_deactivate.sh"

    # Placeholder substitutions for cross-compiler
    for src, dst in [(activate_src, activate_dst), (deactivate_src, deactivate_dst)]:
        if src.exists():
            content = src.read_text()
            content = content.replace("@CROSS_TARGET_TRIPLET@", target_triplet)
            dst.write_text(content)
            print(f"  Installed: {dst}")
        else:
            print(f"  WARNING: Template not found: {src}")


def install_unix_cross_wrappers(prefix: Path, native_triplet: str, target_triplet: str, zig_triplet: str):
    """Install Unix cross-compiler wrappers."""
    bin_dir = prefix / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Check if native triplet zig exists, fallback to plain zig
    build_prefix = Path(os.environ.get("BUILD_PREFIX", os.environ.get("CONDA_PREFIX", "")))
    native_zig = f"{native_triplet}-zig"
    if not (build_prefix / "bin" / native_zig).exists():
        native_zig = "zig"

    # Main cross-compiler wrapper - smart passthrough that injects -target after command
    main_wrapper = bin_dir / f"{target_triplet}-zig"
    content = f'''#!/bin/bash
# Cross-compiler wrapper: injects -target for commands that support it
case "$1" in
  cc|c++|build-exe|build-lib|build-obj|test|run|translate-c)
    cmd="$1"; shift
    exec "${{CONDA_PREFIX}}/bin/{native_zig}" "$cmd" -target {zig_triplet} "$@"
    ;;
  *)
    exec "${{CONDA_PREFIX}}/bin/{native_zig}" "$@"
    ;;
esac
'''
    main_wrapper.write_text(content)
    main_wrapper.chmod(0o755)
    print(f"  Installed: {main_wrapper}")


def install_nonunix_cross_wrappers(prefix: Path, native_triplet: str, target_triplet: str, zig_triplet: str):
    """Install non-Unix cross-compiler wrappers."""
    bin_dir = prefix / "Library" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Check if native triplet zig exists, fallback to plain zig
    build_prefix = Path(os.environ.get("BUILD_PREFIX", os.environ.get("CONDA_PREFIX", "")))
    native_zig = f"{native_triplet}-zig"
    native_zig_ext = f"{native_triplet}-zig.exe"
    if not (build_prefix / "Library" / "bin" / native_zig_ext).exists():
        native_zig = "zig"
        native_zig_ext = "zig.exe"

    # Main cross-compiler wrapper - smart passthrough that injects -target after command
    for ext in [".bat", ".cmd"]:
        wrapper_path = bin_dir / f"{target_triplet}-zig{ext}"
        content = f'''@echo off
setlocal
set "CMD=%1"
if "%CMD%"=="cc" goto inject_target
if "%CMD%"=="c++" goto inject_target
if "%CMD%"=="build-exe" goto inject_target
if "%CMD%"=="build-lib" goto inject_target
if "%CMD%"=="build-obj" goto inject_target
if "%CMD%"=="test" goto inject_target
if "%CMD%"=="run" goto inject_target
if "%CMD%"=="translate-c" goto inject_target
goto passthrough

:inject_target
shift
"%CONDA_PREFIX%\\Library\\bin\\{native_zig_ext}" %CMD% -target {zig_triplet} %*
goto :eof

:passthrough
"%CONDA_PREFIX%\\Library\\bin\\{native_zig_ext}" %*
'''
        wrapper_path.write_text(content)
        print(f"  Installed: {wrapper_path}")


if __name__ == "__main__":
    main()
