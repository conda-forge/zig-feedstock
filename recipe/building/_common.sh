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

# sanitize_cross_cflags TARGET_ARCH FLAGS...
# Strips arch-incompatible -march/-mtune/-mcpu/-mfeat flags injected by
# conda-build for the build host; deduplicates; prints cleaned flags.
# Intentional target-arch flags (e.g. ppc64le -mlongcall) are never touched
# because they match the target arch family, not the host arch family.
sanitize_cross_cflags() {
  local _tarch="$1"; shift
  local _flags="$*" _result="" _seen="" _flag

  local _drop_x86='-march=nocona|-march=core2|-march=haswell|-march=skylake|-march=x86-64|-march=x86-64-v[234]|-mtune=nocona|-mtune=core2|-mtune=haswell|-mtune=skylake|-mtune=generic|-mssse3|-msse4|-msse4\.1|-msse4\.2|-mavx|-mavx2|-mfma'
  local _drop_arm='-march=armv8-a|-march=armv8\.[0-9]-a|-march=armv9-a|-mtune=cortex-[a-z0-9-]+|-mtune=neoverse-[a-z0-9-]+'
  local _drop_ppc='-mcpu=power[0-9]+|-mtune=power[0-9]+|-mvsx|-maltivec'
  local _drop_riscv='-march=rv64[a-z]*|-mabi=lp64[df]?|-mtune=generic-rv64'
  local _drop_s390x='-march=z[0-9]+|-march=arch[0-9]+|-mtune=z[0-9]+|-mzvector'

  local _remove_pat
  case "${_tarch}" in
    aarch64|arm64)  _remove_pat="${_drop_x86}|${_drop_ppc}|${_drop_riscv}|${_drop_s390x}" ;;
    ppc64le)        _remove_pat="${_drop_x86}|${_drop_arm}|${_drop_riscv}|${_drop_s390x}" ;;
    64|x86_64)      _remove_pat="${_drop_arm}|${_drop_ppc}|${_drop_riscv}|${_drop_s390x}" ;;
    riscv64)        _remove_pat="${_drop_x86}|${_drop_arm}|${_drop_ppc}|${_drop_s390x}" ;;
    s390x)          _remove_pat="${_drop_x86}|${_drop_arm}|${_drop_ppc}|${_drop_riscv}" ;;
    *)              _remove_pat="${_drop_x86}|${_drop_arm}|${_drop_ppc}|${_drop_riscv}|${_drop_s390x}" ;;
  esac

  for _flag in ${_flags}; do
    printf '%s\n' "${_flag}" | grep -qE "^(${_remove_pat})$" && continue
    printf ' %s ' "${_seen}" | grep -qF " ${_flag} " && continue
    _seen="${_seen} ${_flag}"
    _result="${_result:+${_result} }${_flag}"
  done
  echo "${_result}"
}

# sanitize_and_export_cross_flags — sanitize CFLAGS/CXXFLAGS for cross builds.
# Reads ${target_platform}; mutates and re-exports CFLAGS and CXXFLAGS.
sanitize_and_export_cross_flags() {
  local _arch="${target_platform##*-}"
  local _v
  for _v in CFLAGS CXXFLAGS; do
    [[ -z "${!_v:-}" ]] && continue
    declare -g "${_v}=$(sanitize_cross_cflags "${_arch}" "${!_v}")"
    export "${_v}"
  done
}
