# Guard: Require bash 5.2+ for associative arrays and other features
# Not bash at all (e.g. brush) -> BASH_VERSINFO is unset, skip silently.
if [[ -n "${BASH_VERSINFO[0]:-}" ]] && { [[ ${BASH_VERSINFO[0]:-0} -lt 5 ]] || { [[ ${BASH_VERSINFO[0]:-0} -eq 5 ]] && [[ ${BASH_VERSINFO[1]:-0} -lt 2 ]]; }; }; then
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi
