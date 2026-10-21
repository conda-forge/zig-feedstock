#!/bin/bash
# Zig compiler deactivation script
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_deactivate.sh

# === Unset all zig variables ===
unset ZIG
unset ZIG_CC
unset ZIG_CXX
unset ZIG_AR
unset ZIG_RANLIB
unset ZIG_ASM
unset ZIG_RC
unset ZIG_LLD
unset ZIG_FORCE_LOAD_CC
unset ZIG_FORCE_LOAD_CXX

# === Unset ZIG_LIBCXX only if activation set it ===
if [[ -n "${_CONDA_ZIG_LIBCXX_AUTO:-}" ]]; then
    unset ZIG_LIBCXX
    unset _CONDA_ZIG_LIBCXX_AUTO
fi

# === Unset toolchain identification ===
unset CONDA_ZIG_BUILD
unset CONDA_ZIG_HOST

# === Unset cross-compiler variables ===
unset ZIG_TARGET_TRIPLET
