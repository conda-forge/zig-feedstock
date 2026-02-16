#!/usr/bin/env python
"""
Build script for zig metapackage.
Creates unprefixed symlinks/wrappers: zig -> $TRIPLET-zig
Only built when TG_ == target_platform (native builds).
Works on both Unix and Windows.
"""

import os
import sys
from pathlib import Path

def main():
    print("=== Installing Zig Metapackage Symlinks ===")

    prefix = Path(os.environ.get("PREFIX", sys.prefix))
    target_triplet = os.environ.get("CONDA_TOOLCHAIN_HOST", "x86_64-conda-linux-gnu")
    is_windows = sys.platform == "win32"

    print(f"Prefix: {prefix}")
    print(f"Target triplet: {target_triplet}")
    print(f"Platform: {'Windows' if is_windows else 'Unix'}")

    bin_dir = prefix / "Library" / "bin" if is_windows else prefix / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Define symlinks/wrappers to create
    links = [
        ("zig", f"{target_triplet}-zig"),
        ("zig-cc", f"{target_triplet}-zig-cc"),
        ("zig-c++", f"{target_triplet}-zig-c++"),
        ("zig-ar", f"{target_triplet}-zig-ar"),
    ]

    for link_name, target_name in links:
        if is_windows:
            create_windows_wrapper(bin_dir, link_name, target_name)
        else:
            create_unix_symlink(bin_dir, link_name, target_name)

    print("=== Zig Metapackage Installation Complete ===")


def create_unix_symlink(bin_dir: Path, link_name: str, target_name: str):
    """Create a Unix symlink."""
    link_path = bin_dir / link_name
    target_path = bin_dir / target_name

    # Only create if target exists (from zig_impl package)
    if not target_path.exists():
        print(f"  Skipping {link_name} -> {target_name} (target not found)")
        return

    # Remove existing symlink if present
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()

    # Create relative symlink
    link_path.symlink_to(target_name)
    print(f"  Created symlink: {link_name} -> {target_name}")


def create_windows_wrapper(bin_dir: Path, link_name: str, target_name: str):
    """Create a Windows batch wrapper."""
    # Check for .exe target
    target_exe = bin_dir / f"{target_name}.exe"
    if not target_exe.exists():
        target_exe = bin_dir / target_name
        if not target_exe.exists():
            print(f"  Skipping {link_name} -> {target_name} (target not found)")
            return

    # Create .bat wrapper
    bat_path = bin_dir / f"{link_name}.bat"
    bat_content = f'@echo off\n"%~dp0{target_name}.exe" %*\n'

    bat_path.write_text(bat_content)
    print(f"  Created wrapper: {link_name}.bat -> {target_name}.exe")

    # Also create .cmd for PowerShell compatibility
    cmd_path = bin_dir / f"{link_name}.cmd"
    cmd_path.write_text(bat_content)
    print(f"  Created wrapper: {link_name}.cmd -> {target_name}.exe")


if __name__ == "__main__":
    main()
