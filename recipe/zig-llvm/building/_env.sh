build_platform="${build_platform:-${target_platform}}"

# Shared platform predicates (is_linux/is_osx/is_unix/is_not_unix/is_cross):
# sourced from recipe/building/_common.sh instead of redefining them here.
# Idempotency-guarded there, safe even if already sourced by a caller.
source "${RECIPE_DIR}/building/_common.sh"

# Debug output: ZIG_LLVM_DEBUG=1 in recipe.yaml env. Defined AFTER the
# _common.sh source above so this dbg()/_debug() pair (message-string call
# convention, ZIG_LLVM_DEBUG-gated) wins over _common.sh's own dbg()
# (command-execution call convention, DEBUG_ZIG_BUILD-gated) for the rest of
# this shell session — the two are NOT interchangeable, and zig-llvm/ code
# uses this message-string one.
# Note: ZIG_LLVM_DEBUG is an incubator dev-only debug knob, not wired into
# recipe.yaml (unlike ZIG_DEBUG_SDK) — set it manually in a local shell.
_debug() { [[ "${ZIG_LLVM_DEBUG:-0}" == "1" ]]; }
dbg() { _debug && echo "  [DBG] $*" || true; }

# Derive the zig-style target triple from an LLVM triple (drop -unknown-/-w64- infixes).
zig_triplet_from_llvm() {
  local _t="${1/-unknown-/-}"
  printf '%s' "${_t/-w64-/-}"
}


# The llvm-project tarball extracts under llvm-source per recipe.yaml
# target_directory, not directly under SRC_DIR.
LLVM_SOURCE_ROOT="${SRC_DIR}/llvm-source"
LLVM_SRC="${LLVM_SOURCE_ROOT}/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
# Windows: conda convention is $PREFIX/Library/ for non-Python artifacts
if [[ "${target_platform}" == win-* ]]; then
  LLVM_INSTALL="${PREFIX}/Library/lib/zig-llvm"
else
  LLVM_INSTALL="${PREFIX}/lib/zig-llvm"
fi

