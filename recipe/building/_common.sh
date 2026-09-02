# _common.sh -- shared predicates and helpers sourced by recipe/build.sh and recipe/building/*.sh
# Idempotency-guarded; safe to source multiple times.
# Requires: ${target_platform} and ${build_platform} to be set by the caller before any function call.

[[ -n "${_ZIG_COMMON_SH_SOURCED:-}" ]] && return 0
_ZIG_COMMON_SH_SOURCED=1

is_linux()    { [[ "${target_platform}" == "linux-"* ]]; }
is_osx()      { [[ "${target_platform}" == "osx-"* ]]; }
is_unix()     { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross()    { [[ "${build_platform}" != "${target_platform}" ]]; }

# Debug helper. Gated on DEBUG_ZIG_BUILD=1.
# Disables xtrace inside the body and restores it afterwards: conda-build runs
# build scripts under `set -x`, and without this each DISABLED dbg call still
# emits 3 trace lines (invocation + `[[ 0 == \1 ]]` + `true`). The caller-level
# `+ dbg echo ...` line is unavoidable; this removes the other two.
dbg() {
  local _dbg_x=0
  case $- in *x*) _dbg_x=1 ;; esac
  { set +x; } 2>/dev/null
  if [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; then
    "$@"
  fi
  if [[ "${_dbg_x}" == "1" ]]; then { set -x; } 2>/dev/null; fi
  return 0
}
