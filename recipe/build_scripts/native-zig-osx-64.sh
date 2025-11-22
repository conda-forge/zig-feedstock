#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="x86_64"
ZIG_ARCH="x86_64"

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-macos-none
  -DZIG_TARGET_MCPU=native
)

EXTRA_ZIG_ARGS+=(
  -Dtarget=${ZIG_ARCH}-macos-none
  -Dcpu=native
)

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h

# This script only sets up EXTRA_ZIG_ARGS and EXTRA_CMAKE_ARGS
echo "macOS-64 configuration complete. EXTRA_ZIG_ARGS contains ${#EXTRA_ZIG_ARGS[@]} arguments."
