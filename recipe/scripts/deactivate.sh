#!/bin/bash
# Zig compiler deactivation script
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_deactivate.sh

# === Unset cross-compiler variables ===
unset ZIG_TARGET_TRIPLET
