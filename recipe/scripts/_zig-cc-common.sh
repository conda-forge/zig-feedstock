# Shared flag filtering and sysroot detection for zig cc/c++ wrappers.
# Sourced by zig-cc.sh and zig-cxx.sh — not installed directly.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")
# Sets: _exec_args (array) ready for: exec "@ZIG_BIN@" "${_exec_args[@]}"
#
# NOTE: zig cc may use the self-hosted linker (not LLD) depending on target.
# The self-hosted linker doesn't support many standard ld flags, so we filter them.

_ZIG_MODE="${_ZIG_MODE:-cc}"

# --- Target identifiers used by gates throughout this file ---
# Initialized from install-time template substitution. Future revisions may
# add a wrapper-name-derivation block here to override _zig_target/_zig_target_arch
# at runtime when callers export _zig_wrapper_invoked. Until that exists,
# these stay as the install-time-substituted constants.
_zig_target="@ZIG_TARGET@"
_zig_target_arch="@ZIG_TARGET_ARCH@"

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

# --- Handle -print-search-dirs (GCC compat for flexlink/mingw_libs) ---
# zig doesn't implement this flag. flexlink calls it to discover library search
# paths for resolving -lXXX arguments. Without a response, flexlink has no
# paths and treats -lws2_32 as a literal filename, then crashes.
for _arg in "$@"; do
    if [[ "$_arg" == "-print-search-dirs" ]]; then
        _zig_lib="${CONDA_PREFIX}/lib/zig"
        _mingw_common="${_zig_lib}/libc/mingw/lib-common"
        _mingw_arch="${_zig_lib}/libc/mingw/lib-@ZIG_TARGET_ARCH@"
        _mingw_libpath="${_mingw_common}:${_mingw_arch}"
        if [[ "${_zig_target}" == "aarch64-windows-gnu" ]]; then
            _mingw_libpath="${_mingw_libpath}:${_zig_lib}/libc/mingw/libarm64"
        fi
        echo "install: ${_zig_lib}/"
        echo "programs: =${CONDA_PREFIX}/bin/"
        echo "libraries: =${_mingw_libpath}:${_zig_lib}"
        exit 0
    fi
done

# --- Handle -print-file-name=<name> (GCC/Clang compat) ---
# zig doesn't support this flag. Intercept it and search:
#   1. zig-llvm/lib and lib/ -- for LLVM/clang runtime libs (libclang_rt.*, libc++.a, ...)
#   2. MinGW lib-common and arch-specific dirs -- for import libs (libkernel32.a, ...)
# Print the resolved path if found, or echo back the name if not (GCC behaviour).
for _arg in "$@"; do
    if [[ "$_arg" == -print-file-name=* ]]; then
        _name="${_arg#-print-file-name=}"
        _zig_lib="${CONDA_PREFIX}/lib/zig"
        _pfn_dirs=(
            "${CONDA_PREFIX}/lib/zig-llvm/lib"
            "${CONDA_PREFIX}/lib"
            "${_zig_lib}/libc/mingw/lib-common"
            "${_zig_lib}/libc/mingw/lib-@ZIG_TARGET_ARCH@"
            "${CONDA_PREFIX}/Library/lib/zig/libc/mingw/lib-common"
            "${CONDA_PREFIX}/Library/lib/zig/libc/mingw/lib-@ZIG_TARGET_ARCH@"
        )
        if [[ "${_zig_target}" == "aarch64-windows-gnu" ]]; then
            _pfn_dirs+=(
                "${_zig_lib}/libc/mingw/libarm64"
                "${CONDA_PREFIX}/Library/lib/zig/libc/mingw/libarm64"
            )
        fi
        for _dir in "${_pfn_dirs[@]}"; do
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
# Search order: CONDA_PREFIX > BUILD_PREFIX > CONDA_BUILD_SYSROOT
# BUILD_PREFIX fallback is needed for cross-build native tool sub-builds
# (CROSS_TOOLCHAIN_FLAGS_NATIVE) where the x86_64 sysroot lives in
# BUILD_PREFIX but CONDA_PREFIX may not point there.
_sysroot_flags=()
if [[ "$(uname -s)" == "Linux" ]] && [[ "${_zig_target}" != "native" ]]; then
    _arch="${_zig_target_arch}"
    _sr=""
    for _candidate in \
        "${CONDA_PREFIX:+${CONDA_PREFIX}/${_arch}-conda-linux-gnu/sysroot}" \
        "${BUILD_PREFIX:+${BUILD_PREFIX}/${_arch}-conda-linux-gnu/sysroot}" \
        "${CONDA_BUILD_SYSROOT:-}"; do
        [[ -d "${_candidate:-}" ]] && _sr="${_candidate}" && break
    done
    if [[ -n "${_sr}" ]]; then
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
        -Wl,-syslibroot|-Wl,-syslibroot,*) _use_lld=1; break ;;
    esac
