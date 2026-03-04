#!/usr/bin/env python
"""
Build script for zig metapackage.
Creates unprefixed symlinks/wrappers: zig -> $TRIPLET-zig
Only built when cross_target_platform_ == target_platform (native builds).
Works on both Unix and Windows.
"""

import os
import sys
from pathlib import Path

def main():
    print("=== Installing Zig Metapackage Symlinks ===")

    prefix = Path(os.environ.get("PREFIX", sys.prefix))
    target_triplet = os.environ.get("CONDA_TRIPLET")
    is_nonunix = "mingw32" in target_triplet

    print(f"Prefix: {prefix}")
    print(f"Target triplet: {target_triplet}")

    bin_dir = prefix / "Library" / "bin" if is_nonunix else prefix / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Define symlinks/wrappers to create
    links = [
        ("zig", f"{target_triplet}-zig"),
    ]

    for link_name, target_name in links:
        if is_nonunix:
            create_nonunix_wrapper(bin_dir, link_name, target_name)
        else:
            create_unix_symlink(bin_dir, link_name, target_name)

    print("=== Zig Metapackage Installation Complete ===")


def create_unix_symlink(bin_dir: Path, link_name: str, target_name: str):
    """Create a Unix symlink."""
    link_path = bin_dir / link_name
    target_path = bin_dir / target_name

    # Verify target exists (from host dependency)
    if not target_path.exists():
        print(f"  ERROR: {link_name} -> {target_name} (target not found)")
        raise FileNotFoundError(f"Symlink target not found: {target_path}")

    # Remove existing symlink if present
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()

    # Create relative symlink
    link_path.symlink_to(target_name)
    print(f"  Created symlink: {link_name} -> {target_name}")


def create_nonunix_wrapper(bin_dir: Path, link_name: str, target_name: str):
    """Create a Windows batch wrapper."""
    prefix = bin_dir.parent.parent  # Library/bin -> Library -> PREFIX

    # Main zig binary is .exe from zig_impl
    target_in_lib = bin_dir / f"{target_name}.exe"
    target_in_bin = prefix / "bin" / f"{target_name}.exe"
    target_ext = ".exe"

    if target_in_lib.exists():
        # Target in Library/bin - use relative path
        bat_content = f'@echo off\n"%~dp0{target_name}{target_ext}" %*\n'
        target_location = "Library/bin"
    elif target_in_bin.exists():
        # Target in bin - use absolute CONDA_PREFIX path
        bat_content = f'@echo off\n"%CONDA_PREFIX%\\bin\\{target_name}{target_ext}" %*\n'
        target_location = "bin"
    else:
        print(f"  ERROR: {link_name} -> {target_name} (target not found)")
        print(f"  Checked: {target_in_lib}")
        print(f"  Checked: {target_in_bin}")
        raise FileNotFoundError(f"Wrapper target not found: {target_name}")

    # Create .bat wrapper
    bat_path = bin_dir / f"{link_name}.bat"
    bat_path.write_text(bat_content)
    print(f"  Created wrapper: {link_name}.bat -> {target_location}/{target_name}{target_ext}")

    # Also create .cmd for PowerShell compatibility
    cmd_path = bin_dir / f"{link_name}.cmd"
    cmd_path.write_text(bat_content)
    print(f"  Created wrapper: {link_name}.cmd -> {target_location}/{target_name}{target_ext}")




if __name__ == "__main__":
    main()
