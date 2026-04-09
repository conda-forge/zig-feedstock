# Shared flag filtering and sysroot detection for zig cc/c++ wrappers.
# Sourced by zig-cc.sh and zig-cxx.sh — not installed directly.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")
# Sets: _exec_args (array) ready for: exec "@ZIG_BIN@" "${_exec_args[@]}"
#
# NOTE: zig cc may use the self-hosted linker (not LLD) depending on target.
# The self-hosted linker doesn't support many standard ld flags, so we filter them.

_ZIG_MODE="${_ZIG_MODE:-cc}"

# --- Handle -print-file-name=<name> (GCC/Clang compat) ---
# zig doesn't support this flag. Intercept it, probe for the file in the
# same locations as libcxx_shared.zig (zig-llvm/lib then lib), print the
# path if found (or echo back the name if not), and exit.
for _arg in "$@"; do
    if [[ "$_arg" == -print-file-name=* ]]; then
        _name="${_arg#-print-file-name=}"
        for _dir in "${CONDA_PREFIX}/lib/zig-llvm/lib" "${CONDA_PREFIX}/lib"; do
            if [[ -e "${_dir}/${_name}" ]]; then
                echo "${_dir}/${_name}"
                exit 0
            fi
        done
        echo "${_name}"
        exit 0
    fi
done

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

# --- Auto-promote to LLD when LLD-only linker flags are detected ---
# zig cc uses the self-hosted linker by default, which doesn't support many
# standard ld flags. When we detect such flags, inject -fuse-ld=lld to switch
# to the bundled LLD (requires build 17+ main.zig patch). This preserves user
# intent instead of silently filtering flags.
_use_lld=0
for _a in "$@"; do
    case "$_a" in
        -fuse-ld=lld) _use_lld=1; break ;;
        # ELF (Linux) flags unsupported by self-hosted linker
        -Wl,--version-script|-Wl,--version-script,*) _use_lld=1; break ;;
        -Wl,--dynamic-list|-Wl,--dynamic-list,*|-Wl,--dynamic-list=*) _use_lld=1; break ;;
        -Wl,-z,defs|-Wl,-z,nodelete) _use_lld=1; break ;;
        -Wl,--gc-sections|-Wl,--no-gc-sections) _use_lld=1; break ;;
        -Wl,--build-id|-Wl,--build-id=*) _use_lld=1; break ;;
        -Wl,--allow-shlib-undefined|-Wl,--no-allow-shlib-undefined) _use_lld=1; break ;;
        -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic) _use_lld=1; break ;;
        -Bsymbolic-functions|-Bsymbolic) _use_lld=1; break ;;
        -Wl,-O[0-9]*) _use_lld=1; break ;;
        # Mach-O (macOS) flags -- now supported via LLD MachO pipeline
        -Wl,-exported_symbols_list|-Wl,-exported_symbols_list,*) _use_lld=1; break ;;
        -Wl,-unexported_symbols_list|-Wl,-unexported_symbols_list,*) _use_lld=1; break ;;
        -Wl,-reexported_symbols_list|-Wl,-reexported_symbols_list,*) _use_lld=1; break ;;
        -Wl,-force_symbols_not_weak_list|-Wl,-force_symbols_not_weak_list,*) _use_lld=1; break ;;
        -Wl,-force_symbols_weak_list|-Wl,-force_symbols_weak_list,*) _use_lld=1; break ;;
        -Wl,-all_load|-Wl,-force_load,*) _use_lld=1; break ;;
        -all_load|-force_load) _use_lld=1; break ;;
    esac
done

# --- Flag filtering ---
# Only filter flags genuinely unsupported by both linkers and Clang.
# LLD-supported flags pass through (LLD auto-promoted above).
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
                    --color-diagnostics|--dependency-file=*)
                        i=$next_i ;;
                    *)
                        args+=("$arg" "$next_arg")
                        i=$next_i ;;
                esac
            fi
            ;;
        # --- Always filtered: unsupported by all linkers or Clang ---
        -Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags) ;;
        -Wl,--color-diagnostics) ;;
        # (macOS Mach-O flags now handled via auto-LLD promotion above)
        # GCC-specific flags that zig's Clang doesn't accept
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

# --- macOS: honor MACOSX_DEPLOYMENT_TARGET at runtime ---
# Override the version in the target triple if MACOSX_DEPLOYMENT_TARGET is set.
# e.g. aarch64-macos.11.0-none -> aarch64-macos.14.0-none
_zig_target="@ZIG_TARGET@"
if [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]] && [[ "${_zig_target}" == *-macos* ]]; then
    _zig_target="${_zig_target%%-macos*}-macos.${MACOSX_DEPLOYMENT_TARGET}-${_zig_target##*macos*-}"
fi

# --- Inject -fuse-ld=lld if auto-promoted (skip if user already passed it) ---
_lld_flag=()
if (( _use_lld )); then
    _has_explicit=0
    for _a in "${_final_args[@]}"; do
        [[ "$_a" == "-fuse-ld=lld" ]] && _has_explicit=1 && break
    done
    (( _has_explicit )) || _lld_flag=(-fuse-ld=lld)
fi

# --- Allow user to override -target and -mcpu ---
_target_flag=(-target "${_zig_target}")
_mcpu_flag=(-mcpu=baseline)
for _a in "${_final_args[@]}"; do
    case "$_a" in
        -target|--target=*) _target_flag=() ;;
        -mcpu=*) _mcpu_flag=() ;;
    esac
done

_exec_args=("${_mode}" "${_lld_flag[@]}" "${_target_flag[@]}" "${_mcpu_flag[@]}" "${_sysroot_flags[@]}" "${_final_args[@]}")
