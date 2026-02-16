#!/usr/bin/env python
"""
Build script for zig_$TG_ activation package.
Installs activation scripts (from templates) and wrappers.
Binaries come from zig_impl_$TG_ dependency.
Works on both Unix and Windows.
"""

import os
import sys
from pathlib import Path


def main():
    print("=== Installing Zig Activation Package ===")

    prefix = Path(os.environ.get("PREFIX", sys.prefix))
    recipe_dir = Path(os.environ.get("RECIPE_DIR", Path(__file__).parent))
    tg = os.environ.get("TG_", "linux-64")
    zig_target = os.environ.get("ZIG_TARGET", "native")
    target_triplet = os.environ.get("TARGET_TRIPLET", "x86_64-conda-linux-gnu")
    build_mode = detect_build_mode()
    is_windows = sys.platform == "win32"

    print(f"PKG_NAME: {os.environ.get('PKG_NAME', 'unknown')}")
    print(f"TG_: {tg}")
    print(f"ZIG_TARGET: {zig_target}")
    print(f"TARGET_TRIPLET: {target_triplet}")
    print(f"BUILD_MODE: {build_mode}")
    print(f"Platform: {'Windows' if is_windows else 'Unix'}")
    print(f"RECIPE_DIR: {recipe_dir}")

    # Get conda triplet from environment or use target_triplet
    conda_triplet = os.environ.get("CONDA_TOOLCHAIN_HOST", target_triplet)

    if build_mode in ("native", "cross-target"):
        install_native_activation(prefix, recipe_dir, conda_triplet, is_windows)
    elif build_mode == "cross-compiler":
        install_cross_activation(prefix, recipe_dir, zig_target, is_windows)
    else:
        print(f"ERROR: Unknown BUILD_MODE: {build_mode}")
        sys.exit(1)

    # Install test files
    install_test_files(prefix, tg)

    print("=== Zig Activation Package Installation Complete ===")


def detect_build_mode() -> str:
    """Detect build mode from environment variables."""
    tg = os.environ.get("TG_", "")
    target_platform = os.environ.get("target_platform", "")
    build_platform = os.environ.get("build_platform", "")
    cross_compilation = os.environ.get("CONDA_BUILD_CROSS_COMPILATION", "0")

    if tg == build_platform:
        return "native"
    elif tg != target_platform:
        return "cross-compiler"
    elif cross_compilation == "1":
        return "cross-target"
    else:
        return "native"


def install_native_activation(prefix: Path, recipe_dir: Path, conda_triplet: str, is_windows: bool):
    """Install activation scripts and wrappers for native builds."""
    print("Installing native activation scripts and wrappers")

    if is_windows:
        install_activation_from_template(prefix, recipe_dir, is_windows=True)
        install_windows_wrappers(prefix)
    else:
        install_activation_from_template(prefix, recipe_dir, is_windows=False)
        install_unix_wrappers(prefix, conda_triplet)


def install_cross_activation(prefix: Path, recipe_dir: Path, zig_target: str, is_windows: bool):
    """Install cross-compiler activation and wrappers."""
    print("Installing cross-compiler activation and wrappers")

    native_triplet = os.environ.get("CONDA_TOOLCHAIN_BUILD", "x86_64-conda-linux-gnu")
    target_triplet = os.environ.get("CONDA_TOOLCHAIN_HOST", os.environ.get("TARGET_TRIPLET", ""))

    print(f"Native triplet: {native_triplet}")
    print(f"Target triplet: {target_triplet}")
    print(f"Zig target: {zig_target}")

    if is_windows:
        install_activation_from_template(prefix, recipe_dir, is_windows=True, cross_target_triplet=target_triplet)
        install_windows_cross_wrappers(prefix, native_triplet, target_triplet, zig_target)
    else:
        install_activation_from_template(prefix, recipe_dir, is_windows=False, cross_target_triplet=target_triplet)
        install_unix_cross_wrappers(prefix, native_triplet, target_triplet, zig_target)


def install_activation_from_template(prefix: Path, recipe_dir: Path, is_windows: bool, cross_target_triplet: str = ""):
    """Install activation/deactivation scripts from templates with placeholder substitution."""
    activate_dir = prefix / "etc" / "conda" / "activate.d"
    deactivate_dir = prefix / "etc" / "conda" / "deactivate.d"
    activate_dir.mkdir(parents=True, exist_ok=True)
    deactivate_dir.mkdir(parents=True, exist_ok=True)

    scripts_dir = recipe_dir / "scripts"

    if is_windows:
        # Windows: use .bat templates
        activate_src = scripts_dir / "activate.bat"
        deactivate_src = scripts_dir / "deactivate.bat"
        activate_dst = activate_dir / "zig_activate.bat"
        deactivate_dst = deactivate_dir / "zig_deactivate.bat"
    else:
        # Unix: use .sh templates
        activate_src = scripts_dir / "activate.sh"
        deactivate_src = scripts_dir / "deactivate.sh"
        activate_dst = activate_dir / "zig_activate.sh"
        deactivate_dst = deactivate_dir / "zig_deactivate.sh"

    # Get compiler basenames from environment for placeholder substitution
    substitutions = {
        "@CC@": os.path.basename(os.environ.get("CC", "gcc")),
        "@CXX@": os.path.basename(os.environ.get("CXX", "g++")),
        "@AR@": os.path.basename(os.environ.get("AR", "ar")),
        "@LD@": os.path.basename(os.environ.get("LD", "ld")),
        "@CROSS_TARGET_TRIPLET@": cross_target_triplet,
    }

    # Process and install activation script
    if activate_src.exists():
        content = activate_src.read_text()
        for placeholder, value in substitutions.items():
            content = content.replace(placeholder, value)
        activate_dst.write_text(content)
        print(f"  Installed: {activate_dst}")
    else:
        print(f"  WARNING: Template not found: {activate_src}")

    # Process and install deactivation script
    if deactivate_src.exists():
        content = deactivate_src.read_text()
        for placeholder, value in substitutions.items():
            content = content.replace(placeholder, value)
        deactivate_dst.write_text(content)
        print(f"  Installed: {deactivate_dst}")
    else:
        print(f"  WARNING: Template not found: {deactivate_src}")


