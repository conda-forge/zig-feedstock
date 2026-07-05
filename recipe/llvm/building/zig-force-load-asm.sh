#!/usr/bin/env bash
_ZIG_MODE="cc"
_zig_wrapper_invoked="${BASH_SOURCE[0]}"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/_zig-force-load-common.sh"
