#!/usr/bin/env bash
# Force-load wrapper for zig c++ on macOS.
#
# Intercepts -Wl,-all_load and -Wl,-force_load,<archive> flags that zig's
# Mach-O linker doesn't support. Extracts .o files from the archives and
# passes them directly to zig c++.
#
# Usage: zig-force-load-cxx <all normal zig c++ args>
# This wrapper sources _zig-cc-common.sh for standard flag filtering,
# then post-processes the filtered args to handle force-load.

_ZIG_MODE="c++"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_self_dir}/_zig-cc-common.sh"

# _exec_args is now set by _zig-cc-common.sh (mode, -target, -mcpu, sysroot, filtered args).
# But _zig-cc-common.sh already strips -Wl,-all_load and -Wl,-force_load,* silently.
# We need to intercept them BEFORE that filtering. Re-scan the original "$@".

_tmpdir=""
_cleanup() { [[ -n "${_tmpdir}" ]] && rm -rf "${_tmpdir}"; }
trap _cleanup EXIT

_all_load=0
_force_load_archives=()
_other_args=()

_i=0
_argv=("$@")
_argc=${#_argv[@]}

while [[ $_i -lt $_argc ]]; do
    _arg="${_argv[$_i]}"
    case "$_arg" in
        -Wl,-all_load)
            _all_load=1
            ;;
        -Wl,-force_load,*)
            _archive="${_arg#-Wl,-force_load,}"
            _force_load_archives+=("${_archive}")
            ;;
        -all_load)
            _all_load=1
            ;;
        -force_load)
            _next_i=$((_i + 1))
            if [[ $_next_i -lt $_argc ]]; then
                _force_load_archives+=("${_argv[$_next_i]}")
                _i=$_next_i
            fi
            ;;
        # Pass all archives when -all_load is active (collected below)
        *)
            _other_args+=("$_arg")
            ;;
    esac
    ((_i++))
done

# If no force-load flags found, just exec normally
if [[ ${_all_load} -eq 0 ]] && [[ ${#_force_load_archives[@]} -eq 0 ]]; then
    exec "@ZIG_BIN@" "${_exec_args[@]}"
fi

# Collect archives to extract
_archives_to_extract=()

if [[ ${_all_load} -eq 1 ]]; then
    # -all_load: extract ALL .a files from the arguments
    for _a in "${_other_args[@]}"; do
        if [[ "$_a" == *.a ]] && [[ -f "$_a" ]]; then
            # Resolve to absolute path — ar x runs in a different directory
            _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
        fi
    done
fi

# Add explicitly force-loaded archives
for _a in "${_force_load_archives[@]}"; do
    if [[ -f "$_a" ]]; then
        # Resolve to absolute path — ar x runs in a different directory
        _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
    else
        echo "WARNING: zig-force-load-cxx: archive not found: $_a" >&2
    fi
done

# Extract .o files from archives
_extracted_objects=()
if [[ ${#_archives_to_extract[@]} -gt 0 ]]; then
    _tmpdir="$(mktemp -d)"
    _idx=0
    for _archive in "${_archives_to_extract[@]}"; do
        # Each archive gets its own subdir to avoid name collisions
        _subdir="${_tmpdir}/ar_${_idx}"
        mkdir -p "${_subdir}"
        (cd "${_subdir}" && ar x "${_archive}")
        for _obj in "${_subdir}"/*.o; do
            [[ -f "$_obj" ]] && _extracted_objects+=("$_obj")
        done
        ((_idx++))
    done
fi

# Build final args: use _exec_args from _zig-cc-common.sh (already filtered)
# but append extracted .o files
exec "@ZIG_BIN@" "${_exec_args[@]}" "${_extracted_objects[@]}"