done

# --- Don't auto-promote to LLD for macOS targets ---
# zig's native linker handles macOS SDK paths (-isysroot, -Wl,-syslibroot) and
# libSystem auto-linking properly. External lld bypasses zig's SDK plumbing and
# fails with "library not found for -lSystem" even with correct sysroot flags.
case "${_zig_target}" in
    *-macos*|*-darwin*) _use_lld=0 ;;
esac

# --- Block explicit LLD on ppc64le: LLD lacks ppc64le relocation support ---
# Only error on explicit -fuse-ld=lld. Standard ELF flags (--version-script,
# --gc-sections, --build-id, etc.) pass through to ld.bfd via the GCC linker
# redirect in Lld.zig -- they are NOT LLD-only.
if (( _use_lld )) && [[ "${_zig_target_arch}" == "powerpc64le" ]]; then
    for _a in "$@"; do
        if [[ "$_a" == "-fuse-ld=lld" ]]; then
            echo "zig cc: error: -fuse-ld=lld is not supported on ppc64le (LLD lacks ppc64le relocation support)" >&2
            exit 1
        fi
    done
fi

# --- Flag filtering ---
# Only filter flags genuinely unsupported by both linkers and Clang.
# LLD-supported flags pass through (LLD auto-promoted above).
args=()
i=0
argv=("$@")
argc=${#argv[@]}
_next_is_rpath_link=0
_next_is_xclang=0

while [[ $i -lt $argc ]]; do
    arg="${argv[$i]}"
    # Handle two-arg form of -Wl,-rpath-link <path> for ppc64le conversion to -L.
    if (( _next_is_rpath_link )); then
        _next_is_rpath_link=0
        args+=( "-L" "$arg" )
        ((i++))
        continue
    fi
    # Handle two-arg form of /Xclang FLAG: forward FLAG directly to zig.
    if (( _next_is_xclang )); then
        _next_is_xclang=0
        args+=( "$arg" )
        ((i++))
        continue
    fi
    case "$arg" in
        # clang-cl passthrough: /clang:X means "pass X to the underlying clang driver".
        # zig-cc is gcc-style and doesn't recognize the /clang: prefix. Strip it and
        # append the un-prefixed flag so zig receives it directly.
        # Used by cmake when target ABI is *-windows-msvc, e.g. normalization probes
        # like `/clang:--target=x86_64-pc-windows-msvc /clang:-print-target-triple`.
        /clang:*)
            args+=( "${arg#/clang:}" )
            ((i++))
            continue
            ;;
        # clang-cl two-arg form: /Xclang FLAG passes FLAG to the clang frontend.
        # zig-cc doesn't recognize /Xclang; consume the flag name here and let the
        # next iteration forward the bare FLAG through to zig directly.
        /Xclang)
            _next_is_xclang=1
            ((i++))
            continue
            ;;
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
        # macOS: -isysroot is needed during compilation (SDK header search).
        # During linking, zig's driver converts -isysroot to -syslibroot
        # internally but its MachO linker rejects it. So:
        #   compile: pass -isysroot through (SDK headers)
        #   link:    strip -isysroot, emit -Wl,-syslibroot instead (below)
        # We stash the path and defer the compile/link decision to after
        # the full arg scan (where _is_compile_only is determined).
        -isysroot)
            next_i=$((i + 1))
            if [[ $next_i -lt $argc ]]; then
                _macos_syslibroot="${argv[$next_i]}"
                i=$next_i
            fi
            ;;
        -Wl,-rpath-link|-Wl,-rpath-link,*)
            # ppc64le: zig→gcc→ld.real chain swallows -Wl,-rpath-link. Convert to -L
            # so ld.real can resolve transitive SONAMEs of dynamic libs being linked.
            # LLD: pass through (LLD handles -rpath-link natively).
            # Others: drop — zig's self-hosted linker doesn't accept this flag.
            if [[ "${_zig_target_arch}" == "powerpc64le" ]]; then
                case "$arg" in
                    -Wl,-rpath-link,*) args+=( "-L" "${arg#-Wl,-rpath-link,}" ) ;;
                    -Wl,-rpath-link)   _next_is_rpath_link=1 ;;
                esac
            elif (( _use_lld )); then
                args+=("$arg")
            fi
            ;;
        -Wl,--disable-new-dtags) ;;
        -Wl,--color-diagnostics) ;;
        # (macOS Mach-O flags now handled via auto-LLD promotion above)
        # GCC-specific flags that zig's Clang doesn't accept
        -march=*|-mtune=*|-mcpu=*|-ftree-vectorize) ;;
        -fstack-protector-strong|-fstack-protector|-fno-plt) ;;
        -fdebug-prefix-map=*) ;;
        -stdlib=*) ;;
        # GCC runtime libraries zig doesn't ship and can't link
        # -lgcc_eh: GCC exception handling — zig uses its own EH mechanism
        # -lgcc_s:  GCC shared runtime — zig uses its own runtime
        -lgcc_eh|-lgcc_s) ;;
        # UNIX-only libraries not present on Windows targets.
        # -ldl:      dlopen/dlsym → LoadLibrary/GetProcAddress (kernel32), not a lib
        # -lpthread: Win32 threads; zig provides pthreads via its Win32 adapter
        # Pass through unchanged on non-Windows targets (Linux/macOS need them).
        -ldl|-lpthread)
            [[ "${_zig_target}" == *-windows-* ]] || args+=("$arg")
            ;;
        # ARM64 Windows uses ucrt only -- no msvcrt.lib in zig's MinGW sysroot.
        # flexlink/OCaml inject -lmsvcrt via BYTECCLIBS; translate to -lucrtbase.
        -lmsvcrt)
            if [[ "${_zig_target}" == *-windows-* ]]; then
                args+=("-lucrtbase")
            else
                args+=("$arg")
            fi
            ;;
        # GNU ld colon-prefix syntax (-l:filename) for known zig-provided libs
        # The -l: prefix means "exact filename match" (GNU ld extension).
        # Zig's linker hits unreachable code when it sees this syntax.
        # For targets where zig provides pthreads natively (Windows, Linux via
        # libc), the static-pthread request is unnecessary and panics the linker.
        -l:libpthread.a|-l:libpthread.so*) ;;
        # macOS: cmake generates bare -l (empty library name) for pthread/dl/atomic
        # since those live in libSystem and cmake vars are empty. ld64.lld rejects
        # bare -l with "library not found for -l"; filter them (harmless no-ops).
        -l) ;;
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
    # Disable ELF dependent library specifiers (#pragma comment(lib, ...))
    # on Linux. LLD resolves these separately from -l flags and may fail
    # when the sysroot lacks stub libraries (glibc ≥2.34 merges libdl/
    # libpthread into libc). The specifiers are always redundant — cmake
    # and build systems add explicit -l flags on the link command line.
    if [[ "$(uname -s)" == "Linux" ]]; then
        _lld_flag+=(-Wl,--no-dependent-libraries)
    fi
