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

TARGET_DIR="${1:?Usage: build_native_for_test.sh <output-dir>}"
LLVM_VER="${LLVM_VERSION:?LLVM_VERSION must be set}"
WORK_DIR=$(mktemp -d)
trap "rm -rf ${WORK_DIR}" EXIT

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
# Fix sysroot libc.so linker scripts 2.17 to use relative paths
source ${RECIPE_DIR}/building/_sysroot_fix.sh
fix_sysroot_libc_scripts "${ENV_DIR}"

# 3. Find the zig binary from zig_impl
ZIG_BIN=$(ls "${ENV_DIR}"/bin/*-zig 2>/dev/null | head -1)
if [[ -z "${ZIG_BIN}" ]]; then
    echo "ERROR: No zig binary found in ${ENV_DIR}/bin/"
    exit 1
fi
echo "[build_native_for_test] Using zig: ${ZIG_BIN}"

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

# 5. Build native zig using zig build (not CMake full build)
INSTALL_DIR="${WORK_DIR}/install"
mkdir -p "${INSTALL_DIR}"

cd "${SRC_DIR}/zig-source"
"${ZIG_BIN}" build \
    --prefix "${INSTALL_DIR}" \
    --search-prefix "${ENV_DIR}" \
    -fallow-so-scripts \
    -Dconfig_h="${CMAKE_BUILD}/config.h" \
    -Dcpu=baseline \
    -Denable-llvm \
    -Doptimize=ReleaseFast \
    -Dstatic-llvm=false \
    -Dstrip=true \
    -Dtarget=native \
    -Duse-zig-libcxx=false \
    -Dversion-string="${PKG_VERSION}" \
    --maxrss 7500000000

# 6. Stash the native zig binary and fix RPATH
#    The binary was built against the temp env (ENV_DIR) which gets deleted.
#    Patch RPATH so it resolves libs relative to wherever it's installed.
mkdir -p "${TARGET_DIR}"
cp "${INSTALL_DIR}/bin/zig" "${TARGET_DIR}/zig_native_patched"
chmod +x "${TARGET_DIR}/zig_native_patched"
# At test time, zig_native_patched is overlaid onto $PREFIX/bin/<triplet>-zig
# so RPATH must resolve from bin/ -> ../lib
patchelf --set-rpath '$ORIGIN/../lib' "${TARGET_DIR}/zig_native_patched"
echo "[build_native_for_test] Stashed native zig to ${TARGET_DIR}/zig_native_patched (RPATH fixed)"
