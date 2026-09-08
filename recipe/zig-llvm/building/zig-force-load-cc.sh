#!/usr/bin/env bash
# Build-time force-load shim (cc mode) for zig-llvm.
# Sources the canonical shipped script (recipe/scripts/_zig-force-load-common.sh)
# with opt-in env gates so the shipped activation-time script itself stays
# byte-identical. See that file's header for what each ZIG_FL_* var does.
_ZIG_MODE="cc"
export ZIG_FL_SKIP_COMMON=1
export ZIG_FL_DEDUP=1
export ZIG_FL_TARGET="${ZIG_TARGET_HOST}"
export ZIG_FL_EXEC="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/../../scripts/_zig-force-load-common.sh" "$@"
