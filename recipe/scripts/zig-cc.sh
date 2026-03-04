#!/usr/bin/env bash
# Wrapper: zig cc -target @ZIG_TARGET@
_ZIG_MODE="cc"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/_zig-cc-common.sh"
exec "@ZIG_BIN@" "${_exec_args[@]}"
