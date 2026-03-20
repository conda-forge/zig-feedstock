#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# ===========================================================================
# Two-stage zig build for debugging langref doctest -lc crashes
#
# Problem: conda zig_impl (bootstrap) lacks ZSTD decompression + debug info.
#   When doctests link with -lc, bootstrap reads libc_nonshared.a which has
#   ZSTD-compressed sections (GCC 13+ -gz=zstd) → @panic("TODO").
#
# Stage 1: Build zig WITH patch 0004 (ZSTD fix), SKIP docgen (-Dno-langref)
#   → Produces zig binary with ZSTD support + debug info (ReleaseSafe)
#
# Stage 2: Use Stage 1 zig as bootstrap, rebuild WITH docgen enabled
#   → Bootstrap can now decompress ZSTD sections
#   → If doctests still crash, we get real stack traces
# ===========================================================================

TARGET_DIR="${1:?Usage: build_native_for_test.sh <output-dir>}"
LLVM_VER="${LLVM_VERSION:?LLVM_VERSION must be set}"
WORK_DIR=${SRC_DIR}/_native_build_tmp && mkdir -p ${SRC_DIR}/_native_build_tmp
# trap "rm -rf ${WORK_DIR}" EXIT

# Find conda/mamba/micromamba
if command -v mamba &>/dev/null; then
    CONDA_CMD=mamba
elif command -v micromamba &>/dev/null; then
    CONDA_CMD=micromamba
elif command -v conda &>/dev/null; then
    CONDA_CMD=conda
else
    echo "ERROR: No conda/mamba/micromamba found"
    exit 1
fi
echo "[build_native_for_test] Using: ${CONDA_CMD}"

# 1. Create temporary env with build tools (pin LLVM to match zig source)
ENV_DIR="${WORK_DIR}/build-env"
${CONDA_CMD} create -p "${ENV_DIR}" -c conda-forge -y \
    cmake ninja gcc gxx patchelf \
    "llvmdev=${LLVM_VER}.*" "clangdev=${LLVM_VER}.*" "libclang-cpp=${LLVM_VER}.*" "lld=${LLVM_VER}.*" \
    libxml2-devel zlib zstd perl python \
    "sysroot_linux-64=${SYSROOT_VERSION}" \
    "zig_impl_${build_platform:-linux-64}>=${PKG_VERSION}"

eval "$(${CONDA_CMD} shell activate -p ${ENV_DIR} 2>/dev/null || conda shell.bash activate ${ENV_DIR})"

