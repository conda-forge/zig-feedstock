#!/usr/bin/env bash
# =============================================================================
# Zig Feedstock Build Functions - Main Entry Point
# =============================================================================
#
# This file sources all modular function libraries for the zig build system.
# Each library contains logically grouped functions:
#
#   _zig_cc.sh    - zig cc compiler wrappers (for zig-native build mode)
#   _bootstrap.sh - GCC-based bootstrap build helpers
#   _cmake.sh     - CMake configuration and build helpers
#   _cross.sh     - Cross-compilation helpers (QEMU, libc config)
#   _build.sh     - Main zig build functions
#   _install.sh   - Installation functions for packages
#
# Usage:
#   source "${RECIPE_DIR}/build_scripts/_functions.sh"
#
# =============================================================================

# Get the directory containing this script
_FUNCTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all function libraries
source "${_FUNCTIONS_DIR}/_zig_cc.sh"
source "${_FUNCTIONS_DIR}/_bootstrap.sh"
source "${_FUNCTIONS_DIR}/_cmake.sh"
source "${_FUNCTIONS_DIR}/_cross.sh"
source "${_FUNCTIONS_DIR}/_build.sh"
source "${_FUNCTIONS_DIR}/_install.sh"
