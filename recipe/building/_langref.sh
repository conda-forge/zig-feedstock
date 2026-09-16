# Phase 2: builds langref via a stage3 zig, when the host can run one (_can_run_stage3).
# Includes the optional ZIG_LANGREF_PROBE per-example timing probe and the timeout /
# crash-pattern-grep / _qemu_shadow_dir cleanup around the real `zig build langref`.
# Requires: PREFIX, ZIG_TRIPLET, ZIG_QEMU_ARCH, PKG_VERSION, cmake_source_dir,
#   SRC_DIR, _qemu_shadow_dir (from _configure_args.sh, if armed).

# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if ! is_unix; then return 1; fi
  if is_linux; then
    command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null && return 0
  fi
  # Rosetta 2 runs an x86_64 stage3 on the arm64 macOS runners; not symmetric.
  is_rosetta && return 0
  return 1
}

# --- Critical langref subset (for lanes where the full langref build is skipped) ---
# Runs building/langref_critical.txt through doctest directly. Report-only unless
# ZIG_LANGREF_CRITICAL_FATAL=1. Pass criterion is a NON-EMPTY output file: doctest
# exits without writing when an example aborts.
if [[ "${ZIG_LANGREF_CRITICAL:-0}" == "1" ]] && _can_run_stage3; then
  _crit_list="${RECIPE_DIR}/building/langref_critical.txt"
  if [[ ! -f "${_crit_list}" ]]; then
    echo "ERROR: ZIG_LANGREF_CRITICAL=1 but ${_crit_list} is missing" >&2
    exit 1
  fi

  _crit_runner=()
  if is_cross && is_linux; then
    _crit_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  _crit_dir="${SRC_DIR:-/tmp}/langref-critical"
  rm -rf "${_crit_dir}"
  mkdir -p "${_crit_dir}"

  if ( cd "${cmake_source_dir}" &&
       "${_crit_runner[@]+"${_crit_runner[@]}"}" "${PREFIX}/bin/zig" \
         build-exe tools/doctest.zig -femit-bin="${_crit_dir}/doctest" ); then
    _crit_pass=0
    _crit_fail=0
    _crit_missing=0
    _crit_failed_names=()
    while IFS= read -r _crit_name || [[ -n "${_crit_name}" ]]; do
      case "${_crit_name}" in ''|'#'*) continue ;; esac
      if [[ ! -f "${cmake_source_dir}/doc/langref/${_crit_name}.zig" ]]; then
        echo "WARNING: langref-critical: no such example: ${_crit_name}" >&2
        _crit_missing=$((_crit_missing + 1))
        continue
      fi
      if ( cd "${cmake_source_dir}" &&
           timeout --kill-after=30s "${ZIG_LANGREF_CRITICAL_STEP_TIMEOUT:-300}" \
             "${_crit_runner[@]+"${_crit_runner[@]}"}" "${_crit_dir}/doctest" \
               --zig "${PREFIX}/bin/zig" \
               --cache-root "${ZIG_LOCAL_CACHE_DIR}" \
               --zig-lib-dir "${PREFIX}/lib/zig/" \
               --default-target "${ZIG_TRIPLET}" \
               -i "doc/langref/${_crit_name}.zig" \
               -o "${_crit_dir}/out" ) >"${_crit_dir}/last.log" 2>&1 &&
         [[ -s "${_crit_dir}/out" ]]; then
        echo "PASS langref-critical ${_crit_name}"
        _crit_pass=$((_crit_pass + 1))
      else
        echo "FAIL langref-critical ${_crit_name}" >&2
        tail -n 15 "${_crit_dir}/last.log" >&2
        _crit_fail=$((_crit_fail + 1))
        _crit_failed_names+=("${_crit_name}")
      fi
      rm -f "${_crit_dir}/out"
    done < "${_crit_list}"

    echo "INFO: langref-critical: ${_crit_pass} pass, ${_crit_fail} fail, ${_crit_missing} missing" >&2

    if [[ ${_crit_missing} -gt 0 ]]; then
      echo "ERROR: langref-critical list names ${_crit_missing} example(s) absent from the source tree" >&2
      exit 1
    fi

    if [[ ${_crit_fail} -gt 0 ]]; then
      printf 'INFO: langref-critical failures: %s\n' "${_crit_failed_names[*]}" >&2
      if [[ "${ZIG_LANGREF_CRITICAL_FATAL:-0}" == "1" ]]; then
        echo "ERROR: langref-critical failures are fatal (ZIG_LANGREF_CRITICAL_FATAL=1)" >&2
        exit 1
      fi
    fi
  else
    echo "ERROR: langref-critical: doctest build failed" >&2
    exit 1
  fi
