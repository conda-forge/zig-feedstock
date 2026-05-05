#!/bin/bash
# Zig compiler activation script
# Installed to: $PREFIX/etc/conda/activate.d/zig_activate.sh
#
# Exports ZIG_CC, ZIG_CXX, etc. pointing to pre-installed wrapper scripts
# in $CONDA_PREFIX/share/zig/wrappers/

# === Configuration (substituted at install time) ===
_CONDA_TRIPLET="@CONDA_TRIPLET@"
_CROSS_TARGET_TRIPLET="@CROSS_TARGET_TRIPLET@"

# === Zig toolchain identification ===
# These variables identify the zig binary name without depending on gcc's TOOLCHAIN.
# CONDA_ZIG_BUILD = build machine zig binary name (e.g. x86_64-conda-linux-gnu-zig)
# CONDA_ZIG_HOST  = target machine zig binary name (e.g. aarch64-conda-linux-gnu-zig)
export CONDA_ZIG_BUILD="@CONDA_ZIG_BUILD@"
export CONDA_ZIG_HOST="@CONDA_ZIG_HOST@"

# === Cross-compiler variable (set only for cross builds) ===
if [[ -n "${_CROSS_TARGET_TRIPLET}" ]]; then
    export ZIG_TARGET_TRIPLET="${_CROSS_TARGET_TRIPLET}"
fi

# === Wrapper directory (pre-installed at build time) ===
_wrapper_dir="${CONDA_PREFIX}/share/zig/wrappers"

if [[ ! -d "${_wrapper_dir}" ]]; then
    echo "WARNING: zig-cc activation: wrapper directory not found: ${_wrapper_dir}" >&2
    unset _CONDA_TRIPLET _CROSS_TARGET_TRIPLET _wrapper_dir
    return 0 2>/dev/null || exit 0
fi

# === Export variables ===
_zig_bin="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig"
[[ -x "${_zig_bin}" ]] && export ZIG="${_zig_bin}"

[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-cc" ]]         && export ZIG_CC="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-cc"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-cxx" ]]        && export ZIG_CXX="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-cxx"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ar" ]]         && export ZIG_AR="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ar"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ranlib" ]]     && export ZIG_RANLIB="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ranlib"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-asm" ]]        && export ZIG_ASM="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-asm"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-rc" ]]         && export ZIG_RC="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-rc"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ld" ]]         && export ZIG_LLD="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-ld"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-force-load-cc" ]]  && export ZIG_FORCE_LOAD_CC="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-force-load-cc"
[[ -x "${_wrapper_dir}/${_CONDA_TRIPLET}-zig-force-load-cxx" ]] && export ZIG_FORCE_LOAD_CXX="${_wrapper_dir}/${_CONDA_TRIPLET}-zig-force-load-cxx"

# === Ensure zig can resolve its cache directory ===
# zig's getAppDataDir on Linux checks XDG_DATA_HOME then HOME/.local/share;
# if neither is set it fails with AppDataDirUnavailable.  ZIG_GLOBAL_CACHE_DIR
# overrides the lookup.  Set it here so direct zig invocations (recipe tests,
# zig test, zig build) always have a writable cache, not just wrapper calls.
if [[ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${XDG_DATA_HOME}/zig/zig-cache"
    elif [[ -n "${HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${HOME}/.local/share/zig/zig-cache"
    else
        export ZIG_GLOBAL_CACHE_DIR="${TMPDIR:-/tmp}/zig-cache-$(id -u 2>/dev/null || echo 0)"
    fi
fi

# === Cleanup temporaries ===
unset _CONDA_TRIPLET _CROSS_TARGET_TRIPLET _wrapper_dir _zig_bin
