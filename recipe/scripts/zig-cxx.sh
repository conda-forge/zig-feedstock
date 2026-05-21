#!/usr/bin/env bash
# Wrapper: zig c++ -target @ZIG_TARGET@
_ZIG_MODE="c++"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/@WRAPPER_PREFIX@_zig-cc-common.sh"
exec "@ZIG_BIN@" "${_exec_args[@]}"
