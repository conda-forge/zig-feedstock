#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

EXTRA_CMAKE_ARGS+=(
  -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
perl -pi -e "s@libLLVMXRay.a@libLLVMXRay.a;$PREFIX/lib/libxml2.dylib;$PREFIX/lib/libzstd.dylib;$PREFIX/lib/libz.dylib@" "${cmake_build_dir}/config.h"
