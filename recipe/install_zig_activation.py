#!/usr/bin/env python
"""
Build script for zig_$cross_target_platform_ activation package.

Installs:
1. Activation/deactivation scripts (all builds)
2. Triplet-prefixed cross-compiler wrappers (cross-compiler builds only)

zig-cc/cxx/ar/ranlib/asm/rc/lld/force-load-cc/force-load-cxx wrappers are
compiled from recipe/building/zig-wrapper.c by build.sh and installed
directly into bin/ (Unix) or Library/bin/ (Windows) — not installed here.
"""

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    print("=== Installing Zig Activation Package ===")

    prefix = Path(os.environ.get("PREFIX", sys.prefix))
    recipe_dir = Path(os.environ.get("RECIPE_DIR", Path(__file__).parent))
    zig_triplet = os.environ.get("ZIG_TRIPLET", "native")
    conda_triplet = os.environ.get("CONDA_TRIPLET", "")
    cross_compiler = os.environ.get("CROSS_COMPILER", "false")

    # Check target triplet for Unix vs non-Unix (mingw32 = non-Unix)
    target_triplet = os.environ.get("CONDA_TRIPLET", "")
    is_nonunix = "mingw32" in target_triplet

    # Cross-target triplet: only set for cross-compiler builds
    cross_target_triplet = target_triplet if cross_compiler == "true" else ""

    # Zig toolchain identification — compute from collision-free recipe env vars
    # (CONDA_ZIG_BUILD/HOST in os.environ may be polluted by activation of
    # native zig package installed as a build dep)
    native_triplet = os.environ.get("NATIVE_TRIPLET", conda_triplet)
    conda_zig_build = f"{native_triplet}-zig"
    conda_zig_host = f"{conda_triplet}-zig"

    print(f"PKG_NAME: {os.environ.get('PKG_NAME', 'unknown')}")
    print(f"zig_triplet: {zig_triplet}")
    print(f"conda_triplet: {conda_triplet}")
    print(f"CROSS_COMPILER: {cross_compiler}")
    print(f"CONDA_ZIG_BUILD: {conda_zig_build}")
    print(f"CONDA_ZIG_HOST: {conda_zig_host}")
    print(f"Platform: {'Non-Unix' if is_nonunix else 'Unix'}")
    print(f"BUILD_NATIVE_ZIG: {os.environ.get('BUILD_NATIVE_ZIG', '<unset>')}")

    # 1. Install activation/deactivation scripts
    install_activation_scripts(
        prefix, recipe_dir,
        zig_triplet=zig_triplet,
        conda_triplet=conda_triplet,
        cross_target_triplet=cross_target_triplet,
        is_nonunix=is_nonunix,
    )

    # 2. Cross-compiler: install triplet-prefixed wrappers (cross builds only)
    if cross_compiler == "true":
        native_triplet = os.environ.get("NATIVE_TRIPLET", "x86_64-conda-linux-gnu")

        print(f"Native triplet: {native_triplet}")
        print(f"Target triplet: {target_triplet}")

        if is_nonunix:
            install_nonunix_cross_wrappers(prefix, recipe_dir, native_triplet, target_triplet, zig_triplet)
        else:
            install_unix_cross_wrappers(prefix, recipe_dir, native_triplet, target_triplet, zig_triplet)

        install_target_triplet_wrappers(prefix, recipe_dir, target_triplet, zig_triplet, is_nonunix)

    print("=== Zig Activation Package Installation Complete ===")


def _install_template(src: Path, dst: Path, replacements: dict, executable: bool = False):
    """Read a template file, apply @PLACEHOLDER@ substitutions, write to dst."""
    content = src.read_text()
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(content)
    if executable:
        dst.chmod(dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"  Installed: {dst}")


