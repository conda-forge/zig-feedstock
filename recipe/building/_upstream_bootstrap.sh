# Upstream zig bootstrap setup
#
# When recipe.yaml's `source:` includes one of the upstream
# ziglang.org tarballs (gated on build_number == 0), it extracts to
# ${SRC_DIR}/zig-bootstrap/zig-${arch}-${os}-${ver}/.  This helper
# locates the extracted binary, makes it accessible under the
# CONDA_ZIG_BUILD name, and prepends its dir to PATH so the rest of
# the build picks it up instead of the conda-forge zig_impl bootstrap.
#
# The upstream binary needs its adjacent lib/ dir to work, so we
# rename/hardlink IN PLACE inside the bootstrap dir (rather than
# symlinking into a separate dir) -- keeps lib/ adjacent.  On Windows,
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

  local _bootstrap_root
  _bootstrap_root="$(find "${SRC_DIR}/zig-bootstrap" -maxdepth 1 -type d -name 'zig-*' -print -quit)"
  if [[ -z "${_bootstrap_root}" ]]; then
    return 0
  fi

  local _bootstrap_zig _bootstrap_aliased
  if is_not_unix; then
    _bootstrap_zig="${_bootstrap_root}/zig.exe"
    _bootstrap_aliased="${_bootstrap_root}/${CONDA_ZIG_BUILD}.exe"
  else
    _bootstrap_zig="${_bootstrap_root}/zig"
    _bootstrap_aliased="${_bootstrap_root}/${CONDA_ZIG_BUILD}"
  fi

  if [[ ! -x "${_bootstrap_zig}" ]]; then
    return 0
  fi

  ln -f "${_bootstrap_zig}" "${_bootstrap_aliased}" 2>/dev/null \
    || cp -f "${_bootstrap_zig}" "${_bootstrap_aliased}"
  export PATH="${_bootstrap_root}:${PATH}"
  echo "=== Using upstream zig bootstrap: ${_bootstrap_aliased} ==="
}
