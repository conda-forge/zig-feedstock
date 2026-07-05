# Force-load helper for zig cc/c++ on macOS — vendored into zig-llvm.
#
# Background: upstream conda-forge zig 0.15.2 build 27 installs
# bin/${CONDA_TRIPLET}-zig-force-load-cc/-cxx as copies of the compiled
# zig-wrapper.c binary, but that binary's detect_mode() lacks cases for
# the `-force-load-cc`/`-force-load-cxx` basename suffixes (it only has
# cc/cxx/c++/asm/ar/ranlib/lld/rc) — so invocation errors with
# `zig-wrapper: cannot determine mode from basename(...)` and exits 1.
# The wrapper also has no archive-extraction logic; it would only inject
# -fuse-ld=lld which doesn't help since zig's MachO ld64 rejects
# -Wl,-all_load and -Wl,-force_load,<archive> as unknown linker args.
#
# This shim intercepts those flags BEFORE handing off to the upstream
# wrapper. It extracts .o members from each force-loaded archive into a
# per-archive tmpdir, strips the force-load directives + bare .a paths
# (when -all_load was set) from the argv, and execs the upstream
# wrapper (which still handles -target/-mcpu injection correctly) with
# the modified argv + extracted .o files appended.
#
# Expects caller to set: _ZIG_MODE ("cc" or "c++")
# Expects environment to provide: BUILD_PREFIX, CONDA_ZIG_BUILD

case "${_ZIG_MODE}" in
  cc)  _zig_target_bin="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"  ;;
  c++) _zig_target_bin="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx" ;;
  *)
    echo "zig-force-load: unknown _ZIG_MODE='${_ZIG_MODE}'" >&2
    exit 1
    ;;
esac

if [[ ! -x "${_zig_target_bin}" ]]; then
  echo "zig-force-load: target binary not executable: ${_zig_target_bin}" >&2
  exit 1
fi

# Use raw argv as the exec baseline. cmake passes -isysroot, -arch, library
# paths, etc. directly. The upstream wrapper will inject -target/-mcpu in
# CC/CXX mode. We do not need _zig-cc-common.sh's sysroot/flag work.
_exec_args=("$@")

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

# Fast path: if no force-load flags, exec upstream wrapper directly.
if [[ ${_all_load} -eq 0 ]] && [[ ${#_force_load_archives[@]} -eq 0 ]]; then
    # Override any caller-supplied -target / --target=… by appending ours last
    # (zig CLI: last -target wins). Required for cross-builds where the upstream
    # BUILD wrapper bakes in -target ${ZIG_TARGET_BUILD} and cmake may inject
    # --target=<LLVM-format> (e.g. x86_64-apple-darwin) which zig rejects.
    # On native (BUILD==TARGET) this is a harmless no-op.
    _exec_args+=( -target "${ZIG_TARGET_HOST}" )
    exec "${_zig_target_bin}" "${_exec_args[@]}"
fi

# Collect archives to extract.
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

# Dedupe archives by basename.
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

# Extract .o files. Dedup scoped to (archive, basename): cross-archive same-name
# objects are intentionally kept (LLVM has many Driver.cpp.o / Error.cpp.o
# duplicates across archives — dropping them silently corrupts the link).
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
            _obase="$(basename "${_obj}")"
            _dedup_key="${_arch_base}:${_obase}"
            case " ${_seen_objs} " in
                *" ${_dedup_key} "*) ;;
                *) _extracted_objects+=("$_obj"); _seen_objs="${_seen_objs} ${_dedup_key}" ;;
            esac
        done
        ((_idx++))
    done
fi

# Strip force-load directives and (if -all_load was set) bare .a paths from
# _exec_args. Leaving those in causes the linker to force-load the archives
# a second time on top of the already-extracted .o set → duplicate symbols.
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
                :  # drop — extracted contents already in _extracted_objects
            else
                _final_exec_args+=("$_ea")
            fi
            ;;
        *) _final_exec_args+=("$_ea") ;;
    esac
done

# Override any caller-supplied -target / --target=… by appending ours last
# (zig CLI: last -target wins). Required for cross-builds where the upstream
# BUILD wrapper bakes in -target ${ZIG_TARGET_BUILD} and cmake may inject
# --target=<LLVM-format> (e.g. x86_64-apple-darwin) which zig rejects.
# On native (BUILD==TARGET) this is a harmless no-op.
_final_exec_args+=( -target "${ZIG_TARGET_HOST}" )
exec "${_zig_target_bin}" "${_final_exec_args[@]}" "${_extracted_objects[@]}"
