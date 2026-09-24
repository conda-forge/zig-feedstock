# Phase 2: builds langref via a stage3 zig, when the host can run one (_can_run_stage3).
# Includes the timeout / crash-pattern-grep / _qemu_shadow_dir cleanup around the
# real `zig build langref`.
# Requires: PREFIX, ZIG_TRIPLET, ZIG_QEMU_ARCH, PKG_VERSION, cmake_source_dir,
#   SRC_DIR, _qemu_shadow_dir (from _configure_args.sh, if armed).

# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if ! is_unix; then return 1; fi
  if is_linux; then
    if command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null; then return 0; fi
  fi
  # Rosetta 2 runs an x86_64 stage3 on the arm64 macOS runners; not symmetric.
  if is_rosetta; then return 0; fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (env override, or lane cannot run stage3)" >&2
elif _can_run_stage3; then
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # PATH already carries the qemu-<llvm-arch> shadow set up before -fqemu was
  # decided; _stage3_runner below resolves through it.

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
    "${_phase2_timeout[@]+"${_phase2_timeout[@]}"}" \
      "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      -Ddoctest-target="${ZIG_TRIPLET}"
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