fi

# --- Translate conda triplets to zig triplets in -target args ---
# Build systems (configure, cmake, meson) pass conda-format triplets that zig
# doesn't understand. Translate them transparently.
_conda_to_zig_target() {
    case "$1" in
        x86_64-w64-mingw32*)   echo "x86_64-windows-gnu" ;;
        aarch64-w64-mingw32*)  echo "aarch64-windows-gnu" ;;
        x86_64-apple-darwin*)  echo "x86_64-macos-none" ;;
        arm64-apple-darwin*)   echo "aarch64-macos-none" ;;
        *-conda-linux-gnu*)    echo "${1%%-conda-linux-gnu*}-linux-gnu" ;;
        *)                     echo "$1" ;;  # pass through as-is
    esac
}

# Scan for user-provided -target and -mcpu, translate if needed
_target_flag=(-target "${_zig_target}")
_mcpu_flag=(-mcpu=baseline)
_translated_args=()
_skip_next=0
for _i in "${!_final_args[@]}"; do
    _a="${_final_args[$_i]}"
    if (( _skip_next )); then
        _skip_next=0
        # This is the value after -target -- translate it
        _translated_args+=("$(_conda_to_zig_target "$_a")")
        _target_flag=()  # user provided -target, skip baked-in
        continue
    fi
    case "$_a" in
        -target)
            _skip_next=1
            _translated_args+=("$_a")
            ;;
        --target=*)
            _val="${_a#--target=}"
            _translated_args+=("--target=$(_conda_to_zig_target "$_val")")
            _target_flag=()
            ;;
        -mcpu=*) _mcpu_flag=(); _translated_args+=("$_a") ;;
        # macOS: zig native linker (self-hosted Mach-O) rejects -syslibroot.
        # Drop these when not using external LLD on macOS targets; the
        # -isysroot emitted by _syslibroot_flag covers SDK location instead.
        # When _use_lld=1, ld64.lld accepts -syslibroot, so pass through.
        -Wl,-syslibroot|-Wl,-syslibroot,*)
            if (( ! _use_lld )) && [[ "${_zig_target}" == *-macos* || "${_zig_target}" == *-darwin* ]]; then
                continue
            fi
            _translated_args+=("$_a")
            ;;
        *) _translated_args+=("$_a") ;;
    esac
