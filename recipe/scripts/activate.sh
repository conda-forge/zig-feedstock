#!/bin/bash
# Zig compiler activation script
# Installed to: $PREFIX/etc/conda/activate.d/zig_activate.sh
#
# Exports ZIG_CC, ZIG_CXX, etc. pointing to compiled wrappers
# in $CONDA_PREFIX/bin/

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

# === Export variables ===
_zig_bin="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig"
[[ -x "${_zig_bin}" ]] && export ZIG="${_zig_bin}"

[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-cc" ]]             && export ZIG_CC="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-cc"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-cxx" ]]            && export ZIG_CXX="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-cxx"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-ar" ]]             && export ZIG_AR="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-ar"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-ranlib" ]]         && export ZIG_RANLIB="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-ranlib"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-asm" ]]            && export ZIG_ASM="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-asm"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-rc" ]]             && export ZIG_RC="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-rc"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-lld" ]]            && export ZIG_LLD="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-lld"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-force-load-cc" ]]  && export ZIG_FORCE_LOAD_CC="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-force-load-cc"
[[ -x "${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-force-load-cxx" ]] && export ZIG_FORCE_LOAD_CXX="${CONDA_PREFIX}/bin/${_CONDA_TRIPLET}-zig-force-load-cxx"

# === Ensure zig can resolve its cache directory ===
# zig's getAppDataDir on Linux checks XDG_DATA_HOME then HOME/.local/share;
# if neither is set it fails with AppDataDirUnavailable.  ZIG_GLOBAL_CACHE_DIR
# overrides the lookup.  Set it here so direct zig invocations (recipe tests,
# zig test, zig build) always have a writable cache, not just wrapper calls.
# NOTE: same fallback logic is duplicated in recipe/testing/_test_utils.py:setup_zig_global_cache_dir()
# Keep both implementations in sync until the cross-language duplication is consolidated.
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
unset _CONDA_TRIPLET _CROSS_TARGET_TRIPLET _zig_bin