# 2. Fix libc/libm linker scripts for zig (same as main build's modify_libc_libm_for_zig)
#    zig's lld can't handle relative paths in linker scripts → replace with symlinks
SYSROOT=$(ls -d "${ENV_DIR}"/*-conda-linux-gnu/sysroot 2>/dev/null | head -1)
if [[ -n "${SYSROOT}" ]]; then
    for lib in libc libm; do
        so="${SYSROOT}/usr/lib64/${lib}.so"
        if [[ -f "$so" ]] && file "$so" | grep -q "text"; then
            echo "  - Replacing ${lib}.so linker script with symlink"
            rm -f "$so"
            ln -sf "../../lib64/${lib}.so.6" "$so"
        fi
    done
fi
# Fix sysroot libc.so linker scripts ${SYSROOT_VERSION} to use relative paths
source ${RECIPE_DIR}/building/_sysroot_fix.sh
fix_sysroot_libc_scripts "${ENV_DIR}"

# 3. Find the zig binary from zig_impl (conda bootstrap)
ZIG_BIN=$(ls "${ENV_DIR}"/bin/*-zig 2>/dev/null | head -1)
if [[ -z "${ZIG_BIN}" ]]; then
    echo "ERROR: No zig binary found in ${ENV_DIR}/bin/"
    exit 1
fi
echo "[build_native_for_test] Bootstrap zig (conda): ${ZIG_BIN}"

# 4. CMake configure + build zigcpp only (generates config.h needed by zig build)
CMAKE_BUILD="${WORK_DIR}/cmake-build"
mkdir -p "${CMAKE_BUILD}"
cmake "${SRC_DIR}/zig-source" \
    -B "${CMAKE_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DZIG_SHARED_LLVM=ON \
    -DZIG_TARGET_MCPU=baseline \
    -DZIG_USE_LLVM_CONFIG=ON \
    -G Ninja
cmake --build "${CMAKE_BUILD}" --target zigcpp -- -j"${CPU_COUNT:-4}"

# 4b. Create pthread_atfork stub (glibc 2.28 libc_nonshared.a not found by lld)
STUB_DIR="${WORK_DIR}/atfork-stub"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/pthread_atfork_stub.c" << 'STUBEOF'
__attribute__((weak))
int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    (void)prepare; (void)parent; (void)child;
    return 0;
}
STUBEOF
NATIVE_CC=$(ls "${ENV_DIR}"/bin/x86_64-conda-linux-gnu-cc 2>/dev/null || echo gcc)
"${NATIVE_CC}" -c "${STUB_DIR}/pthread_atfork_stub.c" -o "${STUB_DIR}/pthread_atfork_stub.o"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${STUB_DIR}/pthread_atfork_stub.o\"|g" \
    "${CMAKE_BUILD}/config.h"
echo "[build_native_for_test] Injected pthread_atfork stub into config.h"

# Common zig build args (shared between Stage 1 and Stage 2)
ZIG_BUILD_ARGS=(
    --search-prefix "${ENV_DIR}"
    -Dconfig_h="${CMAKE_BUILD}/config.h"
    -Dcpu=baseline
    -Ddoctest-target=x86_64-linux-gnu.${SYSROOT_VERSION}
    -Denable-llvm
    -Doptimize=ReleaseSafe
    -Dstatic-llvm=false
    # Explicit target ensures zig std lib uses raw syscalls for functions
    # not in glibc ${SYSROOT_VERSION} (e.g., copy_file_range). This script is only used
    # for linux-64 (x86_64) native test builds.
    -Dtarget=x86_64-linux-gnu.${SYSROOT_VERSION}
    -Duse-zig-libcxx=false
    -Dversion-string="${PKG_VERSION}"
    --maxrss 7500000000
)

# ==========================================================================
# STAGE 1: Build zig with ZSTD patch, SKIP docgen
#   Bootstrap = conda zig_impl (no ZSTD, no debug info)
#   Output = zig binary WITH ZSTD decompression + debug info
# ==========================================================================
echo ""
echo "================================================================"
echo "  STAGE 1: Building zig (skip docgen, ZSTD patch applied)"
echo "  Bootstrap: ${ZIG_BIN} (conda zig_impl)"
echo "================================================================"

STAGE1_DIR="${WORK_DIR}/stage1-install"
mkdir -p "${STAGE1_DIR}"

cd "${SRC_DIR}/zig-source"
"${ZIG_BIN}" build \
    --prefix "${STAGE1_DIR}" \
    "${ZIG_BUILD_ARGS[@]}" \
    -Dno-langref

STAGE1_ZIG="${STAGE1_DIR}/bin/zig"
if [[ ! -x "${STAGE1_ZIG}" ]]; then
    echo "ERROR: Stage 1 build failed - no zig binary at ${STAGE1_ZIG}"
    exit 1
fi
# Fix RPATH so Stage 1 zig can find LLVM shared libs from build-env
patchelf --set-rpath "${ENV_DIR}/lib" "${STAGE1_ZIG}"
echo "[Stage 1] SUCCESS: ${STAGE1_ZIG}"
echo "[Stage 1] Verify ZSTD support:"
"${STAGE1_ZIG}" version

# ==========================================================================
# STAGE 2: Rebuild WITH docgen using Stage 1 zig as bootstrap
#   Bootstrap = Stage 1 zig (HAS ZSTD decompression + debug info)
#   This tests whether patch 0004 fixes the doctest -lc crashes
#   Do NOT strip failing langref tests — we want them to run
# ==========================================================================
echo ""
echo "================================================================"
echo "  STAGE 2: Rebuilding WITH docgen (langref doctests enabled)"
echo "  Bootstrap: ${STAGE1_ZIG} (Stage 1, has ZSTD patch)"
echo "================================================================"

STAGE2_DIR="${WORK_DIR}/stage2-install"
mkdir -p "${STAGE2_DIR}"

# Stage 1 zig needs lib/zig from the source tree to function as bootstrap
# Set --zig-lib-dir so it finds std lib in the source, not relative to binary
cd "${SRC_DIR}/zig-source"
"${STAGE1_ZIG}" build \
    --prefix "${STAGE2_DIR}" \
    "${ZIG_BUILD_ARGS[@]}" \
    2>&1 | tee "${WORK_DIR}/stage2-build.log" || {
    echo ""
    echo "================================================================"
    echo "  STAGE 2 FAILED — doctest crash details above"
    echo "  Full log: ${WORK_DIR}/stage2-build.log"
    echo "================================================================"
    echo ""
    echo "The Stage 1 zig (with ZSTD patch + debug info) is at:"
    echo "  ${STAGE1_ZIG}"
    echo ""
    echo "To manually debug a specific doctest:"
    echo "  ${STAGE1_ZIG} test doc/langref/test_variadic_function.zig \\"
    echo "    --zig-lib-dir lib -lc"
    echo ""
    # Still stash Stage 1 for manual debugging
    mkdir -p "${TARGET_DIR}"
    cp "${STAGE1_ZIG}" "${TARGET_DIR}/zig_native_patched"
    chmod +x "${TARGET_DIR}/zig_native_patched"
    patchelf --set-rpath '$ORIGIN/../lib' "${TARGET_DIR}/zig_native_patched"
    echo "[build_native_for_test] Stashed Stage 1 zig for debugging: ${TARGET_DIR}/zig_native_patched"
    exit 1
}

echo ""
echo "================================================================"
echo "  STAGE 2 SUCCESS — langref doctests passed with ZSTD patch!"
echo "================================================================"

# 7. Stash the Stage 2 zig binary and fix RPATH
#    The binary was built against the temp env (ENV_DIR) which gets deleted.
#    Patch RPATH so it resolves libs relative to wherever it's installed.
mkdir -p "${TARGET_DIR}"
cp "${STAGE2_DIR}/bin/zig" "${TARGET_DIR}/zig_native_patched"
chmod +x "${TARGET_DIR}/zig_native_patched"
# At test time, zig_native_patched is overlaid onto $PREFIX/bin/<triplet>-zig
# so RPATH must resolve from bin/ -> ../lib
patchelf --set-rpath '$ORIGIN/../lib' "${TARGET_DIR}/zig_native_patched"
echo "[build_native_for_test] Stashed native zig to ${TARGET_DIR}/zig_native_patched (RPATH fixed)"
