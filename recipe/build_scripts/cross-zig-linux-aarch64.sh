#!/usr/bin/env bash
set -euo pipefail

# --- Main ---

# Disable stack protection for cross-compilation build tools
# The intermediate build tools (zig-wasm2c, zig1) don't need stack protection
# and glibc 2.28 aarch64 has issues with __stack_chk_guard symbol
export CFLAGS="${CFLAGS} -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS} -fno-stack-protector"

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# perl -pi -e 's/#define ZIG_LLVM_LINK_MODE "static"/#define ZIG_LLVM_LINK_MODE "shared"/g' "${cmake_build_dir}/config.h"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
cat "${cmake_build_dir}/config.h"
