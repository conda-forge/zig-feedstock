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

# _codesign_adhoc PATH: apply an ad-hoc code signature to a compiled binary
# (macOS-only; no-op elsewhere). On Apple Silicon the kernel's AMFI enforcement
# refuses to exec ANY Mach-O binary that lacks at least an ad-hoc signature,
# failing with OSError [Errno 8] "Exec format error"; zig's self-hosted linker
# (unlike Apple's ld64) never emits one. A freshly linked unsigned binary can
# appear to run once (e.g. a shell's own `"$bin" --version` self-check
# immediately after compiling it) due to macOS's implicit first-exec trust for
# that exact vnode, but a `cp` of the same bytes to a new file/inode is a
# distinct, never-signed vnode and reliably hits the AMFI check — this is what
# broke the ${CONDA_TRIPLET}-zig-{cc,cxx,...} suffix copies in zig_build.sh's
# wrapper-install loop even though the un-copied primary wrapper's own
# --version validation passed. Ad-hoc signing on osx-64 is a harmless
# no-op-equivalent, so this guards on is_osx alone rather than also checking
# machine arch. Hard-fails on error: an unsigned wrapper cannot execute on
# osx-arm64, so a silent/soft failure here would only resurface later as a
# confusing Exec format error at test or activation time.
_codesign_adhoc() {
  is_osx || return 0
  local _path="$1"
  if ! codesign --force --sign - "${_path}"; then
    echo "ERROR: codesign ad-hoc signing failed for ${_path}" >&2
    exit 1
  fi
}

# _disk_probe <label>: disk/space diagnostic for the zig build-phase investigation
# (osx 95%-full; apparent stall at "Configuring zig version"). Prints a greppable
# timestamped marker, df for SRC_DIR+PREFIX, and du of the big trees kept during
# the zig link. Gated on ZIG_DISK_PROBE (DEFAULT ON) so it shows in CI now but can
# be silenced with ZIG_DISK_PROBE=0; remove once the disk issue is resolved.
_disk_probe() {
  [[ "${ZIG_DISK_PROBE:-1}" == "1" ]] || return 0
  echo "=== DISK_PROBE [${1:-}] $(date -u '+%FT%TZ') ==="
  df -h "${SRC_DIR}" "${PREFIX}" 2>/dev/null || df -h || true
  local _d
  for _d in "${PREFIX}/lib/zig-llvm" "${SRC_DIR}/conda-zig-source" \
            "${SRC_DIR}/zig-global-cache" "${SRC_DIR}/zig-local-cache" \
            "${SRC_DIR}/build-release" "${SRC_DIR}/native-libcxx-install"; do
    [[ -d "${_d}" ]] && du -sh "${_d}" 2>/dev/null || true
  done
  echo "=== DISK_PROBE [${1:-}] end ==="
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
