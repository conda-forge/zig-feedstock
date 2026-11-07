#!/bin/bash
# Zig msvc-target deactivation
# Installed to: $PREFIX/etc/conda/deactivate.d/zig_msvc_libc.sh

if [[ -n "${_ZIG_MSVC_OLD_LIBC_FILE+x}" ]]; then
    export ZIG_MSVC_LIBC_FILE="${_ZIG_MSVC_OLD_LIBC_FILE}"
else
    unset ZIG_MSVC_LIBC_FILE
fi
if [[ -n "${_ZIG_MSVC_OLD_EXTRA_INCLUDES+x}" ]]; then
    export ZIG_MSVC_EXTRA_INCLUDES="${_ZIG_MSVC_OLD_EXTRA_INCLUDES}"
else
    unset ZIG_MSVC_EXTRA_INCLUDES
fi
unset _ZIG_MSVC_OLD_LIBC_FILE _ZIG_MSVC_OLD_EXTRA_INCLUDES _ZIG_MSVC_SAVED
