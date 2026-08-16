#!/usr/bin/env bash
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/@WRAPPER_PREFIX@_zig-cache-common.sh"
exec "@ZIG_BIN@" ranlib "$@"
