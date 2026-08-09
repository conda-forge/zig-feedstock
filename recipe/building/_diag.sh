# _diag.sh — shared diagnostic-accumulator framework.
# Source this file and call diag_phase/diag_fail/diag_ok/diag_run/... .
# Purpose: a single CI run (2-6h) should report EVERY problem it hit, not just
# the first one, and must never silently swallow a real failure as a WARN.
# Idempotency-guarded; safe to source multiple times.

[[ -n "${_ZIG_DIAG_SH_SOURCED:-}" ]] && return 0
_ZIG_DIAG_SH_SOURCED=1

# _DIAG_FAILURES holds "phase|label|detail" records, one per diag_fail call.
_DIAG_FAILURES=()
_DIAG_PHASE="unknown"

# diag_phase <name>
# Sets the current phase and prints a navigable, timestamped banner.
diag_phase() {
  _DIAG_PHASE="$1"
  echo "=== PHASE: ${_DIAG_PHASE} === ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
}

# diag_fail <label> <detail...>
# Records a failure tagged with the current phase. DOES NOT EXIT.
diag_fail() {
  local _label="$1"; shift
  local _detail="$*"
  _DIAG_FAILURES+=("${_DIAG_PHASE}|${_label}|${_detail}")
  echo "  [FAIL] ${_label}: ${_detail}" >&2
}

# diag_ok <label>
diag_ok() {
  local _label="$1"
  echo "  [ OK ] ${_label}"
}

# diag_run <label> -- <command...>
# Runs a command, capturing its real exit code. Gates purely on that exit
# status -- NEVER on whether an output file exists (a compiler creates its -o
# target before failing codegen; inferring success from file existence
# produced a false "PASS" in the osx probe, do not reintroduce that bug).
# Returns the command's real exit code; never exits the shell itself.
diag_run() {
  local _label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local _log _rc=0
  _log="$(mktemp "${TMPDIR:-/tmp}/zig-diag-run.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/zig-diag-run.$$")"
  "$@" >"${_log}" 2>&1 || _rc=$?
  if [[ ${_rc} -eq 0 ]]; then
    diag_ok "${_label}"
  else
    diag_fail "${_label}" "exit ${_rc}; last 20 lines: $(tail -20 "${_log}")"
  fi
  rm -f "${_log}"
  return "${_rc}"
}

# diag_require_file <label> <path...>
# Each path may be a glob pattern. Missing (no match) -> diag_fail per path.
diag_require_file() {
  local _label="$1"; shift
  local _path _matches
  for _path in "$@"; do
    _matches="$(compgen -G "${_path}" 2>/dev/null || true)"
    if [[ -z "${_matches}" ]]; then
      diag_fail "${_label}" "missing: ${_path}"
    else
      diag_ok "${_label}: ${_path}"
    fi
  done
}

# diag_evidence <label> [dir...]
# Bounded forensic packet: ls -la of each dir, disk free, and any
# CMakeCache.txt under $SRC_DIR/$PREFIX (-maxdepth 6) grepped for the
# LLVM cmake flags that most often explain a bad LLVM build. Every output
# is bounded (head -50) so it cannot flood a 6h log.
diag_evidence() {
  local _label="$1"; shift
  echo "  [EVID] ${_label}"
  local _d
  for _d in "$@"; do
    echo "    ls -la ${_d}:"
    ls -la "${_d}" 2>&1 | head -50 | sed 's/^/      /' || true
  done
  echo "    disk free:"
  df -h 2>&1 | head -50 | sed 's/^/      /' || true
  echo "    CMakeCache.txt matches (LLVM_NO_DEAD_STRIP|LLVM_TARGETS_TO_BUILD|LLVM_BUILD_LLVM_DYLIB|LLVM_LINK_LLVM_DYLIB):"
  local _cc
  while IFS= read -r _cc; do
    echo "      ${_cc}:"
    grep -E 'LLVM_NO_DEAD_STRIP|LLVM_TARGETS_TO_BUILD|LLVM_BUILD_LLVM_DYLIB|LLVM_LINK_LLVM_DYLIB' \
      "${_cc}" 2>/dev/null | head -50 | sed 's/^/        /' || true
  done < <(find "${SRC_DIR:-}" "${PREFIX:-}" -maxdepth 6 -name CMakeCache.txt 2>/dev/null | head -50 || true)
}

# diag_report
# Prints the consolidated summary. Returns 1 if there were failures, else 0.
diag_report() {
  local _n=${#_DIAG_FAILURES[@]}
  if [[ ${_n} -eq 0 ]]; then
    echo "=== DIAGNOSTIC SUMMARY: clean ==="
    return 0
  fi
  echo "=== DIAGNOSTIC SUMMARY: ${_n} failure(s) ==="
  local _i=1 _entry _phase _label _detail
  for _entry in "${_DIAG_FAILURES[@]}"; do
    IFS='|' read -r _phase _label _detail <<< "${_entry}"
    echo "  ${_i}. ${_phase} : ${_label} : ${_detail}"
    _i=$((_i + 1))
  done
  return 1
}

# diag_report_and_exit
# Calls diag_report; exits 1 if there were failures, else returns 0.
diag_report_and_exit() {
  if diag_report; then
    return 0
  else
    exit 1
  fi
}

# diag_install_trap
# Opt-in ERR/EXIT trap: on an unexpected non-zero exit, dumps the summary
# accumulated so far before the shell dies, so an abort still yields a report.
_diag_trap_handler() {
  local _rc="$?"
  if [[ "${_rc}" -ne 0 ]]; then
    echo "=== DIAG TRAP: unexpected exit (code ${_rc}) -- dumping accumulated diagnostics ===" >&2
    diag_report >&2 || true
  fi
}

diag_install_trap() {
  trap '_diag_trap_handler' ERR EXIT
}
