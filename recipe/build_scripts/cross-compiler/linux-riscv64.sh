#!/usr/bin/env bash
# Cross-compiler build for linux-riscv64 using zig as C/C++ compiler
# Binary RUNS on linux-64, TARGETS linux-riscv64
# NO SYSROOT NEEDED - zig bundles cross-compilation support
#
# This script uses zig cc instead of GCC, eliminating:
#   - modify_libc_libm_for_zig (zig handles sysroot internally)
#   - create_gcc14_glibc28_compat_lib (zig uses bundled libc)
#   - create_pthread_atfork_stub (zig libc handles this)

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="riscv64-linux-gnu"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Cross-compiler: linux-64 -> linux-riscv64 using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"
echo "  No sysroot required - zig handles cross-compilation internally"

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
    EXTRA_CMAKE_ARGS+=(
        -DCMAKE_PREFIX_PATH="${ZIG_LLVM_PATH}"
        -DLLVM_CONFIG_EXE="${LLVM_CONFIG}"
        -DZIG_SHARED_LLVM=OFF
        -DZIG_STATIC_LLVM=ON
    )
else
    echo "  WARNING: zig-llvmdev not found at ${ZIG_LLVM_PATH}"
fi

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=riscv64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DCMAKE_CROSSCOMPILING=ON
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
)

# Only maxrss patch needed
CMAKE_PATCHES+=(
    0001-linux-maxrss-CMakeLists.txt.patch
)

# Build zigcpp library (runs on linux-64)
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "${BOOTSTRAP_ZIG}"
