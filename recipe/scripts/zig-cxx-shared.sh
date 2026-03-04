#!/usr/bin/env bash
# Shared-library link wrapper: invokes ld.lld directly (not zig, not gcc).
# Translates compiler-driver flags into raw linker flags.

# --- Sysroot detection (Linux only) ---
_sysroot_link_flags=()
if [[ "$(uname -s)" == "Linux" ]] && [[ "@ZIG_TARGET@" != "native" ]]; then
    _arch="@ZIG_TARGET_ARCH@"
    _sr="${CONDA_PREFIX}/${_arch}-conda-linux-gnu/sysroot"
    [[ ! -d "${_sr}" ]] && _sr="${CONDA_BUILD_SYSROOT:-}"
    if [[ -d "${_sr}" ]]; then
        _sysroot_link_flags+=(-L"${_sr}/usr/lib64" -L"${_sr}/usr/lib" -L"${_sr}/lib64" -L"${_sr}/lib")
        for _ns in "${_sr}/usr/lib64/libc_nonshared.a" "${_sr}/usr/lib/libc_nonshared.a"; do
            [[ -e "${_ns}" ]] && _sysroot_link_flags+=("${_ns}") && break
        done
    fi
fi

# --- Flag translation ---
args=()
_skip_next=0
_grab_next=0
for arg in "$@"; do
    if [[ ${_skip_next} -eq 1 ]]; then
        _skip_next=0
        continue
    fi
    if [[ ${_grab_next} -eq 1 ]]; then
        _grab_next=0
        case "$arg" in
            -Bsymbolic-functions|-Bsymbolic|--color-diagnostics|--dependency-file=*) ;;
            *) args+=("$arg") ;;
        esac
        continue
    fi
    case "$arg" in
        -target) _skip_next=1 ;;
        -mcpu=*|-nostdlib++|-stdlib=*) ;;
        -f*|-O*|-g|-g[0-9]*|-W[^l]*|-D*|-I*|-std=*) ;;
        -Xlinker) _grab_next=1 ;;
        -Wl,-z,defs) ;;
        -Wl,*)
            IFS=',' read -ra _wl_parts <<< "${arg#-Wl,}"
            for _p in "${_wl_parts[@]}"; do
                [[ -n "${_p}" ]] && args+=("${_p}")
            done
            ;;
        *) args+=("$arg") ;;
    esac
done

# --- Find linker ---
_ld=""
for _cand in "${CONDA_PREFIX}/bin/ld.lld" "$(command -v ld.lld 2>/dev/null || true)" "$(command -v ld 2>/dev/null || true)"; do
    [[ -n "${_cand}" ]] && [[ -x "${_cand}" ]] && _ld="${_cand}" && break
done
[[ -z "${_ld}" ]] && echo "ERROR: zig-cxx-shared: no linker found" >&2 && exit 1

exec "${_ld}" "${args[@]}" "${_sysroot_link_flags[@]}"
