# Shared flag filtering and sysroot detection for zig cc/c++ wrappers.
# Sourced by zig-cc.sh and zig-cxx.sh — not installed directly.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")
# Sets: _exec_args (array) ready for: exec "@ZIG_BIN@" "${_exec_args[@]}"

_ZIG_MODE="${_ZIG_MODE:-cc}"

# --- Sysroot detection (Linux only) ---
_sysroot_flags=()
if [[ "$(uname -s)" == "Linux" ]] && [[ "@ZIG_TARGET@" != "native" ]]; then
    _arch="@ZIG_TARGET_ARCH@"
    _sr="${CONDA_PREFIX}/${_arch}-conda-linux-gnu/sysroot"
    [[ ! -d "${_sr}" ]] && _sr="${CONDA_BUILD_SYSROOT:-}"
    if [[ -d "${_sr}" ]]; then
        _sysroot_flags+=(-isysroot "${_sr}" -L"${_sr}/usr/lib64" -L"${_sr}/usr/lib" -L"${_sr}/lib64" -L"${_sr}/lib")
    fi
fi

# --- Flag filtering ---
args=()
i=0
argv=("$@")
argc=${#argv[@]}

while [[ $i -lt $argc ]]; do
    arg="${argv[$i]}"
    case "$arg" in
        -Xlinker)
            next_i=$((i + 1))
            if [[ $next_i -lt $argc ]]; then
                next_arg="${argv[$next_i]}"
                case "$next_arg" in
                    -Bsymbolic-functions|-Bsymbolic|--color-diagnostics|--dependency-file=*)
                        i=$next_i ;;
                    *)
                        args+=("$arg" "$next_arg")
                        i=$next_i ;;
                esac
            fi
            ;;
        -Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags) ;;
        -Wl,--allow-shlib-undefined|-Wl,--no-allow-shlib-undefined) ;;
        -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic) ;;
        -Wl,--color-diagnostics) ;;
        -Wl,--version-script|-Wl,--version-script,*) ;;
        -Wl,-z,defs|-Wl,-z,nodelete|-Wl,-z,*) ;;
        -Wl,-O*) ;;
        -Wl,--gc-sections|-Wl,--no-gc-sections) ;;
        -Wl,--build-id|-Wl,--build-id=*) ;;
        -Wl,-exported_symbols_list|-Wl,-exported_symbols_list,*) ;;
        -Wl,-force_symbols_not_weak_list|-Wl,-force_symbols_not_weak_list,*) ;;
        -Wl,-force_symbols_weak_list|-Wl,-force_symbols_weak_list,*) ;;
        -Wl,-reexported_symbols_list|-Wl,-reexported_symbols_list,*) ;;
        -Wl,-unexported_symbols_list|-Wl,-unexported_symbols_list,*) ;;
        -Wl,-all_load|-Wl,-force_load,*) ;;
        -all_load|-force_load) ;;
        -Bsymbolic-functions|-Bsymbolic) ;;
        -march=*|-mtune=*|-mcpu=*|-ftree-vectorize) ;;
        -fstack-protector-strong|-fstack-protector|-fno-plt) ;;
        -fdebug-prefix-map=*) ;;
        -stdlib=*) ;;
        *) args+=("$arg") ;;
    esac
    ((i++))
done

# --- Handle -nostdlib++: downgrade to cc ---
_final_args=()
_saw_nostdlibxx=0
for _a in "${args[@]}"; do
    if [[ "$_a" == "-nostdlib++" ]]; then
        _saw_nostdlibxx=1
    else
        _final_args+=("$_a")
    fi
done

_mode="${_ZIG_MODE}"
[[ ${_saw_nostdlibxx} -eq 1 ]] && _mode="cc"

_exec_args=("${_mode}" -target @ZIG_TARGET@ -mcpu=baseline "${_sysroot_flags[@]}" "${_final_args[@]}")
