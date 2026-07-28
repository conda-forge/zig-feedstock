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

TARGET_DIR="${1:?Usage: build_native.sh <output-dir>}"
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
echo "[build_native] Using: ${CONDA_CMD}"

# 1. Create temporary env with build tools (pin LLVM to match zig source)
#    When BUILD_NATIVE_STAGE1_ONLY=1, we use the upstream bootstrap tarball at
#    $SRC_DIR/zig-bootstrap/ instead of conda-installing zig_impl (which may
#    not yet be published for a new major version).
ENV_DIR="${WORK_DIR}/build-env"
if [[ "${BUILD_NATIVE_STAGE1_ONLY:-0}" == "1" ]]; then
    echo "[build_native] BUILD_NATIVE_STAGE1_ONLY=1 — using upstream bootstrap (skipping zig_impl conda dep)"
    ${CONDA_CMD} create -p "${ENV_DIR}" -c conda-forge -y \
        cmake ninja gcc gxx patchelf \
        "llvmdev=${LLVM_VER}.*" "clangdev=${LLVM_VER}.*" "libclang-cpp=${LLVM_VER}.*" "lld=${LLVM_VER}.*" \
        libxml2-devel zlib zstd perl python \
        "sysroot_linux-64=2.17"
else
    ${CONDA_CMD} create -p "${ENV_DIR}" -c conda-forge -y \
        cmake ninja gcc gxx patchelf \
        "llvmdev=${LLVM_VER}.*" "clangdev=${LLVM_VER}.*" "libclang-cpp=${LLVM_VER}.*" "lld=${LLVM_VER}.*" \
        libxml2-devel zlib zstd perl python \
        "sysroot_linux-64=2.17" \
        "zig_impl_${build_platform:-linux-64}>=${PKG_VERSION}"
fi

set +e
eval "$(${CONDA_CMD} shell activate -p "${ENV_DIR}" 2>/dev/null || conda shell.bash activate "${ENV_DIR}")"
_act_rc=$?
set -e
if [[ ${_act_rc} -ne 0 ]]; then
    echo "[build_native] mamba/conda activate returned ${_act_rc}; continuing (deactivate hooks may be noisy)" >&2
fi

# 2. Fix libc/libm linker scripts for zig (zig's lld can't handle relative paths
#    in linker scripts — fix_sysroot_libc_scripts rewrites them to relative paths)
source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_sysroot_fix.sh"
source "${RECIPE_DIR}/building/_atfork.sh"
fix_sysroot_libc_scripts "${ENV_DIR}"

# 3. Find the zig binary to use as bootstrap
if [[ "${BUILD_NATIVE_STAGE1_ONLY:-0}" == "1" ]]; then
    # Upstream bootstrap tarball at $SRC_DIR/zig-bootstrap/ — binary is named
    # <arch-triple>-zig (e.g. x86_64-linux-musl-zig). Search up to 2 levels.
    ZIG_BIN="$(find "${SRC_DIR}/zig-bootstrap" -maxdepth 2 -name '*-zig' -type f 2>/dev/null | head -1)"
    if [[ -z "${ZIG_BIN}" || ! -x "${ZIG_BIN}" ]]; then
        echo "ERROR: No upstream bootstrap zig found in ${SRC_DIR}/zig-bootstrap/" >&2
        exit 1
    fi
    ZIG_LIB_DIR_ARGS=()  # snapshot 1245: `zig build` no longer accepts --zig-lib-dir; lib dir auto-discovered from argv[0]
    echo "[build_native] Bootstrap zig (upstream tarball): ${ZIG_BIN}"
    echo "[build_native] Using zig-lib-dir: ${SRC_DIR}/zig-bootstrap/lib"
