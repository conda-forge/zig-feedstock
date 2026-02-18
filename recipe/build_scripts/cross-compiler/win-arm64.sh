#!/usr/bin/env bash
# Cross-compiler ENVIRONMENT SETUP for win-arm64
# Native zig (linux-64) configured to TARGET win-arm64
# NO COMPILATION - just environment variables for zig_$TG_ activation package
#
# NOTE: This script should NOT be executed directly.
# zig_impl_$TG_ is skipped for cross-compiler mode in recipe.yaml.
# Only zig_$TG_ (activation package via install_zig_activation.py) is built.
#
# This file serves as DOCUMENTATION for cross-compiler environment setup.

echo "=== Cross-compiler Environment: linux-64 -> win-arm64 ==="
echo "  This script should not run - cross-compiler skips zig_impl build"
echo "  Environment setup is handled by install_zig_activation.py"

# Environment variables that would be used by activation scripts:
# ZIG_TARGET="aarch64-windows-gnu"
# ZIG_MCPU="baseline"
