#!/bin/bash
# Zig compiler activation script
# Installed to: $PREFIX/etc/conda/activate.d/zig_activate.sh

# === Toolchain configuration (user-overridable) ===
export CONDA_ZIG_CC="${CONDA_ZIG_CC:-@CC@}"
export CONDA_ZIG_CXX="${CONDA_ZIG_CXX:-@CXX@}"
export CONDA_ZIG_AR="${CONDA_ZIG_AR:-@AR@}"
export CONDA_ZIG_LD="${CONDA_ZIG_LD:-@LD@}"

# === Cross-compiler specific (set only for cross builds) ===
if [[ -n "@CROSS_TARGET_TRIPLET@" ]]; then
    export ZIG_TARGET_TRIPLET="@CROSS_TARGET_TRIPLET@"
fi
