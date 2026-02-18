#!/usr/bin/env bash
# Native build for linux-64 using zig as C/C++ compiler - LLVM from source
# This builds LLVM from source with zig cc to avoid ABI mismatch
#
# Strategy:
#   1. Setup zig cc as C/C++ compiler
#   2. Build LLVM/Clang/LLD from source using zig cc (libc++ ABI)
#   3. Build zigcpp using zig cc (libc++ ABI)
#   4. Everything has consistent ABI - no mismatch!

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

ZIG_TARGET="x86_64-linux-gnu"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Native build: linux-64 using zig cc + LLVM from source ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"

# Setup zig as C/C++ compiler
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

# LLVM source location (downloaded by recipe or vendored)
LLVM_SRC="${SRC_DIR}/llvm-project"
LLVM_BUILD="${SRC_DIR}/llvm-build"
LLVM_INSTALL="${SRC_DIR}/llvm-install"

# Check if we have LLVM source
if [[ ! -d "${LLVM_SRC}" ]]; then
    echo "ERROR: LLVM source not found at ${LLVM_SRC}"
    echo "  Need to add LLVM source download to recipe.yaml"
    exit 1
fi

echo "=== Phase 1: Build LLVM with zig cc ==="
mkdir -p "${LLVM_BUILD}"

# Build LLVM with zig cc - only the components zig needs
# This uses zig's libc++ so ABI will match zigcpp
cmake -S "${LLVM_SRC}/llvm" -B "${LLVM_BUILD}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}" \
    -DCMAKE_C_COMPILER="${ZIG_CC}" \
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
    -DCMAKE_AR="${ZIG_AR}" \
    -DCMAKE_RANLIB="${ZIG_RANLIB}" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_RUNTIMES="" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_OCAMLDOC=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF

echo "  Building LLVM (this will take a while)..."
cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
cmake --install "${LLVM_BUILD}"

echo "=== Phase 2: Configure zig with zig-cc-built LLVM ==="
# Point to our zig-cc-built LLVM
export LLVM_CONFIG="${LLVM_INSTALL}/bin/llvm-config"
# Create filtered llvm-config wrapper to remove flags unsupported by zig linker
create_filtered_llvm_config "${LLVM_CONFIG}"

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
    -DZIG_SHARED_LLVM=OFF
    -DZIG_STATIC_LLVM=ON
    -DZIG_USE_LLVM_CONFIG=ON
    -DLLVM_CONFIG_EXE="${LLVM_CONFIG}"
    -DCMAKE_PREFIX_PATH="${LLVM_INSTALL}"
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
EXTRA_ZIG_ARGS+=(
    -Dtarget=${ZIG_TARGET}
)

CMAKE_PATCHES+=(
    0001-linux-maxrss-CMakeLists.txt.patch
)

# Build zigcpp with our zig-cc-built LLVM
configure_cmake_zigcpp "${cmake_build_dir}" "${PREFIX}" "${BOOTSTRAP_ZIG}"

echo "=== LLVM built with zig cc - ABI should match ==="
