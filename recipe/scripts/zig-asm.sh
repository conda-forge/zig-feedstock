#!/usr/bin/env bash
# --- Sysroot detection (Linux only) ---
_sysroot_flags=()
if [[ "$(uname -s)" == "Linux" ]] && [[ "@ZIG_TARGET@" != "native" ]]; then
    _arch="@ZIG_TARGET_ARCH@"
    _sr="${CONDA_PREFIX}/${_arch}-conda-linux-gnu/sysroot"
    [[ ! -d "${_sr}" ]] && _sr="${CONDA_BUILD_SYSROOT:-}"
    if [[ -d "${_sr}" ]]; then
        _sysroot_flags+=(-isysroot "${_sr}")
    fi
fi
exec "@ZIG_BIN@" cc -target @ZIG_TARGET@ -mcpu=baseline "${_sysroot_flags[@]}" "$@"
