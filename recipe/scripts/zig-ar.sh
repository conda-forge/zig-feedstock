#!/usr/bin/env bash
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/@WRAPPER_PREFIX@_zig-cache-common.sh"
# Strip 'T' (thin archive) modifier — zig's linker frontend can't parse thin archives,
# even though zig ar (llvm-ar) can create them. Meson unconditionally passes csrDT on Linux.
_args=()
for _a in "$@"; do
    if [[ ${#_args[@]} -eq 0 && "${_a}" =~ ^[a-zA-Z]+$ && "${_a}" == *T* ]]; then
        _args+=("${_a//T/}")
    else
        _args+=("${_a}")
    fi
done
exec "@ZIG_BIN@" ar "${_args[@]}"
