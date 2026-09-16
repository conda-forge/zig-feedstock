# _langref.sh -- critical langref doctest subset, for lanes where the full
# `zig build langref` is skipped. Sourced by build.sh; call run_langref_critical.
# Requires _common.sh predicates plus PREFIX, ZIG_TRIPLET, ZIG_LOCAL_CACHE_DIR,
# cmake_source_dir, SRC_DIR, RECIPE_DIR, and QEMU_EXECVE on cross linux.

if [[ -n "${_ZIG_LANGREF_SH_SOURCED:-}" ]]; then
  return 0
fi
_ZIG_LANGREF_SH_SOURCED=1

# Native: yes. Cross linux: only through the qemu shim. Cross non-unix: no
# (no wine). Rosetta runs an x86_64 stage3 on the arm64 macOS runners.
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if ! is_unix; then return 1; fi
  if is_linux; then
    [[ -n "${QEMU_EXECVE:-}" && -x "${QEMU_EXECVE}" ]] && return 0
  fi
  is_rosetta && return 0
  return 1
}

# Runs langref_critical.txt through tools/doctest.zig directly: upstream has no
# per-example selector, and the full langref is hours under qemu. Pass criterion
# is a NON-EMPTY -o file -- doctest exits without writing when an example
# aborts, so exit status alone is not enough.
# Bounded twice: per example by ZIG_LANGREF_CRITICAL_STEP_TIMEOUT, and in total
# by ZIG_LANGREF_CRITICAL_BUDGET, so a misbehaving doctest cannot reach the CI
# job ceiling.
#
# Everything here is report-only unless ZIG_LANGREF_CRITICAL_FATAL=1. This is
# additive diagnostic coverage on lanes that currently have none; it must not
# be able to fail a build that would otherwise pass. Tighten to fatal once a
# board has shown 0 missing and a stable pass set on this zig snapshot.
run_langref_critical() {
  [[ "${ZIG_LANGREF_CRITICAL:-0}" == "1" ]] || return 0
  if ! _can_run_stage3; then
    echo "INFO: [langref-critical] skipped: this lane cannot run a stage3 zig" >&2
    return 0
  fi

  local _fatal="${ZIG_LANGREF_CRITICAL_FATAL:-0}"
  local _list="${RECIPE_DIR}/building/langref_critical.txt"
  if [[ ! -f "${_list}" ]]; then
    echo "WARNING: [langref-critical] ZIG_LANGREF_CRITICAL=1 but ${_list} is missing" >&2
    [[ "${_fatal}" == "1" ]] && return 1
    return 0
  fi

  local _runner
  _runner=()
  if is_cross && is_linux; then
    _runner=("${QEMU_EXECVE}")
  fi

  local _dir="${SRC_DIR:-/tmp}/langref-critical"
  rm -rf "${_dir}"
  mkdir -p "${_dir}"

  zig_diag_span "BEGIN langref-critical"
  local _start=${SECONDS}
  local _budget="${ZIG_LANGREF_CRITICAL_BUDGET:-3600}"

  if ! ( cd "${cmake_source_dir}" &&
         env QEMU_EXECVE_NATIVE_PASSTHROUGH=1 \
           "${_runner[@]+"${_runner[@]}"}" "${PREFIX}/bin/zig" \
           build-exe tools/doctest.zig -femit-bin="${_dir}/doctest" ); then
    echo "WARNING: [langref-critical] doctest build failed; no subset coverage this lane" >&2
    zig_diag_span "END langref-critical: doctest build failed"
    [[ "${_fatal}" == "1" ]] && return 1
    return 0
  fi

  local _pass=0
  local _fail=0
  local _missing=0
  local _failed_names
  local _missing_names
  _failed_names=()
  _missing_names=()
  local _name
  while IFS= read -r _name || [[ -n "${_name}" ]]; do
    case "${_name}" in ''|'#'*) continue ;; esac
    if [[ $((SECONDS - _start)) -ge ${_budget} ]]; then
      echo "WARNING: [langref-critical] budget ${_budget}s exhausted; stopping early" >&2
      break
    fi
    if [[ ! -f "${cmake_source_dir}/doc/langref/${_name}.zig" ]]; then
      _missing=$((_missing + 1))
      _missing_names+=("${_name}")
      continue
    fi
    if ( cd "${cmake_source_dir}" &&
         timeout --kill-after=30s "${ZIG_LANGREF_CRITICAL_STEP_TIMEOUT:-300}" \
           env QEMU_EXECVE_NATIVE_PASSTHROUGH=1 \
             "${_runner[@]+"${_runner[@]}"}" "${_dir}/doctest" \
               --zig "${PREFIX}/bin/zig" \
               --cache-root "${ZIG_LOCAL_CACHE_DIR}" \
               --zig-lib-dir "${PREFIX}/lib/zig/" \
               --default-target "${ZIG_TRIPLET}" \
               -i "doc/langref/${_name}.zig" \
               -o "${_dir}/out" ) >"${_dir}/last.log" 2>&1 &&
       [[ -s "${_dir}/out" ]]; then
      echo "PASS langref-critical ${_name}"
      _pass=$((_pass + 1))
    else
      echo "FAIL langref-critical ${_name}" >&2
      tail -n 15 "${_dir}/last.log" >&2
      _fail=$((_fail + 1))
      _failed_names+=("${_name}")
    fi
    rm -f "${_dir}/out"
  done < "${_list}"

  echo "INFO: [langref-critical] ${_pass} pass, ${_fail} fail, ${_missing} missing, $((_pass + _fail + _missing)) attempted" >&2
  zig_diag_span "END langref-critical: elapsed=$((SECONDS - _start))s"

  if [[ ${_missing} -gt 0 ]]; then
    printf 'WARNING: [langref-critical] absent from doc/langref: %s\n' "${_missing_names[*]}" >&2
  fi
  if [[ ${_fail} -gt 0 ]]; then
    printf 'INFO: [langref-critical] failures: %s\n' "${_failed_names[*]}" >&2
  fi

  if [[ "${_fatal}" == "1" ]] && [[ $((_fail + _missing)) -gt 0 ]]; then
    echo "ERROR: [langref-critical] failures are fatal (ZIG_LANGREF_CRITICAL_FATAL=1)" >&2
    return 1
  fi
  return 0
}
