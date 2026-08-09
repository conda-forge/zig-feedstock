# Force-load helper for zig cc/c++ on macOS.
# Sourced by zig-force-load-cc.sh and zig-force-load-cxx.sh.
#
# Intercepts -Wl,-all_load and -Wl,-force_load,<archive> flags that zig's
# Mach-O linker doesn't support. Extracts .o files from the archives and
# passes them directly to zig.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${ZIG_FL_SKIP_COMMON:-}" ]; then
    source "${_self_dir}/@WRAPPER_PREFIX@_zig-cc-common.sh"
else
    # ZIG_FL_SKIP_COMMON: caller (e.g. a build-time consumer) wants the raw
    # argv as the exec baseline, with no -target/-mcpu/sysroot injection from
    # _zig-cc-common.sh.
    _exec_args=("$@")
fi

# _exec_args is now set (either by _zig-cc-common.sh, or above when skipped).
# _zig-cc-common.sh already strips -Wl,-all_load and -Wl,-force_load,* silently.
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

# Fail loud if ZIG_FL_EXEC is set but not executable, instead of letting the
# exec below emit a cryptic "bin/-cc: No such file" ENOENT. Catches a build-time
# shim composing ZIG_FL_EXEC from an empty triple var (an empty triple yields
# ${BUILD_PREFIX}/bin/-cc). Only checks when set; the unset case falls through to
# the templated @ZIG_BIN@ (shipped activation path).
if [[ -n "${ZIG_FL_EXEC:-}" ]] && ! command -v "${ZIG_FL_EXEC}" >/dev/null 2>&1; then
    echo "zig force-load: ZIG_FL_EXEC set but not executable: '${ZIG_FL_EXEC}'" >&2
    echo "  (likely a build-time shim composed it from an empty triple variable)" >&2
    exit 1
fi

# If no force-load flags found, just exec normally
if [[ ${_all_load} -eq 0 ]] && [[ ${#_force_load_archives[@]} -eq 0 ]]; then
    # ZIG_FL_TARGET: append last so it wins over any caller-supplied -target
    # (zig CLI: last -target wins). No-op when unset (default).
    if [[ -n "${ZIG_FL_TARGET:-}" ]]; then
        _exec_args+=( -target "${ZIG_FL_TARGET}" )
    fi
    # ZIG_FL_EXEC: override exec target. Unset -> literal @ZIG_BIN@ placeholder
    # (preserved verbatim for install_zig_activation.py templating).
    exec "${ZIG_FL_EXEC:-@ZIG_BIN@}" "${_exec_args[@]}"
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

# ZIG_FL_DEDUP: dedupe archives by basename before extraction. No-op unless
# set to "1" (default keeps today's unconditional-append behaviour).
if [[ "${ZIG_FL_DEDUP:-}" == "1" ]]; then
    _seen_archives=""
    _archives_dedup=()
    for _archive in "${_archives_to_extract[@]}"; do
        _abase="$(basename "${_archive}")"
        case " ${_seen_archives} " in
            *" ${_abase} "*) ;;
            *) _archives_dedup+=("${_archive}"); _seen_archives="${_seen_archives} ${_abase}" ;;
        esac
    done
    _archives_to_extract=("${_archives_dedup[@]}")
fi

# Extract .o files from archives
_extracted_objects=()
_seen_objs=""
if [[ ${#_archives_to_extract[@]} -gt 0 ]]; then
    _tmpdir="$(mktemp -d)"
    _idx=0
    for _archive in "${_archives_to_extract[@]}"; do
        _subdir="${_tmpdir}/ar_${_idx}"
        mkdir -p "${_subdir}"
        (cd "${_subdir}" && ar x "${_archive}")
        _arch_base="$(basename "${_archive}")"
        for _obj in "${_subdir}"/*.o; do
            [[ -f "$_obj" ]] || continue
            if [[ "${ZIG_FL_DEDUP:-}" == "1" ]]; then
                # Dedup scoped to (archive,basename): cross-archive same-name
                # objects are intentionally kept (e.g. LLVM has many
                # Driver.cpp.o duplicates across archives -- dropping them
                # silently would corrupt the link).
                _obase="$(basename "${_obj}")"
                _dedup_key="${_arch_base}:${_obase}"
                case " ${_seen_objs} " in
                    *" ${_dedup_key} "*) continue ;;
                    *) _seen_objs="${_seen_objs} ${_dedup_key}" ;;
                esac
            fi
            _extracted_objects+=("$_obj")
        done
        ((_idx++))
    done
fi

# ZIG_FL_TARGET: same override as the fast path above.
if [[ -n "${ZIG_FL_TARGET:-}" ]]; then
    _exec_args+=( -target "${ZIG_FL_TARGET}" )
fi

if [[ -n "${ZIG_FL_SKIP_COMMON:-}" ]]; then
    # _exec_args is raw argv here (common.sh was skipped, so it never
    # stripped the force-load directives out of it). Strip them now so the
    # exec target below isn't handed flags it can't parse, and drop bare
    # .a paths that were already force-extracted above.
    _final_exec_args=()
    _skip_next_fa=0
    for _ea in "${_exec_args[@]}"; do
        if (( _skip_next_fa )); then
            _skip_next_fa=0
            continue
        fi
        case "$_ea" in
            -Wl,-all_load|-all_load) ;;
            -Wl,-force_load,*) ;;
            -force_load) _skip_next_fa=1 ;;
            *.a)
                if [[ ${_all_load} -eq 1 ]]; then
                    :  # drop -- already force-extracted above
                else
                    _final_exec_args+=("$_ea")
                fi
                ;;
            *) _final_exec_args+=("$_ea") ;;
        esac
    done
    _exec_args=("${_final_exec_args[@]}")
fi

exec "${ZIG_FL_EXEC:-@ZIG_BIN@}" "${_exec_args[@]}" "${_extracted_objects[@]}"
