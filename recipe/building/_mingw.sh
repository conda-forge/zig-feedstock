# MinGW import lib pre-generation helpers.
# Source this file and call generate_mingw_import_libs().
# Requires: PREFIX, BUILD_PREFIX, BUILD_ZIG, ZIG_TRIPLET, RECIPE_DIR
# and the dbg() function defined in build.sh.

source "${RECIPE_DIR}/building/_common.sh"

function generate_mingw_import_libs() {
  # Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
  # libsynchronization.a when cross-compiling to Windows (consumers using -lsynchronization).
  # IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
  # "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name -- it doesn't
  # exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
  # libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
  # Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
  if is_not_unix; then
    _zig_lib="${PREFIX}/Library/lib/zig"
  else
    _zig_lib="${PREFIX}/lib/zig"
  fi
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
  if [[ -d "${_mingw_common}" ]]; then
    cat > "${_mingw_common}/synchronization.def" << 'SYNCHRONIZATION_DEF'
LIBRARY api-ms-win-core-synch-l1-2-0.dll

EXPORTS

DeleteSynchronizationBarrier
EnterSynchronizationBarrier
InitializeConditionVariable
InitializeSynchronizationBarrier
InitOnceBeginInitialize
InitOnceComplete
InitOnceExecuteOnce
InitOnceInitialize
SignalObjectAndWait
Sleep
SleepConditionVariableCS
SleepConditionVariableSRW
WaitOnAddress
WakeAllConditionVariable
WakeByAddressAll
WakeByAddressSingle
WakeConditionVariable
SYNCHRONIZATION_DEF
  fi

  # Pre-generate Windows PE import libraries (.a) from zig's MinGW .def/.def.in files.
  # MinGW consumers call -print-search-dirs to find library search paths, then look
  # for libXXX.a files at those paths.  zig generates import libs internally at link
  # time (cached in ~/.cache/zig/), but consumers need them at a fixed, known location.
  #
  # Two types of source files exist in lib-common/:
  #   .def     -- ready to use directly with dlltool (e.g. shlwapi.def)
  #   .def.in  -- C preprocessor templates that conditionally include exports by
  #              architecture using macros from def-include/func.def.in
  #              (e.g. kernel32.def.in, ws2_32.def.in, ole32.def.in)
  #
  # uuid is special: compiled from libsrc/uuid.c (no DLL import lib needed).
  # Only generates files that are missing; safe to re-run.
  #
  # Lane's own target arch drives dlltool_machine only; import libs are
  # generated for ALL THREE Windows arches via the loop below.
  # NOTE: ZIG_TRIPLET is this lane's TARGET triple, never a Windows triple --
  # e.g. "x86_64-linux-gnu", "aarch64-linux-gnu", "powerpc64le-linux-gnu",
  # "x86_64-macos". Only its ARCH prefix is consumed.
  _win_arch="${ZIG_TRIPLET%%-*}"
  case "${_win_arch}" in
    x86_64)         _dlltool_machine="i386:x86-64" ;;
    aarch64)        _dlltool_machine="arm64" ;;
    x86|i386|i686)  _dlltool_machine="i386" ;;
    *)              _dlltool_machine="i386:x86-64"
                    echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
  esac
  if [[ -d "${_mingw_common}" ]]; then
    # Prefer the freshly built zig: it carries this recipe's mingw patches.
    # Falls back to the BUILD-machine bootstrap only if it cannot execute here.
    if is_not_unix; then
      _fresh_zig_bin="${PREFIX}/Library/bin/${CONDA_TRIPLET}-zig"
    else
      _fresh_zig_bin="${PREFIX}/bin/${CONDA_TRIPLET}-zig"
    fi
    if [[ -x "${_fresh_zig_bin}" ]] && "${_fresh_zig_bin}" version >/dev/null 2>&1; then
      _zig_bin="${_fresh_zig_bin}"
      echo "INFO: using freshly built zig for mingw CRT: ${_zig_bin}"
      if is_cross; then
        echo "WARN: build_platform (${build_platform}) != target_platform (${target_platform}): the fresh zig is a foreign-arch binary running under emulation (Rosetta 2 on osx-arm64, QEMU user-mode via binfmt_misc on linux)."
        echo "WARN: the exec probe above cannot detect this, because emulation makes it succeed transparently."
        echo "WARN: mingw CRT cache-warm links will be SLOW under emulation; this is expected, NOT a hang."
      fi
    else
      _zig_bin="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
      if [[ -z "${_zig_bin}" ]]; then
        if is_not_unix; then
          _zig_bin="${BUILD_PREFIX}/Library/bin/${BUILD_ZIG}"
        else
          _zig_bin="${BUILD_PREFIX}/bin/${BUILD_ZIG}"
        fi
      fi
      echo "INFO: using bootstrap zig for mingw CRT: ${_zig_bin}"
      echo "WARN: staged mingw CRT derives from the BOOTSTRAP zig's unpatched mingw sources"
    fi
    _def_include="${_mingw_common}/../def-include"
    _mingw_libsrc="${_mingw_common}/../libsrc"

    _dlltool=""
    for _cand in \
        "${BUILD_PREFIX}/bin/llvm-dlltool" \
        "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
        "$(command -v llvm-dlltool 2>/dev/null || true)"; do
      if [[ -x "${_cand}" ]]; then
        _dlltool="${_cand}"
        break
      fi
    done

    # zig 0.17's built-in `ar` will not CREATE a new archive on Darwin, so prefer
    # llvm-ar and keep `zig ar` only as a fallback.
    _ar_cmd=()
    for _cand in \
        "${BUILD_PREFIX}/bin/llvm-ar" \
        "${BUILD_PREFIX}/bin/llvm-ar.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-ar.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-ar" \
        "$(command -v llvm-ar 2>/dev/null || true)"; do
      if [[ -x "${_cand}" ]]; then
        _ar_cmd=("${_cand}")
        break
      fi
    done
    [[ ${#_ar_cmd[@]} -eq 0 ]] && _ar_cmd=("${_zig_bin}" ar)

    dbg echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ar=${_ar_cmd[*]} ==="
    if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
      dbg echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
      _gen_count=0

      # Helper: generate .a from a processed .def file into a given output dir.
      # ${_dlltool_machine} is set per-arch by the loop below.
      function _gen_implib() {
        local stem="$1" def="$2" outdir="$3"
        local lib="${outdir}/lib${stem}.a"
        [[ -f "${lib}" ]] && return 0
        local dll
        dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
        [[ -z "${dll}" ]] && dll="${stem}.dll"
        "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
        _gen_count=$(( _gen_count + 1 ))
      }

      # Silence xtrace across the import-lib loops below. Each .def costs ~14
      # trace lines and there are ~800 .def/.def.in files x3 arches, so this
      # region alone would emit tens of thousands of CI log lines with no
      # diagnostic value: dlltool failures are already swallowed by
      # `2>/dev/null || true` and the post-loop summaries report the counts.
      # Restored immediately after the loops so the CRT compile and stub
      # archives -- where the real failures have occurred -- stay fully traced.
      _mingw_xt=0
      if [[ "${DEBUG_ZIG_BUILD:-0}" != "1" ]]; then
        case $- in *x*) _mingw_xt=1 ;; esac
        { set +x; } 2>/dev/null
      fi

      _mingw_libarm64="${_mingw_common}/../libarm64"
      _mingw_lib32="${_mingw_common}/../lib32"

      # Snapshot the original .def file list ONCE, before the per-arch loop:
      # Steps 2/4 below write generated .def files into ${_ia_outdir}, which
      # for the x86_64 pass IS ${_mingw_common}, so a re-glob per pass would
      # let the x86_64 pass poison the aarch64/x86 passes' input.
      _orig_defs=()
      for _def in "${_mingw_common}"/*.def; do
        [[ -f "${_def}" ]] && _orig_defs+=("${_def}")
      done

      # Generate import libs for ALL THREE Windows arches (not just this
      # lane's own arch): the cache-warm loop further down links all three
      # on every lane, so each needs its own arch-correct .def expansion,
      # written to its own dir so arches never reuse each other's .def.
      for _ia_entry in \
          "x86_64|i386:x86-64|x86_64-windows-gnu|${_mingw_common}" \
          "aarch64|arm64|aarch64-windows-gnu|${_mingw_libarm64}" \
          "x86|i386|x86-windows-gnu|${_mingw_lib32}"; do
        IFS='|' read -r _ia_arch _dlltool_machine _ia_target _ia_outdir <<< "${_ia_entry}"
        mkdir -p "${_ia_outdir}"

        # Step 1: plain .def files, from the pre-loop snapshot (not a re-glob
        # -- Steps 2/4 write generated .def files into ${_mingw_common} too).
        if [[ ${#_orig_defs[@]} -gt 0 ]]; then
          for _def in "${_orig_defs[@]}"; do
            _stem="$(basename "${_def%.def}")"
            _gen_implib "${_stem}" "${_def}" "${_ia_outdir}"
          done
        fi

        # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
        # Preprocessed per arch so F_I386/F_NON_ARM64/F64-style macros expand
        # to this arch's exports.
        for _def_in in "${_mingw_common}"/*.def.in; do
          [[ -f "${_def_in}" ]] || continue
          _stem="$(basename "${_def_in%.def.in}")"
          _lib="${_ia_outdir}/lib${_stem}.a"
          [[ -f "${_lib}" ]] && continue
          _def="${_ia_outdir}/${_stem}.def"
          if [[ ! -f "${_def}" ]]; then
            "${_zig_bin}" cc -E -P \
              -target "${_ia_target}" \
              -x assembler-with-cpp \
              -I"${_def_include}" \
              "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
          fi
          _gen_implib "${_stem}" "${_def}" "${_ia_outdir}"
        done

        # Step 3: uuid -- compiled from C source (no DLL, no import lib needed).
        # zig compiles libsrc/uuid.c into a static archive.
        _uuid_lib="${_ia_outdir}/libuuid.a"
        _uuid_src="${_mingw_libsrc}/uuid.c"
        if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
          _uuid_obj="${_ia_outdir}/_uuid.o"
          "${_zig_bin}" cc -target "${_ia_target}" -c "${_uuid_src}" \
              -o "${_uuid_obj}" 2>/dev/null && \
            "${_ar_cmd[@]}" rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
          rm -f "${_uuid_obj}"
          _gen_count=$(( _gen_count + 1 ))
        fi

        dbg echo "=== [${_ia_arch}] import libs so far: ${_gen_count} (in ${_ia_outdir}) ==="

        # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
        # Zig doesn't ship msvcrt.def -- we provide a complete mingw-w64 version
        # that covers all exports (stdio, math, POSIX I/O, etc.).
        # msvcrt.def.in uses #include "func.def.in" and #include "crt-aliases.def.in",
        # both of which live in zig's own def-include/.  We also include zig's
        # lib-common/ so any future templates can resolve ucrtbase-common.def.in etc.
        _supp_defs="${RECIPE_DIR}/building/mingw-defs"
        if [[ -d "${_supp_defs}" ]]; then
          dbg echo "=== [${_ia_arch}] processing supplemental mingw-w64 .def.in templates ==="
          for _supp_in in "${_supp_defs}"/*.def.in; do
            [[ -f "${_supp_in}" ]] || continue
            _supp_stem="$(basename "${_supp_in%.def.in}")"
            # Skip pure include helpers (not standalone DLL definitions)
            case "${_supp_stem}" in
              func|ucrtbase-common|crt-aliases) continue ;;
            esac
            _supp_lib="${_ia_outdir}/lib${_supp_stem}.a"
            [[ -f "${_supp_lib}" ]] && continue
            _supp_def="${_ia_outdir}/${_supp_stem}.def"
            if [[ ! -f "${_supp_def}" ]]; then
              "${_zig_bin}" cc -E -P \
                -target "${_ia_target}" \
                -x assembler-with-cpp \
                -I"${_supp_defs}" \
                -I"${_def_include}" \
                -I"${_mingw_common}" \
                "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
            fi
            _gen_implib "${_supp_stem}" "${_supp_def}" "${_ia_outdir}"
          done
          # Also process plain .def files (no preprocessing needed)
          for _supp_def in "${_supp_defs}"/*.def; do
            [[ -f "${_supp_def}" ]] || continue
            _supp_stem="$(basename "${_supp_def%.def}")"
            _supp_lib="${_ia_outdir}/lib${_supp_stem}.a"
            [[ -f "${_supp_lib}" ]] && continue
            _gen_implib "${_supp_stem}" "${_supp_def}" "${_ia_outdir}"
          done
          dbg echo "=== [${_ia_arch}] supplemental import libs done (total ${_gen_count}) ==="
        fi
      done

      dbg echo "=== Generated ${_gen_count} import libs total across x86_64+aarch64+x86 ==="

      if [[ "${_mingw_xt}" == "1" ]]; then { set -x; } 2>/dev/null; fi

      # Steps 5+6: CRT startup objects and stub archives, emitted for all
      # three Windows arches (same map as the cache-warm loop below).
      _mingw_crt="${_mingw_common}/../crt"
      _mingw_inc="${_mingw_common}/../include"
      _win_inc="${_zig_lib}/libc/include/any-windows-any"
      _mingw_crt_exists=0
      if [[ -d "${_mingw_crt}" ]]; then
        _mingw_crt_exists=1
        dbg echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="
      else
        dbg echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
      fi

      # Helper: compile one CRT object, surface errors (do NOT swallow).
      # Captures stderr to a log; on success emits dbg trace; on failure
      # prints log to stderr and returns 1 to abort import-lib generation.
      _compile_crt_obj() {
        local src="$1" obj="$2" extra="${3:-}"
        local log; log=$(mktemp)
        # shellcheck disable=SC2086
        if "${_zig_bin}" cc "${_crt_flags[@]}" ${extra} "${src}" -o "${obj}" >"${log}" 2>&1; then
          dbg cat "${log}"
          dbg echo "=== Compiled $(basename "${obj}") ==="
          rm -f "${log}"
          return 0
        fi
        echo "ERROR: failed to compile $(basename "${obj}") for ${_win_target}:" >&2
        cat "${log}" >&2
        rm -f "${log}"
        return 1
      }

      # Helper: compile a one-symbol weak C stub and archive it.
      # Args: out_dir  target_triple  lib_name
      _create_stub_lib_archive() {
        local out_dir="$1"
        local target_triple="$2"
        local lib_name="$3"
        local lib_path="${out_dir}/lib${lib_name}.a"
        [[ -f "${lib_path}" ]] && return 0
        # Sanitize lib_name to a valid C identifier (replace +, -, . with _)
        local sym_name
        sym_name="$(printf '%s' "${lib_name}" | tr -c 'a-zA-Z0-9_' '_')"
        local stub_base=".zig_${sym_name}_stub"
        local stub_c="${out_dir}/${stub_base}.c"
        local stub_o="${out_dir}/${stub_base}.o"
        local stub_log="${out_dir}/${stub_base}.log"
        printf 'int __zig_%s_stub __attribute__((weak)) = 0;\n' "${sym_name}" > "${stub_c}"
        # zig's depfile parser rejects unescaped backslashes in Windows build
        # roots; fail over abs -> rel -> member-less archive.
        local stub_mode
        if "${_zig_bin}" cc -c "${stub_c}" -o "${stub_o}" -target "${target_triple}" 2>"${stub_log}"; then
          stub_mode="abs"
        elif ( cd "${out_dir}" && "${_zig_bin}" cc -c "${stub_base}.c" -o "${stub_base}.o" -target "${target_triple}" ) 2>>"${stub_log}"; then
          stub_mode="rel"
        else
          stub_mode="empty"
        fi
        if [[ "${stub_mode}" == "empty" ]]; then
          echo "WARNING: [_mingw] stub compile failed for lib${lib_name}.a (${target_triple}); using member-less archive" >&2
          cat "${stub_log}" >&2 || true
          if ! "${_ar_cmd[@]}" rcs "${lib_path}" 2>>"${stub_log}"; then
            echo "ERROR: [_mingw] failed to archive ${lib_path} (${target_triple}):" >&2
            cat "${stub_log}" >&2 || true
            rm -f "${stub_c}" "${stub_o}" "${stub_log}"
            return 1
          fi
        elif ! "${_ar_cmd[@]}" rcs "${lib_path}" "${stub_o}" 2>>"${stub_log}"; then
          echo "ERROR: [_mingw] failed to archive ${lib_path} (${target_triple}):" >&2
          cat "${stub_log}" >&2 || true
          rm -f "${stub_c}" "${stub_o}" "${stub_log}"
          return 1
        fi
        echo "INFO: [_mingw] stub archive: ${lib_path} (mode=${stub_mode})" >&2
        rm -f "${stub_c}" "${stub_o}" "${stub_log}"
      }

      for _crt_entry in \
          "x86_64-windows-gnu:${_mingw_common}" \
          "aarch64-windows-gnu:${_mingw_libarm64}" \
          "x86-windows-gnu:${_mingw_lib32}"; do
        _win_target="${_crt_entry%%:*}"
        _crt_outdir="${_crt_entry##*:}"
        mkdir -p "${_crt_outdir}"

        # CRT compile flags must match zig's internal addCrtCcArgs (src/libs/mingw.zig)
        # exactly, otherwise oscalls.h and other internal headers reject inclusion via
        # `#error ERROR: Use of C runtime library internal header file.`. Keep this in
        # lockstep with upstream zig's addCcArgs+addCrtCcArgs flag set.
        _crt_flags=(-target "${_win_target}" -mcpu=baseline -c
                    -std=gnu11
                    -D__USE_MINGW_ANSI_STDIO=0
                    -D__MSVCRT_VERSION__=0x700
                    -D_CRTBLD
                    -D_SYSCRT=1
                    -D_WIN32_WINNT=0x0f00
                    -DCRTDLL=1
                    -DHAVE_CONFIG_H
                    -isystem "${_win_inc}"
                    -I"${_mingw_inc}")

        if [[ "${_mingw_crt_exists}" == "1" ]]; then
          dbg echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} -> ${_crt_outdir} (${_win_target}) ==="

          # crt2.o -- console application entry (main)
          _crt2_obj="${_crt_outdir}/crt2.o"
          if [[ ! -f "${_crt2_obj}" ]] && [[ -f "${_mingw_crt}/crtexe.c" ]]; then
            _compile_crt_obj "${_mingw_crt}/crtexe.c" "${_crt2_obj}" || return 1
          fi

          # crt2win.o -- GUI application entry (WinMain)
          _crt2win_obj="${_crt_outdir}/crt2win.o"
          if [[ ! -f "${_crt2win_obj}" ]] && [[ -f "${_mingw_crt}/crtexewin.c" ]]; then
            _compile_crt_obj "${_mingw_crt}/crtexewin.c" "${_crt2win_obj}" "-D_WINDOWS" || return 1
          fi

          # dllcrt2.o -- DLL entry (DllMain)
          _dllcrt2_obj="${_crt_outdir}/dllcrt2.o"
          if [[ ! -f "${_dllcrt2_obj}" ]] && [[ -f "${_mingw_crt}/crtdll.c" ]]; then
            _compile_crt_obj "${_mingw_crt}/crtdll.c" "${_dllcrt2_obj}" || return 1
          fi
        fi

        dbg echo "=== Generating stub archives for ${_win_target} in ${_crt_outdir} ==="
        # Real archives ship for all three arches now (cache-warm loop below),
        # so only the toolchain convenience libs need empty stubs.
        local _stub_libs=(gcc gcc_eh stdc++ ssp)
        for _stub_lib in "${_stub_libs[@]}"; do
          _create_stub_lib_archive "${_crt_outdir}" "${_win_target}" "${_stub_lib}"
        done
      done

      # Cache-warm + stage real libmingw32.lib for all three Windows targets so
      # non-zig linkers (flexlink, mingw-gcc) can resolve -lmingw32 / -lucrt /
      # -lmingwex / -lwinpthread without falling back to empty stubs. Zig compiles
      # its full mingw source tree into a single ~10MB libmingw32.lib at link time
      # and caches it; we trigger materialization with a real link of a tiny program
      # that references snprintf + pthread_self, then harvest the cached artifact.
      # Each target gets its own ZIG_GLOBAL_CACHE_DIR to avoid cross-arch contamination.
      # Failures are recorded per target and aggregated; if ANY target fails,
      # the function fails after the loop (see the FATAL check below).

      # Bootstrap zig's bundled setjmp.h still marks _setjmp/_setjmp3 dllimport; the
      # recipe patch only fixes the zig we ship, not the one we link warm.c with.
      _bp_setjmp="${BUILD_PREFIX}/lib/zig/libc/include/any-windows-any/setjmp.h"
      [[ -f "${_bp_setjmp}" ]] || _bp_setjmp="${BUILD_PREFIX}/Library/lib/zig/libc/include/any-windows-any/setjmp.h"
      if [[ -f "${_bp_setjmp}" ]]; then
        if grep -qE '^_CRTIMP int __cdecl .*_setjmp3?\(' "${_bp_setjmp}"; then
          sed -i.zigbak -E 's/^_CRTIMP( int __cdecl .*_setjmp3?\()/\1/' "${_bp_setjmp}"
          dbg echo "[_mingw] stripped _CRTIMP from bootstrap setjmp.h: ${_bp_setjmp}"
        fi
      else
        echo "WARN: [_mingw] bootstrap setjmp.h not found; warm link may fail on _setjmp3" >&2
      fi

      local _warm_dir
      _warm_dir="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/zig-warm-$$")"
      mkdir -p "${_warm_dir}"
      cat > "${_warm_dir}/warm.c" <<'WARM_EOF'
#include <stdio.h>
#include <pthread.h>
int main(void) {
    char b[8]; (void)snprintf(b, 8, "%d", 0);
    pthread_t t = pthread_self(); (void)t;
    return 0;
}
WARM_EOF

      # ${_mingw_libarm64}/${_mingw_lib32} are already set unconditionally by
      # the import-lib generation loop above, ahead of any arch branching.

      # Aggregate cache-warm failures so a Windows arch whose CRT archives go
      # missing fails the build loudly instead of shipping silently.
      local _warm_failed_count=0
      local _warm_failed_list=""

      # Map: zig target triple -> staging dir name under lib/libc/mingw/
      for _warm_pair in \
          "x86_64-windows-gnu:${_mingw_common}" \
          "aarch64-windows-gnu:${_mingw_libarm64}" \
          "x86-windows-gnu:${_mingw_lib32}"; do
          _warm_tgt="${_warm_pair%%:*}"
          _warm_stage="${_warm_pair##*:}"
          _warm_cache="${_warm_dir}/cache-${_warm_tgt}"
          rm -rf "${_warm_cache}"
          mkdir -p "${_warm_cache}"

          # Real link (NOT -c compile-only) to force libmingw32 materialization.
          if ! ZIG_GLOBAL_CACHE_DIR="${_warm_cache}" \
                  "${_zig_bin}" cc -target "${_warm_tgt}" -pthread \
                  "${_warm_dir}/warm.c" \
                  -o "${_warm_cache}/warm.exe" 2>"${_warm_cache}/warm.err"; then
              echo "ERROR: cache-warm link failed for ${_warm_tgt}; CRT archives will be missing. Errors:" >&2
              tail -5 "${_warm_cache}/warm.err" >&2 || true
              _warm_failed_count=$((_warm_failed_count + 1))
              _warm_failed_list="${_warm_failed_list} ${_warm_tgt}(link)"
              continue
          fi

          local _warm_lib
          _warm_lib="$(find "${_warm_cache}" -name 'libmingw32.lib' -print -quit 2>/dev/null)"
          if [[ -z "${_warm_lib}" || ! -f "${_warm_lib}" ]]; then
              echo "ERROR: libmingw32.lib not found in cache for ${_warm_tgt}; CRT archives will be missing" >&2
              _warm_failed_count=$((_warm_failed_count + 1))
              _warm_failed_list="${_warm_failed_list} ${_warm_tgt}(no-libmingw32)"
              continue
          fi

          mkdir -p "${_warm_stage}"
          # Stage under conventional library names + both .lib (Windows MSVC) and
          # .a (Unix toolchain) extensions so consumers spelling -lucrt /
          # -lmingwex / -lwinpthread all resolve to the single zig-built archive.
          # DO NOT overwrite libpthread.a — it's the 2KB import lib for
          # libwinpthread-1.dll; overwriting would silently switch consumers from
          # dynamic to static threading runtime.
          local _name
          for _name in libmingw32 libucrt libmingwex libwinpthread; do
              cp -f "${_warm_lib}" "${_warm_stage}/${_name}.lib"
              cp -f "${_warm_lib}" "${_warm_stage}/${_name}.a"
          done
          dbg echo "[_mingw] staged libmingw32+aliases for ${_warm_tgt} under ${_warm_stage}"
      done

      rm -rf "${_warm_dir}"

      # Fail loudly rather than shipping a zig_impl whose libarm64/ or lib32/
      # CRT archives are silently absent -- that is the published-build-10
      # failure mode, and it surfaces downstream at LINK time for win-arm64 /
      # win-32 consumers rather than here.
      if [[ "${_warm_failed_count}" -gt 0 ]]; then
        echo "FATAL: ${_warm_failed_count} Windows target(s) failed to cache-warm:${_warm_failed_list}" >&2
        return 1
      fi

      dbg echo "=== Stub archive generation done ==="

    else
      dbg echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
    fi
  fi
}
