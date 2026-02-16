#!/bin/bash
# Zig compiler deactivation script
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_deactivate.sh

# === Unset toolchain variables ===
unset CONDA_ZIG_CC CONDA_ZIG_CXX CONDA_ZIG_AR CONDA_ZIG_LD
unset ZIG_TARGET_TRIPLET
