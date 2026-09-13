# Guard: coreutils userland must be present (m2-coreutils has no win-arm64 build)
_missing_tools=""
for _tool in mkdir cp mv rm cat basename tail; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    _missing_tools="${_missing_tools} ${_tool}"
  fi
done

if [[ -n "${_missing_tools}" ]]; then
  echo "ERROR: missing required coreutils binaries:${_missing_tools}"
  echo "target_platform=${target_platform:-?} build_platform=${build_platform:-?}"
  echo "These are normally provided by m2-coreutils, which has no win-arm64 conda-forge build"
  exit 1
fi
unset _missing_tools _tool
