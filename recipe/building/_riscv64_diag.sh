#!/usr/bin/env bash
# riscv64 sysroot GROUP-rewrite experiment diagnostics.
# sysroot_diag() is a no-op unless DEBUG_ZIG_BUILD=1 and must never fail the build.

source "${RECIPE_DIR}/building/_common.sh"

function sysroot_diag() {
  local phase="${1:-unknown}"
  [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]] || return 0

  local sysroot="${CONDA_BUILD_SYSROOT:-}"
  echo "=== sysroot_diag: ${phase} ==="
  echo "CONDA_BUILD_SYSROOT=${sysroot:-(unset)}"
  echo "build_platform=${build_platform:-(unset)} target_platform=${target_platform:-(unset)} is_cross=$(is_cross && echo true || echo false)"
  echo "ZIG_SYSROOT_MODE=${ZIG_SYSROOT_MODE:-(unset -> legacy)}"

  local rel
  for rel in usr/lib lib64 lib64/lp64d lib; do
    if [[ -e "${sysroot}/${rel}" ]]; then
      ls -ld "${sysroot}/${rel}" 2>&1 || true
      readlink "${sysroot}/${rel}" 2>/dev/null || true
    else
      echo "${rel}: MISSING"
    fi
  done

  local libc="${sysroot}/usr/lib/libc.so"
  if [[ -f "${libc}" ]] && grep -q -E "^(GROUP|INPUT)" "${libc}" 2>/dev/null; then
    echo "--- ${libc} ---"
    cat "${libc}" 2>&1 || true
  fi

  if [[ -f "${libc}.orig" ]]; then
    echo "--- ${libc}.orig (PRE-REWRITE original) ---"
    cat "${libc}.orig" 2>&1 || true
  fi

  echo "=== end sysroot_diag: ${phase} ==="
  return 0
}