fi

# --- Optional: langref per-example cost probe (measurement only, no artifact) ---
# ZIG_LANGREF_PROBE=<N|all> times N doctest examples to size a future subset.
# Runs before phase 2 so the qemu shadow PATH is still in place. Writes only
# under SRC_DIR, never into ${PREFIX}.
if [[ -n "${ZIG_LANGREF_PROBE:-}" ]] && _can_run_stage3; then
  _probe_runner=()
  if is_cross && is_linux; then
    _probe_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  _probe_dir="${SRC_DIR:-/tmp}/langref-probe"
  rm -rf "${_probe_dir}"
  mkdir -p "${_probe_dir}/cache"
  _probe_tsv="${_probe_dir}/timings.tsv"
  _probe_budget="${ZIG_LANGREF_PROBE_BUDGET:-2400}"
  _probe_step="${ZIG_LANGREF_PROBE_STEP_TIMEOUT:-600}"

  _probe_kind() {
    grep -oE '^//[[:space:]]*(test_safety|test_error|test|exe|syntax|obj|lib)' "$1" \
      | tail -n 1 | tr -d '[:space:]' | sed 's|^//||'
  }

  if ( cd "${cmake_source_dir}" &&
       "${_probe_runner[@]+"${_probe_runner[@]}"}" "${PREFIX}/bin/zig" \
         build-exe tools/doctest.zig -femit-bin="${_probe_dir}/doctest" ); then
    # Round-robin by kind so a truncated probe still spans every kind.
    ( cd "${cmake_source_dir}" &&
      for _f in doc/langref/*.zig; do
        printf '%s\t%s\n' "$(_probe_kind "${_f}")" "${_f}"
      done ) | sort -k1,1 -k2,2 \
        | awk -F'\t' '{ n[$1]++; printf "%04d\t%s\t%s\n", n[$1], $1, $2 }' \
        | sort -k1,1n -k2,2 | cut -f2,3 > "${_probe_dir}/order.txt"

    printf 'kind\texample\tseconds\trc\n' | tee "${_probe_tsv}"
    _probe_i=0
    _probe_t0=$(date +%s)
    while IFS=$'\t' read -r _k _f; do
      _probe_i=$((_probe_i + 1))
      if [[ "${ZIG_LANGREF_PROBE}" != "all" ]] && [[ ${_probe_i} -gt ${ZIG_LANGREF_PROBE} ]]; then
        break
      fi
      if [[ $(( $(date +%s) - _probe_t0 )) -ge ${_probe_budget} ]]; then
        echo "INFO: langref probe budget ${_probe_budget}s reached after $((_probe_i - 1)) examples" >&2
        break
      fi
      _e0=$(date +%s)
      if ( cd "${cmake_source_dir}" &&
           timeout --kill-after=30s "${_probe_step}" \
             "${_probe_runner[@]+"${_probe_runner[@]}"}" "${_probe_dir}/doctest" \
               --zig "${PREFIX}/bin/zig" \
               --cache-root "${_probe_dir}/cache" \
               --zig-lib-dir "${PREFIX}/lib/zig" \
               --default-target "${ZIG_TRIPLET}" \
               -i "${_f}" \
               -o "${_probe_dir}/out.html" ) >"${_probe_dir}/last.log" 2>&1; then
        _rc=0
      else
        _rc=$?
      fi
      printf '%s\t%s\t%s\t%s\n' "${_k}" "${_f}" "$(( $(date +%s) - _e0 ))" "${_rc}" \
        | tee -a "${_probe_tsv}"
      if [[ ${_rc} -ne 0 ]]; then
        tail -n 15 "${_probe_dir}/last.log" >&2
      fi
    done < "${_probe_dir}/order.txt"

    echo "INFO: langref probe per-kind totals (kind count total_s mean_s):" >&2
    awk -F'\t' 'NR>1 { c[$1]++; s[$1]+=$3 } END { for (k in c) printf "  %-12s %4d %6d %7.1f\n", k, c[k], s[k], s[k]/c[k] }' \
      "${_probe_tsv}" >&2
  else
    echo "WARNING: langref probe: doctest build failed; skipping probe" >&2
  fi
fi

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (env override, or lane cannot run stage3)" >&2
elif _can_run_stage3; then
  zig_diag_note "PHASE 2: building langref via stage3 zig"
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # PATH already carries the qemu-<llvm-arch> shadow set up before -fqemu was
  # decided; _stage3_runner below resolves through it.

  _phase2_diag_flags=()
  zig_diag_on && _phase2_diag_flags=(--verbose --summary all)

  # Bound langref so a hung lane ends instead of hitting the CI job ceiling.
  _phase2_timeout=()
  _phase2_timed_out=0
  if [[ "${ZIG_LANGREF_TIMEOUT:-5h}" != "0" ]] && command -v timeout &>/dev/null; then
    _phase2_timeout=(timeout --kill-after=60s "${ZIG_LANGREF_TIMEOUT:-5h}")
  fi

  # Crash-probe capture: kept out of ${PREFIX} so it never enters the package.
  _phase2_log="${SRC_DIR:-/tmp}/zig-phase2-langref.log"

  _phase2_pipefail_state="$(shopt -po pipefail)"
  set -o pipefail
  if (
    cd "${cmake_source_dir}" &&
    zig_diag_exec "phase2-langref" -- \
      "${_phase2_timeout[@]+"${_phase2_timeout[@]}"}" \
      "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      -Ddoctest-target="${ZIG_TRIPLET}" \
      ${_phase2_diag_flags[@]+"${_phase2_diag_flags[@]}"}
  ) 2>&1 | tee "${_phase2_log}"; then
    _phase2_rc=0
  else
    _phase2_rc=${PIPESTATUS[0]}
  fi
  eval "${_phase2_pipefail_state}"

  if [[ ${_phase2_rc} -ne 0 ]]; then
    if [[ ${_phase2_rc} -eq 124 || ${_phase2_rc} -eq 137 ]]; then
      # Non-fatal: an emulated lane can legitimately exceed the bound. The
      # install happens at the END of the phase, so a timeout usually means
      # NO artifact; the check after this block then fails the build.
      echo "WARNING: Phase 2 langref TIMED OUT after ${ZIG_LANGREF_TIMEOUT:-5h} (rc=${_phase2_rc}); continuing" >&2
      zig_diag_note "phase2-langref TIMED OUT rc=${_phase2_rc} -- continuing (non-fatal)"
      _phase2_timed_out=1
    else
      echo "ERROR: Phase 2 langref build failed (rc=${_phase2_rc})" >&2
      exit 1
    fi
  fi

  if [ -n "${_qemu_shadow_dir:-}" ]; then
    rm -rf "${_qemu_shadow_dir}"
    unset _qemu_shadow_dir
  fi

  # panic/error: excluded on purpose -- doctests intentionally panic
  # (e.g. runtime_division_by_zero.zig, runtime_unwrap_null.zig).
  _phase2_crash_pattern='uncaught target signal|Illegal instruction|Bus error|core dumped|Segmentation fault|SIGSEGV|SIGILL|SIGBUS|Unable to dump stack trace|qemu: fatal'
  if [[ -f "${_phase2_log}" ]] && grep -qE "${_phase2_crash_pattern}" "${_phase2_log}"; then
    echo "ERROR: Phase 2 langref log shows a hard-fault signature" >&2
    grep -nE "${_phase2_crash_pattern}" "${_phase2_log}" | head -n 20 >&2
    exit 1
  fi

  # Phase 2 only runs on lanes that package langref.html, so a missing artifact is fatal.
  if [[ ${_phase2_timed_out} -eq 1 ]] && [[ ! -f "${PREFIX}/doc/langref.html" ]]; then
    echo "ERROR: Phase 2 langref timed out BEFORE doc/langref.html was installed" >&2
    exit 1
  fi
else
  echo "INFO: Phase 2 langref skipped: stage3 not runnable on this host (cross without qemu/wine)" >&2
fi
