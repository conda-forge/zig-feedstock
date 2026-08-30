#!/usr/bin/env python
"""
Build script for zig_$cross_target_platform_ activation package.

Installs:
1. Activation/deactivation scripts (all builds)
2. zig-cc wrapper scripts from templates (all Unix builds)
3. Native-triplet compiler suite (cross-compiler builds only) — many
   downstream cross-compiling recipes invoke the build machine's own
   triplet-prefixed compiler for build-time tools in addition to the
   host/target compiler.
4. Triplet-prefixed cross-compiler wrappers (cross-compiler builds only)

All wrapper content lives in recipe/scripts/ as templates with @PLACEHOLDER@
substitution — no script content is generated inline.
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
    # recipe.yaml passes CROSS_COMPILER as a jinja boolean; rattler-build's
    # serialization of it is version-dependent ("true" <=0.73, "True" >=0.74),
    # so normalize instead of comparing against a literal. A mismatch is silent:
    # the triplet-prefixed wrapper suite below is simply never installed.
    cross_compiler_raw = os.environ.get("CROSS_COMPILER", "false")
    cross_compiler = cross_compiler_raw.strip().lower() in ("true", "1", "yes", "on")

    # Check target triplet for Unix vs non-Unix (mingw32 = non-Unix)
    target_triplet = os.environ.get("CONDA_TRIPLET", "")
    is_nonunix = "mingw32" in target_triplet

    # Cross-target triplet: only set for cross-compiler builds
    cross_target_triplet = target_triplet if cross_compiler else ""

    # Zig toolchain identification — compute from collision-free recipe env vars
    # (CONDA_ZIG_BUILD/HOST in os.environ may be polluted by activation of
    # native zig package installed as a build dep)
    native_triplet = os.environ.get("NATIVE_TRIPLET", conda_triplet)
    conda_zig_build = f"{native_triplet}-zig"
    conda_zig_host = f"{conda_triplet}-zig"

    print(f"PKG_NAME: {os.environ.get('PKG_NAME', 'unknown')}")
    print(f"zig_triplet: {zig_triplet}")
    print(f"conda_triplet: {conda_triplet}")
    print(f"CROSS_COMPILER: {cross_compiler_raw}")
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

    # 2. Install zig-cc wrapper scripts
    install_zig_cc_wrappers(
        prefix, recipe_dir,
        zig_triplet=zig_triplet,
        conda_triplet=conda_triplet,
        is_nonunix=is_nonunix,
    )


    # 3. Cross-compiler: install triplet-prefixed wrappers
    if cross_compiler:
        native_triplet = os.environ.get("NATIVE_TRIPLET", "x86_64-conda-linux-gnu")
        native_zig_triplet = os.environ.get("NATIVE_ZIG_TRIPLET", "native")

        print(f"Native triplet: {native_triplet}")
        print(f"Native zig triplet: {native_zig_triplet}")
        print(f"Target triplet: {target_triplet}")

        # Native-triplet compiler suite (zig-cc/cxx/ar/ranlib/asm/rc/lld/
        # windres/force-load-cc/force-load-cxx targeting the build machine
        # itself) — reuses install_zig_cc_wrappers with native_triplet/
        # native_zig_triplet substituted for conda_triplet/zig_triplet, so
        # the resulting suite is named f"{native_triplet}-{name}" instead
        # of f"{conda_triplet}-{name}". is_nonunix is shared with the target
        # suite because this recipe's xc_valid gating (xc_lnx/xc_osx/xc_nlo)
        # only allows same-OS-family cross builds — native and target are
        # never on opposite sides of the Unix/non-Unix boundary.
        install_zig_cc_wrappers(
            prefix, recipe_dir,
            zig_triplet=native_zig_triplet,
            conda_triplet=native_triplet,
            is_nonunix=is_nonunix,
        )

        if is_nonunix:
            install_nonunix_cross_wrappers(prefix, recipe_dir, native_triplet, target_triplet, zig_triplet)
        else:
            install_unix_cross_wrappers(prefix, recipe_dir, native_triplet, target_triplet, zig_triplet)

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
            # No -target => native compile; zig defaults to the host CPU
            # model, baking the runner's ISA into the shipped shim.
            "-mcpu=baseline",
            f"-I{src.parent}",
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


def _find_zig_bin(conda_triplet: str, is_nonunix: bool = False) -> str:
    """Return the zig binary reference for wrappers.

    Uses %CONDA_PREFIX% (NonUnix) relative path, or ${_self_dir} (Unix,
    the wrapper's own directory) so wrappers work after installation.
    Unix wrappers must NOT anchor on $CONDA_PREFIX: it reflects whichever
    env is active at invocation time, not where the wrapper lives (e.g.
    a cross-compiler wrapper invoked with a build env active).
    """
    if is_nonunix:
        if conda_triplet:
            return f"%CONDA_PREFIX%\\Library\\bin\\{conda_triplet}-zig.exe"
        return "%CONDA_PREFIX%\\Library\\bin\\zig.exe"
    if conda_triplet:
        return f"${{_self_dir}}/{conda_triplet}-zig"
    return "${_self_dir}/zig"


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


def install_zig_cc_wrappers(
    prefix: Path,
    recipe_dir: Path,
    zig_triplet: str,
    conda_triplet: str,
    is_nonunix: bool = False,
):
    """Install zig-cc/cxx/ar/ranlib/asm/rc wrapper scripts from templates."""
    scripts_dir = recipe_dir / "scripts"

    # Strip glibc version for cc/c++ target (clang rejects ".2.17" suffix)
    cc_target = _strip_glibc_version(zig_triplet)
    zig_bin = _find_zig_bin(conda_triplet, is_nonunix=is_nonunix)

    # Architecture prefix for sysroot detection (e.g. x86_64 from x86_64-linux-gnu.2.17)
    target_arch = zig_triplet.split("-")[0] if "-" in zig_triplet else ""

    replacements = {
        "@ZIG_BIN@": zig_bin,
        "@ZIG_TARGET@": cc_target,
        "@ZIG_TARGET_ARCH@": target_arch,
        "@WRAPPER_PREFIX@": f"{conda_triplet}-",
    }

    if is_nonunix:
        wrapper_dir = prefix / "Library" / "bin"
        # Extract zig binary filename from full %CONDA_PREFIX%\... path once
        zig_bin_name = zig_bin.rsplit("\\", 1)[-1]

        # Compile zig-cc.exe and zig-cxx.exe (native .exe with flag filtering)
        cc_src = recipe_dir / "building" / "zig-cc-nonunix.c"
        if cc_src.exists():
            is_mingw = "mingw32" in conda_triplet
            for mode, exe_name in [("cc", "zig-cc"), ("c++", "zig-cxx")]:
                mode_replacements = {
                    **replacements,
                    "@ZIG_CC_MODE@": mode,
                    "@ZIG_BIN_NAME@": zig_bin_name,
                    "@IS_MINGW_TARGET@": "1" if is_mingw else "0",
                }
                _compile_c_shim(cc_src, wrapper_dir / f"{conda_triplet}-{exe_name}.exe", mode_replacements)

        # Compile .exe shims for simple pass-through tools
        tool_src = recipe_dir / "building" / "zig-tool-nonunix.c"
        if tool_src.exists():
            zig_target_for_asm = replacements.get("@ZIG_TARGET@", "native")
            tool_prefix_args = {
                "zig-ar":     '"ar"',
                "zig-ranlib": '"ranlib"',
                "zig-rc":     '"rc"',
                "zig-lld":    '"lld-link"',
                "zig-asm":    f'"cc", "-target", "{zig_target_for_asm}", "-mcpu=baseline"',
            }
            for name, prefix_args in tool_prefix_args.items():
                tool_replacements = {
                    **replacements,
                    "@ZIG_BIN_NAME@": zig_bin_name,
                    "@ZIG_PREFIX_ARGS@": prefix_args,
                }
                _compile_c_shim(tool_src, wrapper_dir / f"{conda_triplet}-{name}.exe", tool_replacements)

        # Compile zig-windres.exe (dedicated shim with -o -> -fo translation)
        windres_src = recipe_dir / "building" / "zig-windres-nonunix.c"
        if windres_src.exists():
            windres_replacements = {
                **replacements,
                "@ZIG_BIN_NAME@": zig_bin_name,
            }
            _compile_c_shim(windres_src, wrapper_dir / f"{conda_triplet}-zig-windres.exe", windres_replacements)

    else:
        wrapper_dir = prefix / "bin"
        building_dir = recipe_dir / "building"
        # Install shared helpers (sourced by wrapper scripts, not executed directly).
        # _translate.gen.sh is the generated flag-translation fragment (R1-R9);
        # it lives in recipe/building/ (source of truth: flag_rules.py), unlike
        # the other two helpers which live in recipe/scripts/ alongside the
        # wrapper templates that source them.
        for helper, helper_src_dir in [
            ("_zig-cc-common.sh", scripts_dir),
            ("_zig-force-load-common.sh", scripts_dir),
            ("_translate.gen.sh", building_dir),
        ]:
            src = helper_src_dir / helper
            if src.exists():
                _install_template(src, wrapper_dir / f"{conda_triplet}-{helper}", replacements)
        wrappers = ["zig-cc", "zig-cxx", "zig-ar", "zig-ranlib", "zig-asm", "zig-rc", "zig-lld", "zig-windres", "zig-force-load-cc", "zig-force-load-cxx"]
        for name in wrappers:
            src = scripts_dir / f"{name}.sh"
            if src.exists():
                _install_template(src, wrapper_dir / f"{conda_triplet}-{name}", replacements, executable=True)


def install_unix_cross_wrappers(
    prefix: Path, recipe_dir: Path,
    native_triplet: str, target_triplet: str, zig_triplet: str,
):
    """Install Unix cross-compiler wrapper from template."""
    bin_dir = prefix / "bin"

    # Always use triplet-prefixed native zig (zig_impl provides it)
    native_zig = f"{native_triplet}-zig"

    # Strip glibc version for cc/c++ commands (clang rejects ".2.17" suffix)
    cc_triplet = _strip_glibc_version(zig_triplet)

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
    cc_triplet = _strip_glibc_version(zig_triplet)

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


if __name__ == "__main__":
    main()
