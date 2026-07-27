# Shared flag filtering and sysroot detection for zig cc/c++ wrappers.
# Sourced by zig-cc.sh and zig-cxx.sh — not installed directly.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")
# Sets: _exec_args (array) ready for: exec "@ZIG_BIN@" "${_exec_args[@]}"
#
# NOTE: zig cc may use the self-hosted linker (not LLD) depending on target.
# The self-hosted linker doesn't support many standard ld flags, so we filter them.

_ZIG_MODE="${_ZIG_MODE:-cc}"

# --- Ensure zig can resolve its cache directory ---
# zig's global cache resolves as: ZIG_GLOBAL_CACHE_DIR (explicit) >
# std.fs.getAppDataDir("zig")/zig-cache, where getAppDataDir on Linux checks
# XDG_DATA_HOME then HOME/.local/share.  If neither is set, zig panics with
# AppDataDirUnavailable.  Always set ZIG_GLOBAL_CACHE_DIR if unset, mirroring
# zig's own resolution so the variable is always populated before exec.
if [[ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${XDG_DATA_HOME}/zig/zig-cache"
    elif [[ -n "${HOME:-}" ]]; then
        export ZIG_GLOBAL_CACHE_DIR="${HOME}/.local/share/zig/zig-cache"
    else
        export ZIG_GLOBAL_CACHE_DIR="${TMPDIR:-/tmp}/zig-cache-$(id -u 2>/dev/null || echo 0)"
    fi
fi

# --- Source generated flag-translation rules (R1-R13, unix profile) ---
# Source of truth: recipe/building/flag_rules.py -> _zig_translate_flags()
# in recipe/building/_translate.gen.sh. Handles R1 (-Map rewrite), R2/R3
# (-print-search-dirs / -print-file-name= intercepts), R4 (-nostdlib++),
# R5 (-target/--target= triplet translation), R6 (-mcpu= preserve-or-
# default), R7 (always-drop -Wl,--color-diagnostics/-rpath-link*/
# --disable-new-dtags), R8 (-Bsymbolic* keep+trigger), R9 (-Wl,-z,*/
# -Wl,-O* passthrough+trigger), R10-R13 (-print-multi-os-directory /
# -print-prog-name= / -print-sysroot / -print-multiarch intercepts).
# Reuses _self_dir if the sourcing wrapper
# already computed it (zig-cc.sh/zig-cxx.sh/_zig-force-load-common.sh all
# do), else derives it from this file's own location.
_self_dir="${_self_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${_self_dir}/@WRAPPER_PREFIX@_translate.gen.sh"

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
_xlinker_next=0
for _a in "$@"; do
    # Handle -Xlinker <arg> pairs: check the arg after -Xlinker for LLD triggers
    if (( _xlinker_next )); then
        _xlinker_next=0
        case "$_a" in
            --dynamic-list|--dynamic-list=*|--version-script|--version-script=*) _use_lld=1; break ;;
            --gc-sections|--no-gc-sections|--build-id|--build-id=*) _use_lld=1; break ;;
            --allow-shlib-undefined|--no-allow-shlib-undefined) _use_lld=1; break ;;
            -exported_symbols_list|-exported_symbols_list,*) _use_lld=1; break ;;
            -unexported_symbols_list|-unexported_symbols_list,*) _use_lld=1; break ;;
            -all_load|-force_load|-force_load,*) _use_lld=1; break ;;
        esac
        continue
    fi
    case "$_a" in
        -Xlinker) _xlinker_next=1 ;;
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

# --- Preserve: -Xlinker general pair drop (out of R1-R9 manifest scope) ---
# Drops -Xlinker --color-diagnostics and -Xlinker --dependency-file=* pairs
# (Clang-specific flags the self-hosted linker path doesn't want); keeps
# every other -Xlinker <arg> pair verbatim. flag_rules.py explicitly calls
# this out as NOT part of R1-R9 ("-Xlinker general trigger/drop besides
# Bsymbolic ... stays hand-written"), so it runs as a pre-filter over the
# raw argv before the generated call (R8's own -Xlinker Bsymbolic handling
# lives inside the generated fn and is unaffected by this pre-filter).
_pre_args=()
_xl_argv=("$@")
_xl_argc=${#_xl_argv[@]}
_xl_i=0
while [[ $_xl_i -lt $_xl_argc ]]; do
    _xl_a="${_xl_argv[$_xl_i]}"
    if [[ "$_xl_a" == "-Xlinker" ]]; then
        _xl_next_i=$((_xl_i + 1))
        if [[ $_xl_next_i -lt $_xl_argc ]]; then
            _xl_next="${_xl_argv[$_xl_next_i]}"
            case "$_xl_next" in
                --color-diagnostics|--dependency-file=*) ;;
                *) _pre_args+=("$_xl_a" "$_xl_next") ;;
            esac
            _xl_i=$_xl_next_i
        fi
    else
        _pre_args+=("$_xl_a")
    fi
    ((_xl_i++))
done

# --- Delegate the 9 de-dup rules (R1-R9) to the generated translator ---
_tr_in_args=("${_pre_args[@]}")
_tr_conda_prefix="${CONDA_PREFIX}"
_tr_target_arch="@ZIG_TARGET_ARCH@"
_tr_is_win_target=0
[[ "@ZIG_TARGET@" == *-windows-* ]] && _tr_is_win_target=1
_tr_mode_is_cxx=0
[[ "${_ZIG_MODE}" == "c++" ]] && _tr_mode_is_cxx=1
_zig_translate_flags   # may exit 0 directly for R2 (-print-search-dirs) / R3 (-print-file-name=)

# Merge the generated fn's own R8/R9 trigger scan with the hand-written
# out-of-scope scan above (--version-script/--dynamic-list/--gc-sections/
# --build-id/--allow-shlib-undefined/Mach-O equivalents).
(( _tr_use_lld )) && _use_lld=1

# --- Block LLD on ppc64le: LLD lacks ppc64le relocation support ---
if (( _use_lld )) && [[ "@ZIG_TARGET_ARCH@" == "powerpc64le" ]]; then
    echo "zig cc: error: -fuse-ld=lld is not supported on ppc64le (LLD lacks ppc64le relocation support)" >&2
    echo "  Remove -fuse-ld=lld or any LLD-only flags (--dynamic-list, --version-script, etc.)" >&2
    exit 1
fi

# --- Flag filtering: unix-only drops NOT covered by the generated R1-R9
# manifest (GCC-specific flags Clang rejects, GCC runtime libs zig doesn't
# ship/can't link). Operates on the already-translated _tr_out_args.
_final_args=()
for _fa in "${_tr_out_args[@]}"; do
    case "$_fa" in
        # GCC-specific flags that zig's Clang doesn't accept
        -march=*|-mtune=*|-ftree-vectorize) ;;
        -fstack-protector-strong|-fstack-protector|-fno-plt) ;;
        # ppc64le REL24-mitigation flags (GCC-only) reach zig's Clang frontend
        # via CFLAGS during our own build of zig; Clang rejects them. Parity
        # port from the 0.16.0 _9 branch "GCC filter" (2026-07-27).
        -fno-partial-inlining|-fno-ipa-cp-clone) ;;
        -fdebug-prefix-map=*) ;;
        -stdlib=*) ;;
        # GCC runtime libraries zig doesn't ship and can't link
        # -lgcc_eh: GCC exception handling — zig uses its own EH mechanism
        # -lgcc_s:  GCC shared runtime — zig uses its own runtime
        -lgcc_eh|-lgcc_s) ;;
        # GNU ld colon-prefix syntax (-l:filename) for known zig-provided libs
        # The -l: prefix means "exact filename match" (GNU ld extension).
        # Zig's linker hits unreachable code when it sees this syntax.
        # For targets where zig provides pthreads natively (Windows, Linux via
        # libc), the static-pthread request is unnecessary and panics the linker.
        -l:libpthread.a|-l:libpthread.so*) ;;
        *) _final_args+=("$_fa") ;;
    esac
done

_mode="${_tr_mode_out}"

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

# --- Default -target injection (skip if the generated R5 pass already
# translated a user-provided -target/--target=) ---
_target_flag=(-target "${_zig_target}")
for _a in "${_final_args[@]}"; do
    case "$_a" in
        -target|--target=*) _target_flag=() ;;
    esac
done

_exec_args=("${_mode}" "${_lld_flag[@]}" "${_target_flag[@]}" "${_sysroot_flags[@]}" "${_final_args[@]}")