def install_unix_wrappers(prefix: Path, conda_triplet: str):
    """Install Unix wrapper scripts."""
    bin_dir = prefix / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # conda-zig-* wrappers that use environment variables
    wrappers = {
        "conda-zig-cc": '#!/bin/bash\nexec ${CONDA_ZIG_CC:-zig cc} "$@"\n',
        "conda-zig-cxx": '#!/bin/bash\nexec ${CONDA_ZIG_CXX:-zig c++} "$@"\n',
        "conda-zig-ar": '#!/bin/bash\nexec ${CONDA_ZIG_AR:-zig ar} "$@"\n',
        "conda-zig-ld": '#!/bin/bash\nexec ${CONDA_ZIG_LD:-zig ld} "$@"\n',
    }

    for name, content in wrappers.items():
        wrapper_path = bin_dir / name
        wrapper_path.write_text(content)
        wrapper_path.chmod(0o755)
        print(f"  Installed: {wrapper_path}")

    # Triplet-prefixed tool wrappers
    for tool in ["cc", "c++", "ar"]:
        wrapper_path = bin_dir / f"{conda_triplet}-zig-{tool}"
        content = f'#!/bin/bash\nexec "${{CONDA_PREFIX}}/bin/{conda_triplet}-zig" {tool} "$@"\n'
        wrapper_path.write_text(content)
        wrapper_path.chmod(0o755)
        print(f"  Installed: {wrapper_path}")


def install_windows_wrappers(prefix: Path):
    """Install Windows wrapper scripts."""
    bin_dir = prefix / "Library" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # conda-zig-* batch wrappers
    wrappers = {
        "conda-zig-cc": '@echo off\n"%CONDA_PREFIX%\\Library\\bin\\zig.exe" cc %*\n',
        "conda-zig-cxx": '@echo off\n"%CONDA_PREFIX%\\Library\\bin\\zig.exe" c++ %*\n',
        "conda-zig-ar": '@echo off\n"%CONDA_PREFIX%\\Library\\bin\\zig.exe" ar %*\n',
        "conda-zig-ld": '@echo off\n"%CONDA_PREFIX%\\Library\\bin\\zig.exe" ld %*\n',
    }

    for name, content in wrappers.items():
        for ext in [".bat", ".cmd"]:
            wrapper_path = bin_dir / f"{name}{ext}"
            wrapper_path.write_text(content)
            print(f"  Installed: {wrapper_path}")


def install_unix_cross_wrappers(prefix: Path, native_triplet: str, target_triplet: str, zig_target: str):
    """Install Unix cross-compiler wrappers."""
    bin_dir = prefix / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Main cross-compiler wrapper
    main_wrapper = bin_dir / f"{target_triplet}-zig"
    content = f'#!/bin/bash\nexec "${{CONDA_PREFIX}}/bin/{native_triplet}-zig" -target {zig_target} "$@"\n'
    main_wrapper.write_text(content)
    main_wrapper.chmod(0o755)
    print(f"  Installed: {main_wrapper}")

    # Tool wrappers
    for tool in ["cc", "c++", "ar"]:
        wrapper_path = bin_dir / f"{target_triplet}-zig-{tool}"
        content = f'#!/bin/bash\nexec "${{CONDA_PREFIX}}/bin/{native_triplet}-zig" {tool} -target {zig_target} "$@"\n'
        wrapper_path.write_text(content)
        wrapper_path.chmod(0o755)
        print(f"  Installed: {wrapper_path}")


def install_windows_cross_wrappers(prefix: Path, native_triplet: str, target_triplet: str, zig_target: str):
    """Install Windows cross-compiler wrappers."""
    bin_dir = prefix / "Library" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Main cross-compiler wrapper
    for ext in [".bat", ".cmd"]:
        wrapper_path = bin_dir / f"{target_triplet}-zig{ext}"
        content = f'@echo off\n"%CONDA_PREFIX%\\Library\\bin\\{native_triplet}-zig.exe" -target {zig_target} %*\n'
        wrapper_path.write_text(content)
        print(f"  Installed: {wrapper_path}")

    # Tool wrappers
    for tool in ["cc", "c++", "ar"]:
        for ext in [".bat", ".cmd"]:
            wrapper_path = bin_dir / f"{target_triplet}-zig-{tool}{ext}"
            content = f'@echo off\n"%CONDA_PREFIX%\\Library\\bin\\{native_triplet}-zig.exe" {tool} -target {zig_target} %*\n'
            wrapper_path.write_text(content)
            print(f"  Installed: {wrapper_path}")


def install_test_files(prefix: Path, tg: str):
    """Install test files."""
    test_dir = prefix / "etc" / "conda" / "test-files" / f"zig_{tg}"
    test_dir.mkdir(parents=True, exist_ok=True)
    (test_dir / "README").write_text(f"Test placeholder for zig_{tg}\n")
    print(f"  Installed test files: {test_dir}")


if __name__ == "__main__":
    main()
