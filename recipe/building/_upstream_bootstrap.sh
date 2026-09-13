# Upstream zig bootstrap setup
#
# When recipe.yaml's `source:` includes one of the upstream
# ziglang.org tarballs (gated on build_number == 0), the payload may land
# nested in a zig-*/ subdir or flat in zig-bootstrap/ (both handled). This
# helper locates the extracted binary, makes it accessible under the
# CONDA_ZIG_BUILD name, and prepends its dir to PATH so the rest of
# the build picks it up instead of the conda-forge zig_impl bootstrap.
#
# The upstream binary needs its adjacent lib/ dir to work, so we
# rename/hardlink IN PLACE inside the bootstrap dir (rather than
# symlinking into a separate dir) — keeps lib/ adjacent.  On Windows,
# MSYS `ln -s` writes a cygwin-marker file that native programs don't
# follow, so we use a hardlink (or copy as fallback).
#
# Called only on first builds (build_number == 0) of a new zig
# release.  Subsequent builds use conda-forge's published
# `zig_impl_${build_platform}` package, which can parse the
# matching build.zig directly.
function setup_upstream_zig_bootstrap() {
  if [[ ! -d "${SRC_DIR}/zig-bootstrap" ]]; then
    return 0
  fi

  local _bootstrap_root="" _cand
  for _cand in "${SRC_DIR}/zig-bootstrap"/zig-*/; do
    if [[ -d "${_cand}" ]]; then
      _bootstrap_root="${_cand%/}"
      break
    fi
  done
  # rattler-build may strip the archive's single top-level dir, leaving the
  # payload flat in zig-bootstrap/. Accept both layouts (cf. build_native.sh:87).
  if [[ -z "${_bootstrap_root}" ]]; then
    _bootstrap_root="${SRC_DIR}/zig-bootstrap"
  fi

  local _bootstrap_zig _bootstrap_aliased
  if is_not_unix; then
    _bootstrap_zig="${_bootstrap_root}/zig.exe"
    _bootstrap_aliased="${_bootstrap_root}/${CONDA_ZIG_BUILD}.exe"
    export ZIG_BOOTSTRAP_EXE="${_bootstrap_aliased}"
  else
    : # brush 0.4.0 $? guard
    _bootstrap_zig="${_bootstrap_root}/zig"
    _bootstrap_aliased="${_bootstrap_root}/${CONDA_ZIG_BUILD}"
    export ZIG_BOOTSTRAP_EXE="${_bootstrap_aliased}"
  fi

  if [[ ! -x "${_bootstrap_zig}" ]]; then
    echo "ERROR: [_upstream_bootstrap] zig-bootstrap/ exists but no executable bootstrap zig at ${_bootstrap_zig}" >&2
    ls -la "${SRC_DIR}/zig-bootstrap" "${_bootstrap_root}" >&2 2>&1 || true
    return 0
  fi

  ln -f "${_bootstrap_zig}" "${_bootstrap_aliased}" 2>/dev/null \
    || cp -f "${_bootstrap_zig}" "${_bootstrap_aliased}"
  export PATH="${_bootstrap_root}:${PATH}"
  echo "=== Using upstream zig bootstrap: ${_bootstrap_aliased} ==="
}
