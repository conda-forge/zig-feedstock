#!/usr/bin/env bash
# Native build for linux-64 using zig as C/C++ compiler
# Binary RUNS on linux-64, TARGETS linux-64
#
# This script uses zig cc instead of GCC, eliminating the need for:
#   - modify_libc_libm_for_zig (zig handles sysroot internally)
#   - create_gcc14_glibc28_compat_lib (zig uses bundled libc stubs)
#   - create_pthread_atfork_stub (zig libc doesn't have this gap)

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-linux-gnu"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Native build: linux-64 using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"

# Setup zig as C/C++ compiler (eliminates GCC workarounds)
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

# Check for zig-llvmdev (LLVM built with zig cc, installed to lib/zig-llvm/)
ZIG_LLVM_PATH="${PREFIX}/lib/zig-llvm"
if [[ -f "${PREFIX}/lib/zig-llvm-path.txt" ]]; then
    ZIG_LLVM_PATH=$(cat "${PREFIX}/lib/zig-llvm-path.txt")
fi

if [[ -d "${ZIG_LLVM_PATH}" ]]; then
    echo "  Using zig-llvmdev: ${ZIG_LLVM_PATH}"
    LLVM_CONFIG="${ZIG_LLVM_PATH}/bin/llvm-config"
    # Ensure llvm-config wrapper is in place to filter unsupported linker flags
    # (zig's linker doesn't support GNU ld flags like -Bsymbolic-functions)
    create_filtered_llvm_config "${LLVM_CONFIG}"
    EXTRA_CMAKE_ARGS+=(
        -DCMAKE_PREFIX_PATH="${ZIG_LLVM_PATH}"
        -DLLVM_CONFIG_EXE="${LLVM_CONFIG}"
    )
else
    echo "  WARNING: zig-llvmdev not found at ${ZIG_LLVM_PATH}"
    echo "  Falling back to system LLVM (may cause ABI mismatch)"
    # Even for system LLVM, wrap llvm-config to filter unsupported linker flags
    if [[ -x "${PREFIX}/bin/llvm-config" ]]; then
        create_filtered_llvm_config "${PREFIX}/bin/llvm-config"
    fi
fi

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
# Use shared LLVM since we're building with LLVM_BUILD_LLVM_DYLIB=ON
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
    -Dstatic-llvm=false
)

# Only maxrss patch needed - pthread_atfork handled by zig
CMAKE_PATCHES+=(
    0001-linux-maxrss-CMakeLists.txt.patch
)

# Build zigcpp library (still needed for CMake integration)
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "${BOOTSTRAP_ZIG}"