def _find_zig_compiler() -> str:
    """Find a zig binary suitable for compiling C shims at install time.

    Search order:
    1. CONDA_ZIG_BUILD (build machine's zig binary name)
    2. CONDA_ZIG_HOST (target machine's zig — usable on win-arm64 via x86_64 emulation)
    3. Any *-zig.exe or zig.exe in known prefix directories
    """
    conda_zig_build = os.environ.get("CONDA_ZIG_BUILD", "")
    conda_zig_host = os.environ.get("CONDA_ZIG_HOST", "")

    # Try CONDA_ZIG_BUILD first, then CONDA_ZIG_HOST as fallback
    # (cross-target builds on win-arm64 may only have the win-64 zig binary,
    # which runs fine via non-unix x86_64-on-ARM64 emulation)
    for zig_name in (conda_zig_build, conda_zig_host):
        if not zig_name:
            continue
        found = shutil.which(zig_name)
        if found:
            return found
        # Search known prefix directories
        for name in (zig_name, f"{zig_name}.exe"):
            for prefix_var in ("BUILD_PREFIX", "PREFIX", "CONDA_PREFIX"):
                prefix_path = os.environ.get(prefix_var, "")
                if not prefix_path:
                    continue
                for subdir in ("Library/bin", "bin"):
                    candidate = Path(prefix_path) / subdir / name
                    if candidate.exists():
                        return str(candidate)

    raise RuntimeError(
        f"No zig binary found to compile C shim. "
        f"CONDA_ZIG_BUILD={conda_zig_build!r}, CONDA_ZIG_HOST={conda_zig_host!r}"
    )


def _compile_c_shim(src: Path, dst: Path, replacements: dict):
    """Compile a C shim with @PLACEHOLDER@ substitution using zig cc."""
    content = src.read_text()
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)

    dst.parent.mkdir(parents=True, exist_ok=True)
    zig_bin = _find_zig_compiler()

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_src = Path(tmpdir) / src.name
        tmp_src.write_text(content)
        subprocess.check_call([
            zig_bin, "cc",
            "-O2",
            "-o", str(dst),
            str(tmp_src),
            "-lkernel32",
        ])

    pdb = dst.with_suffix(".pdb")
    if pdb.exists():
        pdb.unlink()
        print(f"  Removed: {pdb}")

    print(f"  Compiled: {dst}")


def _strip_glibc_version(triplet: str) -> str:
    """Strip glibc version suffix from triplet for clang compatibility.

    zig cc/c++ internally invokes clang which rejects glibc version suffixes
    (e.g. x86_64-linux-gnu.2.17). Zig's own -target flag accepts it, but
    since these wrappers route through zig cc -> clang, strip the suffix.
    """
    m = re.match(r'^(.*-gnu[a-z]*)\.\d+\.\d+', triplet)
    return m.group(1) if m else triplet


def _normalize_cc_target(triplet: str) -> str:
    """Normalize a zig triplet for use as a zig cc -target value.

    Applies two transformations:
    1. Strip glibc version suffix (clang rejects e.g. x86_64-linux-gnu.2.17)
    2. Expand bare macOS major version to major.minor (zig 0.15+ rejects e.g.
       'aarch64-macos.11-none'; requires 'aarch64-macos.11.0-none').
    """
    triplet = _strip_glibc_version(triplet)
    triplet = re.sub(r'(-macos\.)(\d+)(-)', r'\g<1>\2.0\3', triplet)
    return triplet


def install_activation_scripts(
    prefix: Path,
    recipe_dir: Path,
    zig_triplet: str,
    conda_triplet: str,
    cross_target_triplet: str,
    is_nonunix: bool,
):
    """Install activation/deactivation scripts for all builds."""
    activate_dir = prefix / "etc" / "conda" / "activate.d"
    deactivate_dir = prefix / "etc" / "conda" / "deactivate.d"

    # CONDA_ZIG_BUILD: the build platform's conda triplet (who runs the compiler)
    # CONDA_ZIG_HOST: the target platform's conda triplet (what the compiler targets)
    # Compute from collision-free args — don't read from os.environ which may be
    # polluted by activation of native zig installed as build dep.
    native_triplet = os.environ.get("NATIVE_TRIPLET", conda_triplet)
    conda_zig_build = f"{native_triplet}-zig"
    conda_zig_host = f"{conda_triplet}-zig"

    scripts_dir = recipe_dir / "scripts"
    replacements = {
        "@ZIG_TRIPLET@": zig_triplet,
        "@CONDA_TRIPLET@": conda_triplet,
        "@CROSS_TARGET_TRIPLET@": cross_target_triplet,
        "@CONDA_ZIG_BUILD@": conda_zig_build,
        "@CONDA_ZIG_HOST@": conda_zig_host,
    }

    if is_nonunix:
        _install_template(scripts_dir / "activate.bat", activate_dir / "zig_activate.bat", replacements)
        _install_template(scripts_dir / "deactivate.bat", deactivate_dir / "zig_deactivate.bat", replacements)
    else:
        _install_template(scripts_dir / "activate.sh", activate_dir / "zig_activate.sh", replacements)
        _install_template(scripts_dir / "deactivate.sh", deactivate_dir / "zig_deactivate.sh", replacements)


