#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

EXTRA_CMAKE_ARGS+=(
  -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
