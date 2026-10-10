#!/usr/bin/env python
"""
Build script for zig metapackage.
Creates unprefixed symlinks/wrappers: zig -> $TRIPLET-zig
Only built when xtarget_ == target_platform (native builds).
Works on both Unix and NonUnix.
"""

import os
import sys
from pathlib import Path

def main():
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
    """Create a NonUnix batch wrapper."""
    prefix = bin_dir.parent.parent  # Library/bin -> Library -> PREFIX

    # zig_impl ships the main binary as .exe for the win-64 NATIVE target but
    # unsuffixed for the win-arm64 CROSS target. NOT a shell difference: both
    # lanes run build=win-64 with identical m2-msys2-runtime, and build.sh's
    # mv is byte-identical. Mechanism unconfirmed — the pre-mv filename has
    # never been captured. Probe both spellings, .exe first.
    candidates = [
        (bin_dir / f"{target_name}.exe", ".exe", "Library/bin"),
        (bin_dir / target_name, "", "Library/bin"),
        (prefix / "bin" / f"{target_name}.exe", ".exe", "bin"),
        (prefix / "bin" / target_name, "", "bin"),
    ]
    for cand, ext, location in candidates:
        if cand.exists():
            target_ext = ext
            target_location = location
            break
    else:
        print(f"  ERROR: {link_name} -> {target_name} (target not found)")
        for cand, _ext, _loc in candidates:
            print(f"  Checked: {cand}")
        raise FileNotFoundError(f"Wrapper target not found: {target_name}")

    if target_ext == "":
        print(f"  WARNING: {target_name} has no .exe suffix; cmd.exe cannot execute it directly")

    if target_location == "Library/bin":
        bat_content = f'@echo off\n"%~dp0{target_name}{target_ext}" %*\n'
    else:
        bat_content = f'@echo off\n"%CONDA_PREFIX%\\bin\\{target_name}{target_ext}" %*\n'

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