done

# --- WIN-ARM64: inject _fpreset stub to satisfy CRT auto-import relocation ---
# MinGW crt2.obj references _fpreset via DLL auto-import using
# IMAGE_REL_ARM64_BRANCH26 which lld-link cannot use for import stubs.
# Providing a direct definition via the stub bypasses auto-import entirely.
# Only inject on link steps (no -c flag in args).
_fpreset_stub=()
if [[ "${_zig_target}" == "aarch64-windows-gnu" ]]; then
    _stub="${CONDA_PREFIX}/lib/zig/libc/mingw/libarm64/_fpreset_arm64.o"
    _is_compile_only=0
    for _a in "${_translated_args[@]}"; do
        [[ "$_a" == "-c" ]] && _is_compile_only=1 && break
    done
    if [[ ${_is_compile_only} -eq 0 ]] && [[ -f "${_stub}" ]]; then
        _fpreset_stub=("${_stub}")
    fi
fi

# --- Link-only flags: detect compile-only mode (-c/-E/-S) ---
_is_compile_only=0
for _a in "${_translated_args[@]}"; do
    case "$_a" in -c|-E|-S) _is_compile_only=1; break;; esac
done

# --- macOS SDK selection helper ---
# _pick_macos_sdk <glob>
# Selects the best-matching MacOSX SDK for MACOSX_DEPLOYMENT_TARGET.
# Priority: (1) exact match MacOSX<DEPLOYMENT_TARGET>.sdk;
#           (2) major-version match MacOSX<MAJOR>*.sdk (highest of that major);
#           (3) newest of all matches (sort -V | tail -1).
# Echoes the chosen path or empty string if none found.
_pick_macos_sdk() {
    local _glob="$1"
    local _mdt="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    local _major="${_mdt%%.*}"
    local _chosen=""
    # (1) exact match
    local _exact
    _exact=$(ls -d ${_glob} 2>/dev/null | grep "MacOSX${_mdt}\.sdk$" | sort -V | tail -1)
    if [[ -d "${_exact:-}" ]]; then
        echo "${_exact}"
        return
    fi
    # (2) major-version match (e.g. MacOSX11*.sdk), pick highest
    _chosen=$(ls -d ${_glob} 2>/dev/null | grep "MacOSX${_major}\." | sort -V | tail -1)
    if [[ -d "${_chosen:-}" ]]; then
        echo "${_chosen}"
        return
    fi
    # (3) newest of all
    _chosen=$(ls -d ${_glob} 2>/dev/null | sort -V | tail -1)
    if [[ -d "${_chosen:-}" ]]; then
        echo "${_chosen}"
        return
    fi
    echo ""
}

