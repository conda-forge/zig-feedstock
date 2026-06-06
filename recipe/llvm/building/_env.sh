build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { [[ "${target_platform}" != "linux-"* && "${target_platform}" != "osx-"* ]]; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

# Debug output: ZIG_LLVM_DEBUG=1 in recipe.yaml env
_debug() { [[ "${ZIG_LLVM_DEBUG:-0}" == "1" ]]; }
dbg() { _debug && echo "  [DBG] $*" || true; }

echo "=== Building zig-llvmdev with zig cc ==="
echo "  LLVM source: ${SRC_DIR}/llvm-source/llvm"
echo "  Target: ${target_platform}"

LLVM_SRC="${SRC_DIR}/llvm-source/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
# Windows: conda convention is $PREFIX/Library/ for non-Python artifacts
if [[ "${target_platform}" == win-* ]]; then
  LLVM_INSTALL="${PREFIX}/Library/lib/zig-llvm"
else
  LLVM_INSTALL="${PREFIX}/lib/zig-llvm"
fi

