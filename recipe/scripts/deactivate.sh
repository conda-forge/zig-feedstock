#!/bin/bash
# Zig compiler deactivation script
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_deactivate.sh

# === Unset all zig-cc variables ===
unset ZIG_CC
unset ZIG_CXX
unset ZIG_AR
unset ZIG_RANLIB
unset ZIG_ASM
unset ZIG_RC
unset ZIG_FORCE_LOAD_CC

# === Unset toolchain identification ===
unset CONDA_ZIG_BUILD
unset CONDA_ZIG_HOST

# === Unset cross-compiler variables ===
unset ZIG_TARGET_TRIPLET