# --- macOS: -isysroot / -syslibroot handling (compile vs link) ---
# Compile: pass -isysroot for SDK header search.
# Link: depends on which linker is in play.
#   * Self-hosted Mach-O linker (zig's default): rejects -syslibroot and
#     -isysroot at link time; rely on zig's automatic SDKROOT detection.
#   * ld64.lld (when _use_lld=1, e.g. via -Wl,-all_load auto-promotion):
#     accepts -Wl,-syslibroot,<sdk>. Without it, zig cannot resolve SDK
#     .tbd stubs (libSystem etc.) and emits bare -l entries to ld64.lld
#     which fail with "library not found for -l".
_syslibroot_flag=()
if [[ -n "${_macos_syslibroot:-}" ]]; then
    if [[ ${_is_compile_only} -eq 1 ]]; then
        _syslibroot_flag=("-isysroot" "${_macos_syslibroot}")
    elif (( _use_lld )); then
        _syslibroot_flag=("-isysroot" "${_macos_syslibroot}" "-Wl,-syslibroot,${_macos_syslibroot}")
    fi
    # Self-hosted-link path: _syslibroot_flag stays empty — -isysroot already stripped
fi

# --- macOS: override Xcode SDK with conda-forge SDK ---
# When cmake supplies -isysroot pointing to a host Xcode or Command Line Tools
# SDK (not a conda-forge SDK), ld64.lld fails with "library not found for
# -lSystem" and undefined symbols (_abort, _free, _malloc, etc.) because the
# Xcode SDK ABI does not match the conda-forge -target triple.
# Override with the conda-forge SDK when available.
if [[ "${_zig_target}" == *-macos* ]]; then
    if [[ -n "${_macos_syslibroot:-}" ]] && [[ "${_macos_syslibroot}" == /Applications/Xcode* || "${_macos_syslibroot}" == /Library/Developer/CommandLineTools* ]]; then
        _conda_sdk=""
        for _cand in \
            "${CONDA_BUILD_SYSROOT:-}" \
            "${CONDA_PREFIX:+${CONDA_PREFIX}/MacOSX.sdk}"; do
            [[ -d "${_cand:-}" ]] && { _conda_sdk="${_cand}"; break; }
        done
        if [[ -z "${_conda_sdk}" ]]; then
            _conda_sdk=$(_pick_macos_sdk '/opt/MacOSX*.sdk /opt/conda/sdks/MacOSX*.sdk')
            [[ -d "${_conda_sdk:-}" ]] || _conda_sdk=""
        fi
        if [[ -n "${_conda_sdk}" ]]; then
            _macos_syslibroot="${_conda_sdk}"
            _syslibroot_flag=()
            if [[ ${_is_compile_only} -eq 1 ]]; then
                _syslibroot_flag=("-isysroot" "${_macos_syslibroot}")
            elif (( _use_lld )); then
                _syslibroot_flag=("-isysroot" "${_macos_syslibroot}" "-Wl,-syslibroot,${_macos_syslibroot}")
            fi
        else
            >&2 echo "WARNING: zig-wrapper: -isysroot pointed at Xcode/CLT (${_macos_syslibroot}) but no conda-forge SDK found in /opt, /opt/conda/sdks, CONDA_BUILD_SYSROOT, or CONDA_PREFIX"
        fi
        unset _conda_sdk _cand
    fi
