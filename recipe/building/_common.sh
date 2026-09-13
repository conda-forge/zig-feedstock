# _common.sh — shared predicates and helpers sourced by recipe/build.sh and recipe/building/*.sh
# Idempotency-guarded; safe to source multiple times.
# Requires: ${target_platform} and ${build_platform} to be set by the caller before any function call.

if [[ -n "${_ZIG_COMMON_SH_SOURCED:-}" ]]; then
  return 0
fi
_ZIG_COMMON_SH_SOURCED=1

is_linux()    { [[ "${target_platform}" == "linux-"* ]]; }
is_osx()      { [[ "${target_platform}" == "osx-"* ]]; }
is_unix()     { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross()    { [[ "${build_platform}" != "${target_platform}" ]]; }

# xtrace-quiet: conda-build/rattler-build runs the build script under `set -x`
# from outside recipe/, so a DISABLED dbg call still emitted three trace lines
# (the invocation, the gate test, and the `true`). Suppress xtrace across the
# body and restore it, leaving only the caller-level invocation line.
dbg() {
  { local _x; case $- in *x*) _x=1;; *) _x=0;; esac; set +x; } 2>/dev/null
  [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]] && "$@"
  [[ ${_x} == 1 ]] && { set -x; } 2>/dev/null
  return 0
}

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
    if printf ' %s ' "${_seen}" | grep -qF " ${_flag} "; then
      continue
    fi
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
    printf -v "${_v}" '%s' "$(sanitize_cross_cflags "${_arch}" "${!_v}")"
    export "${_v}"
  done
}

_cfg_subst() {  # _cfg_subst FILE PATTERN REPL [g]
  python - "$@" <<'PY'
import re, sys
path, pat, repl = sys.argv[1], sys.argv[2], sys.argv[3]
count = 0 if len(sys.argv) > 4 else 1
with open(path, 'r', newline='') as f:
    data = f.read()
with open(path, 'w', newline='') as f:
    f.write(''.join(re.sub(pat, repl, ln, count=count)
                    for ln in data.splitlines(keepends=True)))
PY
}

_cfg_subst_lit() {  # _cfg_subst_lit FILE LITERAL REPL -- literal, global, ZIG_LLVM_ lines only
  python - "$@" <<'PY'
import sys
path, lit, repl = sys.argv[1], sys.argv[2], sys.argv[3]

def spellings(p):
    """MSYS POSIX (/c/x), CMake (C:/x) and native (C:\\x) forms of one path."""
    forms = [p]
    if len(p) > 2 and p[0] == '/' and p[2] == '/':
        drive, rest = p[1].upper(), p[3:]
        forms.append(drive + ':/' + rest)
        forms.append(drive + ':\\' + rest.replace('/', '\\'))
    return forms

pairs = list(zip(spellings(lit), spellings(repl)))
with open(path, 'r', newline='') as f:
    data = f.read()
out = []
for ln in data.splitlines(keepends=True):
    if 'ZIG_LLVM_' in ln:
        for a, b in pairs:
            ln = ln.replace(a, b)
    out.append(ln)
with open(path, 'w', newline='') as f:
    f.write(''.join(out))
PY
}
