#!/usr/bin/env bash
# windres wrapper: translates -o <out> / -o<out> to zig rc's -fo equivalent.
set -e
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o)   _args+=("-fo" "$2"); shift 2;;
        -o*)  _args+=("-fo${1#-o}"); shift;;
        *)    _args+=("$1"); shift;;
    esac
done
exec "@ZIG_BIN@" rc "${_args[@]}"
