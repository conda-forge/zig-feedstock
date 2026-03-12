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
[[ -x "${_wrapper_dir}/zig-cc" ]]         && export ZIG_CC="${_wrapper_dir}/zig-cc"
[[ -x "${_wrapper_dir}/zig-cxx" ]]        && export ZIG_CXX="${_wrapper_dir}/zig-cxx"
[[ -x "${_wrapper_dir}/zig-ar" ]]         && export ZIG_AR="${_wrapper_dir}/zig-ar"
[[ -x "${_wrapper_dir}/zig-ranlib" ]]     && export ZIG_RANLIB="${_wrapper_dir}/zig-ranlib"
[[ -x "${_wrapper_dir}/zig-asm" ]]        && export ZIG_ASM="${_wrapper_dir}/zig-asm"
[[ -x "${_wrapper_dir}/zig-rc" ]]         && export ZIG_RC="${_wrapper_dir}/zig-rc"
[[ -x "${_wrapper_dir}/zig-cxx-shared" ]]    && export ZIG_CXX_SHARED="${_wrapper_dir}/zig-cxx-shared"
[[ -x "${_wrapper_dir}/zig-force-load-cc" ]]  && export ZIG_FORCE_LOAD_CC="${_wrapper_dir}/zig-force-load-cc"
[[ -x "${_wrapper_dir}/zig-force-load-cxx" ]] && export ZIG_FORCE_LOAD_CXX="${_wrapper_dir}/zig-force-load-cxx"

# === Cleanup temporaries ===
unset _CONDA_TRIPLET _CROSS_TARGET_TRIPLET _wrapper_dir