fi

# --- macOS: auto-detect SDK when no -isysroot was supplied by the caller ---
# Build systems that don't call clang through the Xcode toolchain path may
# omit -isysroot entirely. Without it, compile steps won't find SDK headers.
# Search order:
#   1. $SDKROOT (set by macosx_deployment_target activate.d scripts)
#   2. $CONDA_BUILD_SYSROOT (set by conda-forge on macOS)
#   3. $CONDA_PREFIX/MacOSX.sdk (canonical conda-forge SDK symlink)
#   4. best MacOSX*.sdk glob under $CONDA_PREFIX (fallback)
#   5. /opt/MacOSX*.sdk (conda-forge GitHub Actions runner install)
#   6. /opt/conda/sdks/MacOSX*.sdk (conda-forge docker install)
#   7. xcrun --show-sdk-path (Xcode/CLT, last resort)
if [[ -z "${_macos_syslibroot:-}" ]] && [[ "${_zig_target}" == *-macos* ]]; then
    _auto_sdk=""
    for _cand in \
        "${SDKROOT:-}" \
        "${CONDA_BUILD_SYSROOT:-}" \
        "${CONDA_PREFIX:+${CONDA_PREFIX}/MacOSX.sdk}"; do
        if [[ -d "${_cand:-}" ]]; then
            _auto_sdk="${_cand}"
            break
        fi
    done
    if [[ -z "${_auto_sdk}" ]] && [[ -n "${CONDA_PREFIX:-}" ]]; then
        _auto_sdk=$(_pick_macos_sdk "${CONDA_PREFIX}/MacOSX*.sdk")
        [[ -d "${_auto_sdk:-}" ]] || _auto_sdk=""
    fi
    # Conda-forge GitHub Actions / docker installs SDK at /opt
    if [[ -z "${_auto_sdk}" ]]; then
        _auto_sdk=$(_pick_macos_sdk '/opt/MacOSX*.sdk')
        [[ -d "${_auto_sdk:-}" ]] || _auto_sdk=""
    fi
    if [[ -z "${_auto_sdk}" ]]; then
        _auto_sdk=$(_pick_macos_sdk '/opt/conda/sdks/MacOSX*.sdk')
        [[ -d "${_auto_sdk:-}" ]] || _auto_sdk=""
    fi
    if [[ -z "${_auto_sdk}" ]] && command -v xcrun &>/dev/null; then
        _auto_sdk=$(xcrun --show-sdk-path 2>/dev/null || true)
        [[ -d "${_auto_sdk:-}" ]] || _auto_sdk=""
    fi
    if [[ -n "${_auto_sdk}" ]]; then
        _macos_syslibroot="${_auto_sdk}"
        if [[ ${_is_compile_only} -eq 1 ]]; then
            _syslibroot_flag=("-isysroot" "${_macos_syslibroot}")
        elif (( _use_lld )); then
            _syslibroot_flag=("-isysroot" "${_macos_syslibroot}" "-Wl,-syslibroot,${_macos_syslibroot}")
        fi
    fi
fi

_exec_args=("${_mode}" "${_lld_flag[@]}" "${_target_flag[@]}" "${_mcpu_flag[@]}" "${_sysroot_flags[@]}" "${_syslibroot_flag[@]}" "${_translated_args[@]}" "${_fpreset_stub[@]}")
[[ "${ZIG_DEBUG_SDK:-0}" == 1 ]] && >&2 echo "zig-wrapper SDK: target=${MACOSX_DEPLOYMENT_TARGET:-unset} isysroot_in=${_macos_syslibroot:-unset} syslibroot_flag=${_syslibroot_flag[*]:-unset} use_lld=${_use_lld}"
[[ "${ZIG_DEBUG_SDK:-0}" == 1 ]] && >&2 echo "zig-wrapper FINAL: ${_exec_args[*]}"
