#!/usr/bin/env bash
set -euo pipefail

# --- Main ---

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}"
perl -pi -e "s@;-lm@;$PREFIX/lib/libc++.dylib;-lm@" "${cmake_build_dir}"/config.h
