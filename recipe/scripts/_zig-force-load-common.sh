# Force-load helper for zig cc/c++ on macOS.
# Sourced by zig-force-load-cc.sh and zig-force-load-cxx.sh.
#
# Intercepts -Wl,-all_load and -Wl,-force_load,<archive> flags that zig's
# Mach-O linker doesn't support. Extracts .o files from the archives and
# passes them directly to zig.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")

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
    for _a in "${_other_args[@]}"; do
        if [[ "$_a" == *.a ]] && [[ -f "$_a" ]]; then
            _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
        fi
    done
fi

for _a in "${_force_load_archives[@]}"; do
    if [[ -f "$_a" ]]; then
        _archives_to_extract+=("$(cd "$(dirname "$_a")" && pwd)/$(basename "$_a")")
    else
        echo "WARNING: zig-force-load-${_ZIG_MODE}: archive not found: $_a" >&2
    fi
done

# Extract .o files from archives
_extracted_objects=()
if [[ ${#_archives_to_extract[@]} -gt 0 ]]; then
    _tmpdir="$(mktemp -d)"
    _idx=0
    for _archive in "${_archives_to_extract[@]}"; do
        _subdir="${_tmpdir}/ar_${_idx}"
        mkdir -p "${_subdir}"
        (cd "${_subdir}" && ar x "${_archive}")
        for _obj in "${_subdir}"/*.o; do
            [[ -f "$_obj" ]] && _extracted_objects+=("$_obj")
        done
        ((_idx++))
    done
fi

exec "@ZIG_BIN@" "${_exec_args[@]}" "${_extracted_objects[@]}"
