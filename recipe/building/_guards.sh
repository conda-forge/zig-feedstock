# Early-exit guards for the zig_impl build.
# Verifies CONDA_TRIPLET, CONDA_ZIG_BUILD, ZIG_TRIPLET, PKG_NAME are set, derives
# ZIG_QEMU_ARCH, and (ZIG_USE_CACHE=1) may `exit 0` the whole build on a cache hit.
# Requires: CONDA_TRIPLET, CONDA_ZIG_BUILD, ZIG_TRIPLET, PKG_NAME, RECIPE_DIR.

# --- Early exits ---

if [[ -z "${CONDA_TRIPLET:-}" ]]; then
  echo "CONDA_TRIPLET must be specified in recipe.yaml env"
  exit 1
fi
if [[ -z "${CONDA_ZIG_BUILD:-}" ]]; then
  echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"
  exit 1
fi
if [[ -z "${ZIG_TRIPLET:-}" ]]; then
  echo "ZIG_TRIPLET must be specified in recipe.yaml env"
  exit 1
fi

export ZIG_QEMU_ARCH="${ZIG_TRIPLET%%-*}"

if [[ "${PKG_NAME:-}" != "zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: >${PKG_NAME:-}< - Verify recipe.yaml script:"
  exit 1
fi

# === Build caching for quick recipe iteration ===
# Set ZIG_USE_CACHE=1 to enable build caching:
#   - First run: builds normally, caches result
#   - Subsequent runs: restores from cache, skips build
if [[ "${ZIG_USE_CACHE:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  if stub_cache_restore; then
    echo "=== Build restored from cache (skipping compilation) ==="
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi
