# GENERATED FILE -- DO NOT EDIT BY HAND.
# Source of truth: recipe/building/flag_rules.py
# Regenerate:       python recipe/building/gen_translators.py
# CI drift guard:   python recipe/building/gen_translators.py --check
#
# _zig_translate_flags -- shared flag-translation rules R1-R13 (unix
# profile only -- this fragment is only ever sourced by the bash wrapper,
# which always runs on the unix profile).
#
# Contract:
#   Inputs (globals, caller sets before calling):
#     _tr_in_args       : array  - args to translate (e.g. "$@")
#     _tr_conda_prefix  : string - $CONDA_PREFIX
#     _tr_target_arch   : string - baked-in @ZIG_TARGET_ARCH@
#     _tr_is_win_target : 0|1    - whether the baked-in zig target is a
#                         windows/mingw target (drives R1's -Map rewrite)
#     _tr_mode_is_cxx   : 0|1    - 1 for c++ mode, 0 for cc mode
#   Outputs (globals, set by this function):
#     _tr_out_args : array  - translated args. Already includes any
#                    injected "-mcpu=baseline" (R6, prepended first) and
#                    translated -target/--target= values (R5); does NOT
#                    include the zig binary path, the mode token, or
#                    "-fuse-ld=lld" (those remain hand-written in the
#                    sourcing wrapper, out of scope here).
#     _tr_use_lld  : 0|1  - caller MUST OR this with its own hand-written
#                    scan for the remaining out-of-scope LLD triggers
#                    (--version-script, --dynamic-list, --gc-sections,
#                    --build-id, --allow-shlib-undefined, -fuse-ld=lld
#                    itself) before deciding whether to prepend
#                    "-fuse-ld=lld".
#     _tr_mode_out : string - possibly downgraded to "cc" by R4.
#
# May print R2/R3/R10-R13 output directly and `exit 0` -- this function is meant
# to be `source`d (not run in a subshell), so `exit` here really does
# exit the whole wrapper process, matching the pre-refactor fragment's
# behavior.
_zig_translate_flags() {
    local _a _i _n _dir _name _prog
    local _argc=${#_tr_in_args[@]}

    # R2/R3/R10-R13: intercept rules -- single arg scan, one case dispatch.
    for _a in "${_tr_in_args[@]}"; do
        case "$_a" in
        -print-search-dirs)
            local _zig_lib="${_tr_conda_prefix}/lib/zig"
            local _arch_leaf="lib-x86_64"
            [[ "${_tr_target_arch}" == "aarch64" ]] && _arch_leaf="libarm64"
            echo "install: ${_zig_lib}/"
            echo "programs: =${_tr_conda_prefix}/bin/"
            echo "libraries: =${_zig_lib}/libc/mingw/lib-common:${_zig_lib}/libc/mingw/${_arch_leaf}:${_zig_lib}"
            exit 0
            ;;
        -print-file-name=*)
            _name="${_a#-print-file-name=}"
            for _dir in "${_tr_conda_prefix}/lib/zig-llvm/lib" "${_tr_conda_prefix}/lib"; do
                if [[ -e "${_dir}/${_name}" ]]; then
                    echo "${_dir}/${_name}"
                    exit 0
                fi
            done
            echo "${_name}"
            exit 0
            ;;
        -print-multi-os-directory)
            echo "."
            exit 0
            ;;
        -print-prog-name=*)
            _name="${_a#-print-prog-name=}"
            _prog="${_tr_conda_prefix}/bin/${_name}"
            if [[ -e "${_prog}" ]]; then
                echo "${_prog}"
            else
                echo "${_name}"
            fi
            exit 0
            ;;
        -print-sysroot)
            echo "${_sr:-}"
            exit 0
            ;;
        -print-multiarch)
            if (( _tr_is_win_target )); then
                _zig_tr_translate_target "${_tr_target_arch}-w64-mingw32"
            else
                _zig_tr_translate_target "${_tr_target_arch}-conda-linux-gnu"
            fi
            exit 0
            ;;
        esac
    done

    # Pre-scan: use_lld triggers (R8, R9-trigger-subset) + -mcpu= presence (R6).
    _tr_use_lld=0
    local _has_mcpu=0
    for _i in "${!_tr_in_args[@]}"; do
        _a="${_tr_in_args[$_i]}"
        case "$_a" in
            -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic|-Bsymbolic-functions|-Bsymbolic) _tr_use_lld=1 ;;
            -Wl,-z,defs|-Wl,-z,nodelete) _tr_use_lld=1 ;;
            -Wl,-O[0-9]*) _tr_use_lld=1 ;;
            -mcpu=*) _has_mcpu=1 ;;
        esac
        if [[ "$_a" == "-Xlinker" ]]; then
            _n="${_tr_in_args[$((_i + 1))]:-}"
            case "$_n" in
                -Bsymbolic-functions|-Bsymbolic) _tr_use_lld=1 ;;
            esac
        fi
    done

    _tr_out_args=()
    (( _has_mcpu )) || _tr_out_args+=("-mcpu=baseline")

    local _saw_nostdlibxx=0
    _i=0
    while [[ $_i -lt $_argc ]]; do
        _a="${_tr_in_args[$_i]}"

        # R1: -Map rewrite (mingw targets only)
        if (( _tr_is_win_target )); then
            case "$_a" in
                -Map)
                    _n="${_tr_in_args[$((_i + 1))]:-}"
                    if [[ -n "$_n" ]]; then
                        _tr_out_args+=("-Wl,-Map,${_n}")
                        _i=$((_i + 2))
                        continue
                    fi
                    ;;
                -Map=*)
                    _tr_out_args+=("-Wl,-Map,${_a#-Map=}")
                    _i=$((_i + 1))
                    continue
                    ;;
                -Map?*)
                    _tr_out_args+=("-Wl,-Map,${_a#-Map}")
                    _i=$((_i + 1))
                    continue
                    ;;
            esac
        fi

        # R4: -nostdlib++ strip + mode downgrade
        if [[ "$_a" == "-nostdlib++" ]]; then
            _saw_nostdlibxx=1
            _i=$((_i + 1))
            continue
        fi

        # R8: -Xlinker Bsymbolic(-functions) pair -- keep verbatim (already
        # counted toward use_lld in the pre-scan above).
        if [[ "$_a" == "-Xlinker" ]]; then
            _n="${_tr_in_args[$((_i + 1))]:-}"
            case "$_n" in
                -Bsymbolic-functions|-Bsymbolic)
                    _tr_out_args+=("$_a" "$_n")
                    _i=$((_i + 2))
                    continue
                    ;;
            esac
        fi

        # R7: hybrid-gated -Wl,* drop -- gate=always members first.
        case "$_a" in
            -Wl,--color-diagnostics | -Wl,-rpath-link* | -Wl,--disable-new-dtags)
                _i=$((_i + 1))
                continue
                ;;
        esac
        # R7: gate=when_not_lld members -- only while use_lld is inactive.
        # (block is empty when R7 has no when_not_lld members, e.g. after
        # the 2026-07-15 narrowing to the 3 always-drop flags.)

        # R9: -Wl,-z,* / -Wl,-O* -- always kept, never dropped (falls
        # through to the default keep below; the trigger subset was
        # already counted toward use_lld in the pre-scan above).

        # R5: -target / --target= translation
        if [[ "$_a" == "-target" ]]; then
            _n="${_tr_in_args[$((_i + 1))]:-}"
            _tr_out_args+=("$_a" "$(_zig_tr_translate_target "$_n")")
            _i=$((_i + 2))
            continue
        fi
        case "$_a" in
            --target=*)
                _tr_out_args+=("--target=$(_zig_tr_translate_target "${_a#--target=}")")
                _i=$((_i + 1))
                continue
                ;;
        esac

        _tr_out_args+=("$_a")
        _i=$((_i + 1))
    done

    _tr_mode_out="cc"
    (( _tr_mode_is_cxx )) && _tr_mode_out="c++"
    (( _saw_nostdlibxx )) && _tr_mode_out="cc"
}

# R5 helper: conda triplet -> zig triplet (unix profile: includes darwin).
_zig_tr_translate_target() {
    case "$1" in
        x86_64-w64-mingw32*)   echo "x86_64-windows-gnu" ;;
        aarch64-w64-mingw32*)   echo "aarch64-windows-gnu" ;;
        *-conda-linux-gnu*)    echo "${1%%-conda-linux-gnu*}-linux-gnu" ;;
        x86_64-apple-darwin*)   echo "x86_64-macos-none" ;;
        arm64-apple-darwin*)   echo "aarch64-macos-none" ;;
        *)                     echo "$1" ;;
    esac
}
