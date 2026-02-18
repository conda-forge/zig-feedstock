#!/usr/bin/env bash
set -euo pipefail

# --- Main ---

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "" "${target_platform}"

# Create pthread_atfork stub for CMake fallback
create_pthread_atfork_stub "${ZIG_ARCH}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