def install_unix_cross_wrappers(
    prefix: Path, recipe_dir: Path,
    native_triplet: str, target_triplet: str, zig_triplet: str,
):
    """Install Unix cross-compiler wrapper from template."""
    bin_dir = prefix / "bin"

    # Always use triplet-prefixed native zig (zig_impl provides it)
    native_zig = f"{native_triplet}-zig"

    # Strip glibc version for cc/c++ commands (clang rejects ".2.17" suffix)
    cc_triplet = _normalize_cc_target(zig_triplet)

    replacements = {
        "@NATIVE_ZIG@": native_zig,
        "@CC_TRIPLET@": cc_triplet,
        "@ZIG_TRIPLET@": zig_triplet,
    }
    _install_template(
        recipe_dir / "building" / "cross-zig.sh",
        bin_dir / f"{target_triplet}-zig",
        replacements, executable=True,
    )


def install_nonunix_cross_wrappers(
    prefix: Path, recipe_dir: Path,
    native_triplet: str, target_triplet: str, zig_triplet: str,
):
    """Install non-Unix cross-compiler .exe shim (replaces .bat/.cmd).

    Compiles a small C shim that forwards to the native zig binary with
    -target injection. This avoids .bat/.cmd issues with CMake's compiler
    detection (backslash escaping, command-line quoting).
    """
    bin_dir = prefix / "Library" / "bin"

    # Always use triplet-prefixed native zig (zig_impl provides it)
    native_zig_exe = f"{native_triplet}-zig.exe"

    # Strip glibc version for cc/c++ commands (clang rejects ".2.17" suffix)
    cc_triplet = _normalize_cc_target(zig_triplet)

    replacements = {
        "@NATIVE_ZIG_EXE@": native_zig_exe,
        "@CC_TRIPLET@": cc_triplet,
        "@ZIG_TRIPLET@": zig_triplet,
    }
    _compile_c_shim(
        recipe_dir / "building" / "cross-zig-shim.c",
        bin_dir / f"{target_triplet}-zig.exe",
        replacements,
    )


