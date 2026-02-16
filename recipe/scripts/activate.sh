#!/bin/bash
# Zig compiler activation script
# Installed to: $PREFIX/etc/conda/activate.d/zig_activate.sh

# === Cross-compiler specific (set only for cross builds) ===
if [[ -n "@CROSS_TARGET_TRIPLET@" ]]; then
    export ZIG_TARGET_TRIPLET="@CROSS_TARGET_TRIPLET@"
fi
