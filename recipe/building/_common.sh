# _common.sh — shared predicates and helpers sourced by recipe/build.sh and recipe/building/*.sh
# Idempotency-guarded; safe to source multiple times.
# Requires: ${target_platform} and ${build_platform} to be set by the caller before any function call.

[[ -n "${_ZIG_COMMON_SH_SOURCED:-}" ]] && return 0
_ZIG_COMMON_SH_SOURCED=1

is_linux()    { [[ "${target_platform}" == "linux-"* ]]; }
is_osx()      { [[ "${target_platform}" == "osx-"* ]]; }
is_unix()     { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross()    { [[ "${build_platform}" != "${target_platform}" ]]; }

dbg() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]] && "$@" || true; }