else
    # Conda-installed zig_impl provides the bootstrap binary
    ZIG_BIN=$(ls "${ENV_DIR}"/bin/*-zig 2>/dev/null | head -1)
    if [[ -z "${ZIG_BIN}" ]]; then
        echo "ERROR: No zig binary found in ${ENV_DIR}/bin/"
        exit 1
    fi
    ZIG_LIB_DIR_ARGS=()
    echo "[build_native] Bootstrap zig (conda): ${ZIG_BIN}"
fi

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
NATIVE_CC=$(ls "${ENV_DIR}"/bin/x86_64-conda-linux-gnu-cc 2>/dev/null || echo gcc)
create_pthread_atfork_stub "x86_64" "${NATIVE_CC}" "${STUB_DIR}"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${STUB_DIR}/pthread_atfork_stub.o\"|g" \
    "${CMAKE_BUILD}/config.h"
echo "[build_native] Injected pthread_atfork stub into config.h"

# Common zig build args (shared between Stage 1 and Stage 2)
ZIG_BUILD_ARGS=(
    --search-prefix "${ENV_DIR}"
    -Dconfig_h="${CMAKE_BUILD}/config.h"
    -Dcpu=baseline
    -Ddoctest-target=x86_64-linux-gnu.2.17
    -Denable-llvm
    -Dstatic-llvm=false
    # Explicit target ensures zig std lib uses raw syscalls for functions
    # not in glibc 2.17 (e.g., copy_file_range). This script is only used
    # for linux-64 (x86_64) native test builds.
    -Dtarget=x86_64-linux-gnu.2.17
    -Duse-zig-libcxx=false
    -Dversion-string="${PKG_VERSION}"
    --maxrss 8000000000
)

# ==========================================================================
# STAGE 1: Build zig with ZSTD patch, SKIP docgen
#   Bootstrap = conda zig_impl OR upstream tarball (see BUILD_NATIVE_STAGE1_ONLY)
#   Output = zig binary WITH ZSTD decompression + debug info
# ==========================================================================
echo ""
echo "================================================================"
echo "  STAGE 1: Building zig (skip docgen, ZSTD patch applied)"
echo "  Bootstrap: ${ZIG_BIN}"
echo "================================================================"

STAGE1_DIR="${WORK_DIR}/stage1-install"
mkdir -p "${STAGE1_DIR}"

cd "${SRC_DIR}/zig-source"
"${ZIG_BIN}" build \
    --prefix "${STAGE1_DIR}" \
    "${ZIG_LIB_DIR_ARGS[@]}" \
    "${ZIG_BUILD_ARGS[@]}" \
    -Dno-langref \
    -Doptimize=ReleaseSafe \
    2>&1 | tee "${WORK_DIR}/stage1-build.log" || {
        echo "ERROR: Stage 1 zig build failed - see ${WORK_DIR}/stage1-build.log" >&2
        exit 1
    }

STAGE1_ZIG="${STAGE1_DIR}/bin/zig"
if [[ ! -x "${STAGE1_ZIG}" ]]; then
    echo "ERROR: Stage 1 build failed - no zig binary at ${STAGE1_ZIG}"
    exit 1
fi

# Diagnostic: test the freshly-built binary BEFORE any mutation (strip/patchelf).
# Use LD_LIBRARY_PATH to substitute for the missing RPATH so the dynamic linker
# can find libLLVM-22.so etc. in ${ENV_DIR}/lib. This isolates whether failures
# downstream are from the binary itself (miscompile) or from our mutations
# (strip/patchelf side effects). NON-FATAL: just logs the result.
echo "[Stage 1] Diagnostic: testing pre-mutation binary via LD_LIBRARY_PATH..."
if LD_LIBRARY_PATH="${ENV_DIR}/lib" "${STAGE1_ZIG}" version > /dev/null 2>&1; then
    echo "[Stage 1] Pre-mutation binary: WORKS"
else
    echo "[Stage 1] Pre-mutation binary: FAILS (suggests miscompile or partial build)" >&2
fi

# Replace ${STAGE1_ZIG} with a shell wrapper that exports LD_LIBRARY_PATH at
# runtime, instead of using patchelf to rewrite RPATH. patchelf 0.17.2 silently
# corrupts these LLVM-linked zig binaries — pre-mutation binary works via
# LD_LIBRARY_PATH but post-patchelf the binary segfaults. Verified across
# ReleaseSafe / Debug / strip / no-strip combinations. The wrapper approach
# avoids binary mutation entirely. The wrapper bakes in ${ENV_DIR} as an
# absolute path; this is fine as long as the conda build keeps _native_build_tmp
# alive for the rest of the build, which it does.
mv "${STAGE1_ZIG}" "${STAGE1_ZIG}.real"
cat > "${STAGE1_ZIG}" <<EOF
#!/bin/bash
export LD_LIBRARY_PATH="${ENV_DIR}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${STAGE1_ZIG}.real" "\$@"
EOF
chmod +x "${STAGE1_ZIG}"
echo "[Stage 1] Installed LD_LIBRARY_PATH wrapper at ${STAGE1_ZIG}"

# Verify the binary actually executes (catches segfaults from a partially-linked
# zig that passed the file-existence check but is corrupt — e.g. when max_rss
# was exceeded but the build system wrote a partial output before failing).
# Must run AFTER the wrapper is installed, because the freshly-built binary has
# no RPATH for ${ENV_DIR}/lib and the wrapper is what supplies LD_LIBRARY_PATH
# at invocation.
if ! "${STAGE1_ZIG}" version > /dev/null 2>&1; then
    echo "ERROR: Stage 1 zig at ${STAGE1_ZIG} fails to execute (segfault or runtime error)" >&2
    echo "" >&2
    echo "----- stage1-build.log (last 200 lines) -----" >&2
    tail -n 200 "${WORK_DIR}/stage1-build.log" >&2 || echo "(log unreadable)" >&2
    echo "----- end stage1-build.log -----" >&2
    exit 1
fi

echo "[Stage 1] SUCCESS: ${STAGE1_ZIG}"
echo "[Stage 1] Verify ZSTD support:"
"${STAGE1_ZIG}" version

# When BUILD_NATIVE_STAGE1_ONLY=1 (e.g., ppc64le bootstrap use-case), skip
# Stage 2 doctest run and stash Stage 1 as the deliverable directly.
#
# Stash deliverable: copy the .real ELF binary AND install a wrapper that
# (a) uses readlink to find its own location so it can locate its sibling
# .real binary regardless of where TARGET_DIR is placed, and (b) bakes in
# the absolute path to ${ENV_DIR}/lib for LD_LIBRARY_PATH. The original
# patchelf --set-rpath '$ORIGIN/../lib' was incorrect for this deployment
# layout (TARGET_DIR has no ../lib sibling); the libs actually live in
# build_native.sh's mamba env at ${ENV_DIR}/lib, which persists for the
# remainder of the build inside _native_build_tmp.
if [[ "${BUILD_NATIVE_STAGE1_ONLY:-0}" == "1" ]]; then
    echo "[build_native] BUILD_NATIVE_STAGE1_ONLY=1 — skipping Stage 2 doctest run"
    mkdir -p "${TARGET_DIR}"
    cp "${STAGE1_ZIG}.real" "${TARGET_DIR}/zig_native_patched.real"
    chmod +x "${TARGET_DIR}/zig_native_patched.real"
    # Copy Stage 1's zig stdlib alongside the .real binary. zig 0.17 locates
    # its stdlib by walking up from argv[0] looking for a lib/std sibling —
    # without this, build_zig_with_zig's later invocation of the stashed
    # binary fails with "unable to find zig installation directory".
    cp -r "${STAGE1_DIR}/lib" "${TARGET_DIR}/lib"
    cat > "${TARGET_DIR}/zig_native_patched" <<EOF
#!/bin/bash
SELF_DIR=\$(dirname "\$(readlink -f "\$0")")
export LD_LIBRARY_PATH="${ENV_DIR}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\${SELF_DIR}/\$(basename "\$0").real" "\$@"
EOF
    chmod +x "${TARGET_DIR}/zig_native_patched"
    echo "[build_native] Stashed Stage 1 zig (wrapper + .real + lib) to ${TARGET_DIR}/"
    exit 0
fi

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
    -Doptimize=ReleaseSafe \
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
    echo "[build_native] Stashed Stage 1 zig for debugging: ${TARGET_DIR}/zig_native_patched"
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
echo "[build_native] Stashed native zig to ${TARGET_DIR}/zig_native_patched (RPATH fixed)"
