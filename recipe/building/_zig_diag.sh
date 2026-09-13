#!/usr/bin/env bash
# Zig build diagnostics, two tiers (reuses the recipe.yaml-plumbed
# DEBUG_ZIG_BUILD toggle -- no new variable, no recipe.yaml changes needed).
#   ALWAYS-ON: paired phase BEGIN/END spans with rc + elapsed, plus a one-line
#     host fingerprint.  A handful of lines per build.  These make a failed
#     multi-hour emulated lane analysable without paying for a re-run, and a
#     BEGIN with no matching END means killed from outside.
#   GATED on DEBUG_ZIG_BUILD=1: env dumps and per-command verbosity.
# zig_diag_exec always runs its command and re-raises its exit code -- the gate
# only ever affects output, never control flow.
# Never fails the build -- every external command is guarded (command -v /
# || true) so this file is safe under set -euo pipefail.

if [[ -n "${_ZIG_DIAG_SH_SOURCED:-}" ]]; then
  return 0
fi
_ZIG_DIAG_SH_SOURCED=1

source "${RECIPE_DIR}/building/_common.sh"

zig_diag_on() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

# Always-on tier -- never gated.
zig_diag_span() { echo "[zig-diag] $*" >&2; }

# One always-on line: the host facts that explain scheduling behaviour later.
zig_diag_fingerprint() {
  local _n="unknown"
  command -v nproc &>/dev/null && _n=$(nproc) || true
  zig_diag_span "host: nproc=${_n} target=${target_platform:-<unset>} build=${build_platform:-<unset>} triplet=${ZIG_TRIPLET:-<unset>}"
}

# Gated tier -- silent unless DEBUG_ZIG_BUILD=1.
zig_diag_note() {
  zig_diag_on || return 0
  echo "[zig-diag] $*" >&2
}

zig_diag_env() {
  local label="${1:-unknown}"
  zig_diag_on || return 0
  zig_diag_note "=== env: ${label} ==="
  command -v free &>/dev/null && free -m >&2 || true
  command -v nproc &>/dev/null && zig_diag_note "nproc=$(nproc)" || true
  ulimit -a >&2 || true
  zig_diag_note "target_platform=${target_platform:-<unset>}"
  zig_diag_note "build_platform=${build_platform:-<unset>}"
  zig_diag_note "PREFIX=${PREFIX:-<unset>}"
  zig_diag_note "BUILD_PREFIX=${BUILD_PREFIX:-<unset>}"
  zig_diag_note "CONDA_BUILD_SYSROOT=${CONDA_BUILD_SYSROOT:-<unset>}"
  zig_diag_note "ZIG_TRIPLET=${ZIG_TRIPLET:-<unset>}"
  zig_diag_note "ZIG_QEMU_ARCH=${ZIG_QEMU_ARCH:-<unset>}"
  zig_diag_note "QEMU_EXECVE=${QEMU_EXECVE:-<unset>}"
  zig_diag_note "QEMU_EXECVE_NATIVE_PASSTHROUGH=${QEMU_EXECVE_NATIVE_PASSTHROUGH:-<unset>}"
  zig_diag_note "QEMU_LD_PREFIX=${QEMU_LD_PREFIX:-<unset>}"
  zig_diag_note "CPU_COUNT=${CPU_COUNT:-<unset>}"
  zig_diag_note "SKIP_LANGREF=${SKIP_LANGREF:-<unset>}"
  zig_diag_note "DEBUG_ZIG_BUILD=${DEBUG_ZIG_BUILD:-<unset>}"
  zig_diag_note "=== end env: ${label} ==="
  return 0
}

# Always runs the command and re-raises its exit code unchanged.  BEGIN/END
# spans are always-on and PAIRED -- a BEGIN with no END means the process was
# killed from outside before its own timeout fired.  Only the echoed command
# line is gated.
zig_diag_exec() {
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  if zig_diag_on; then
    zig_diag_span "BEGIN ${label}: $*"
  else
    zig_diag_span "BEGIN ${label}"
  fi
  local _start=${SECONDS}
  local rc=0
  "$@" || rc=$?
  local _elapsed=$((SECONDS - _start))
  local _sig=""
  if [[ ${rc} -ge 128 ]]; then
    _sig=" signal=$(kill -l $((rc - 128)) 2>/dev/null || echo unknown)"
  fi
  zig_diag_span "END ${label}: rc=${rc} elapsed=${_elapsed}s${_sig}"
  return ${rc}
}
