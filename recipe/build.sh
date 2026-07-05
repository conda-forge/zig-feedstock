#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# === Master dispatch: build.sh is called for both the LLVM/zig staging output
echo "=== Bug 2 diagnostic: env at build.sh entry ==="
echo "  target_platform                = ${target_platform:-<unset>}"
echo "  build_platform                 = ${build_platform:-<unset>}"
echo "  cross_target_platform          = ${cross_target_platform:-<unset>}"
echo "  cross_target_platform_         = ${cross_target_platform_:-<unset>}"
echo "  CONDA_BUILD_CROSS_COMPILATION  = ${CONDA_BUILD_CROSS_COMPILATION:-<unset>}"
echo "  LLVM_TRIPLET                   = ${LLVM_TRIPLET:-<unset>}"
echo "  ZIG_TRIPLET                    = ${ZIG_TRIPLET:-<unset>}"
echo "  ZIG_TARGET_BUILD               = ${ZIG_TARGET_BUILD:-<unset>}"
echo "  CONDA_BUILD_SYSROOT            = ${CONDA_BUILD_SYSROOT:-<unset>}"
echo "  MACOSX_DEPLOYMENT_TARGET       = ${MACOSX_DEPLOYMENT_TARGET:-<unset>}"
echo "==============================================="

if [[ "${target_platform}" == "linux-riscv64" || "${target_platform}" == "linux-s390x" ]]; then
  # Bootstrap zig wrappers (installs $BUILD_PREFIX/share/zig/wrappers/<triplet>-zig-*)
  # zig_impl_* build dep has no activation; we must run this manually.
  source "${RECIPE_DIR}/llvm/building/_zig_wrappers.sh"

  # zig build 30 removed the per-target $BUILD_PREFIX/share/zig/wrappers/<triplet>-zig-*
  # binaries. Cross-target the mini-builds exactly like the LLVM build
  # (_cross_compile.sh): keep the BUILD-host cc that _zig_wrappers.sh exported and pass
  # the TARGET triple via -DCMAKE_*_COMPILER_TARGET=${ZIG_TRIPLET} inside each dep
  # script. ZIG_TRIPLET is glibc-suffixed (e.g. riscv64-linux-gnu.2.39), so the emitted
  # .so files carry the correct symbol-version floor; the zig-cc wrapper defers to an
  # explicit -target, so the BUILD-host cc produces target-arch code. Using ZIG_TRIPLET
  # (per-target) also fixes the previous hardcode that mis-targeted s390x as riscv64.
  if [[ -z "${ZIG_TRIPLET:-}" ]]; then
    echo "ERROR: ZIG_TRIPLET unset — cannot cross-target the riscv64/s390x dep builds" >&2
    exit 1
  fi
  echo "DBG ${target_platform} mini-builds: ZIG_CC=${ZIG_CC} target=${ZIG_TRIPLET}"

  ( cd "${SRC_DIR}/libxml2-source" && "${RECIPE_DIR}"/building/libxml2_build.sh )
  ( cd "${SRC_DIR}/zlib-source"    && "${RECIPE_DIR}"/building/zlib_build.sh    )
  ( cd "${SRC_DIR}/zstd-source"    && "${RECIPE_DIR}"/building/zstd_build.sh    )
fi

"${RECIPE_DIR}"/building/llvm_build.sh
"${RECIPE_DIR}"/building/zig_build.sh