def install_target_triplet_wrappers(
    prefix: Path, recipe_dir: Path,
    target_triplet: str, zig_triplet: str,
    is_nonunix: bool,
):
    """Compile and install target-triplet-prefixed zig-cc/cxx/ar/... wrappers.

    Mirrors build.sh Phase 2 for cross-compiler packages: compiles zig-wrapper.c
    with @ZIG_TARGET@ and @ZIG_REAL_PATH@ substituted, then copies the resulting
    binary to bin/{target_triplet}-zig-{suffix} for all 9 tool suffixes.

    This is separate from install_unix_cross_wrappers / install_nonunix_cross_wrappers
    which install the bare {target_triplet}-zig dispatcher script/shim.
    """
    wrapper_src = recipe_dir / "building" / "zig-wrapper.c"
    if not wrapper_src.exists():
        raise FileNotFoundError(f"zig-wrapper.c not found at {wrapper_src}")

    # bin directory mirrors build.sh WRAPPER_BIN_DIR
    if is_nonunix:
        bin_dir = prefix / "Library" / "bin"
        real_zig_path = str(prefix / "Library" / "share" / "zig" / "zig-real.exe")
        exe_ext = ".exe"
    else:
        bin_dir = prefix / "bin"
        real_zig_path = str(prefix / "share" / "zig" / "zig-real")
        exe_ext = ""

    # @ZIG_TARGET@: strip glibc version suffix (build.sh: ${ZIG_TRIPLET%%.[0-9]*})
    zig_target = re.sub(r'\.[0-9]+\.[0-9]+$', '', zig_triplet)

    replacements = {
        "@ZIG_TARGET@": zig_target,
        "@ZIG_REAL_PATH@": real_zig_path,
    }

    # Substitute source and compile in a temp dir
    content = wrapper_src.read_text()
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)

    # zig_impl is a BUILD dep, installed into BUILD_PREFIX during build.
    # Use the build-host's zig binary directly — bypass the cross-compiler
    # dispatcher (which won't work at install time before activation).
    build_zig = os.environ.get("CONDA_ZIG_BUILD", "")  # e.g. "x86_64-conda-linux-gnu-zig"
    build_prefix = Path(os.environ["BUILD_PREFIX"])

    if is_nonunix:
        candidates = [
            # zig_impl is a BUILD dep, installed into ${BUILD_PREFIX} during build
            build_prefix / "Library" / "bin" / f"{build_zig}.exe",
            # _27 layout fallback
            build_prefix / "Library" / "share" / "zig" / "zig-real.exe",
        ]
    else:
        candidates = [
            # zig_impl is a BUILD dep, installed into ${BUILD_PREFIX} during build
            build_prefix / "bin" / build_zig,
            # _27 layout fallback
            build_prefix / "share" / "zig" / "zig-real",
        ]

    zig_bin = next((p for p in candidates if p.is_file()), None)

    # Cross-platform builds: CONDA_ZIG_BUILD may reference the cross-build's "native"
    # triplet (e.g., osx-64 for osx-arm64 cross) while BUILD machine uses a different
    # zig wrapper name (e.g., linux-64). Probe for any -zig binary in BUILD_PREFIX/bin.
    if zig_bin is None:
        if is_nonunix:
            bin_dir = build_prefix / "Library" / "bin"
            glob_pattern = "*-zig.exe"
        else:
            bin_dir = build_prefix / "bin"
            glob_pattern = "*-zig"
        matches = sorted(bin_dir.glob(glob_pattern))
        # Filter out our own newly-installed cross-compiler dispatcher if it ended up here
        # (it shouldn't be in build_prefix, but defensive). Match anything matching the pattern.
        for match in matches:
            if match.is_file():
                zig_bin = match
                break

    if zig_bin is None:
        if is_nonunix:
            bin_dir = build_prefix / "Library" / "bin"
            glob_pattern = "*-zig.exe"
        else:
            bin_dir = build_prefix / "bin"
            glob_pattern = "*-zig"
        raise FileNotFoundError(
            f"No working zig found in BUILD_PREFIX. Tried:\n  "
            + "\n  ".join(str(p) for p in candidates)
            + f"\n  glob: {bin_dir}/{glob_pattern}"
            + f"\nCONDA_ZIG_BUILD={build_zig!r}; is a zig_impl_* package listed as a build dep?"
        )

    # Wrapper binary is compiled NATIVE (runs on BUILD machine).
    # It does NOT need cross-compilation; the target arch is baked into
    # @ZIG_TARGET@ constant which the wrapper passes to zig at runtime.

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_src = Path(tmpdir) / "zig-wrapper-built.c"
        tmp_src.write_text(content)

        primary_wrapper = Path(tmpdir) / f"{target_triplet}-zig{exe_ext}"

        extra_flags = []
        if "powerpc64le" in zig_triplet or "ppc64le" in zig_triplet:
            extra_flags.append(f"--target={zig_triplet}")
        if "macos" in zig_triplet or "darwin" in target_triplet:
            extra_flags.append("-Wl,-headerpad_max_install_names")

        subprocess.check_call([
            str(zig_bin), "cc", "-O2",
            *extra_flags,
            str(tmp_src),
            "-o", str(primary_wrapper),
        ])
        print(f"  Compiled wrapper: {primary_wrapper.name}")

        bin_dir.mkdir(parents=True, exist_ok=True)

        suffixes = [
            "zig-cc", "zig-cxx", "zig-ar", "zig-ranlib",
            "zig-lld", "zig-rc", "zig-asm",
            "zig-force-load-cc", "zig-force-load-cxx",
        ]
        for suffix in suffixes:
            dst = bin_dir / f"{target_triplet}-{suffix}{exe_ext}"
            shutil.copy2(str(primary_wrapper), str(dst))
            if not is_nonunix:
                dst.chmod(dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            print(f"  Installed: {dst}")

        # Remove any stray .pdb sidecar emitted by zig's PE/COFF link (Windows)
        if is_nonunix:
            for pdb in Path(tmpdir).glob("*.pdb"):
                pdb.unlink()


if __name__ == "__main__":
    main()
