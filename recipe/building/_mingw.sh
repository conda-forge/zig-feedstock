# MinGW import lib pre-generation helpers.
# Source this file and call generate_mingw_import_libs().
# Requires: PREFIX, BUILD_PREFIX, BUILD_ZIG, ZIG_TRIPLET, RECIPE_DIR
# and the dbg() function defined in build.sh.

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_diag.sh"  # diag_fail (idempotent; build-zig.sh already sources this)

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
  # Target arch detection for dlltool machine type and zig cc -target.
  # ZIG_TRIPLET is e.g. "x86_64-windows-gnu" or "aarch64-windows-gnu".
  _win_arch="${ZIG_TRIPLET%%-*}"
  case "${_win_arch}" in
    x86_64)         _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
    aarch64)        _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
    x86|i386|i686)  _dlltool_machine="i386";         _win_target="x86-windows-gnu" ;;
    *)              _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                    echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
  esac
  if [[ -d "${_mingw_common}" ]]; then
    # Prefer the FRESHLY-BUILT zig we are about to ship (installed + renamed by
    # build-zig.sh:750 to "${CONDA_TRIPLET}-zig") so the staged import libs are
    # produced by the zig our own mingw patches govern, not a previously
    # published bootstrap package. CONDA_TRIPLET is the target triplet (set in
    # recipe.yaml env); layout mirrors build-zig.sh's is_not_unix relocation.
    if is_not_unix; then
      _zig_bin_fresh="${PREFIX}/Library/bin/${CONDA_TRIPLET}-zig"
    else
      _zig_bin_fresh="${PREFIX}/bin/${CONDA_TRIPLET}-zig"
    fi

    # Fallback: the BUILD machine's bootstrap zig (CONDA_ZIG_BUILD), needed for
    # cross-compilation targets (e.g. win-arm64 built on win-64) where the
    # freshly-built zig binary is for the wrong architecture and can't execute.
    # BUILD_ZIG is the binary name (not a full path), so resolve via PATH first,
    # then fall back to explicit BUILD_PREFIX locations.
    _zig_bin_boot="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
    if [[ -z "${_zig_bin_boot}" ]]; then
      if is_not_unix; then
        _zig_bin_boot="${BUILD_PREFIX}/Library/bin/${BUILD_ZIG}"
      else
        _zig_bin_boot="${BUILD_PREFIX}/bin/${BUILD_ZIG}"
      fi
    fi

    # Selection gate. A file-mode test ([[ -x ]]) is NOT sufficient: on a cross
    # lane the freshly-built zig is a TARGET-arch ELF that is perfectly
    # executable-mode yet cannot run on this build host. It dies at the dynamic
    # loader (e.g. "libzstd.so.1: cannot open shared object file") and only
    # surfaces far downstream as "failed to compile crt2.o". Probe by actually
    # running it, so this cannot disagree with _can_run_stage3 (build-zig.sh:686),
    # which already skips Phase 2 langref for exactly this reason.
    _tgt_arch="${CONDA_TRIPLET%%-*}"
    _bld_arch="${BUILD_ZIG%%-*}"
    _zig_fresh_ver=""
    _zig_fresh_runs=0
    if [[ -x "${_zig_bin_fresh}" ]] && _zig_fresh_ver="$("${_zig_bin_fresh}" version 2>&1)"; then
      _zig_fresh_runs=1
    fi

    if [[ ${_zig_fresh_runs} -eq 1 ]]; then
      _zig_bin="${_zig_bin_fresh}"
      echo "INFO: [_mingw] cache-warm using FRESHLY-BUILT zig (shipped compiler): ${_zig_bin} (version ${_zig_fresh_ver})" >&2
    else
      _zig_bin="${_zig_bin_boot}"
      if [[ ! -e "${_zig_bin_fresh}" ]]; then
        echo "WARN: [_mingw] freshly-built zig absent at ${_zig_bin_fresh}; cache-warm falling back to BOOTSTRAP zig: ${_zig_bin}" >&2
        diag_fail "cache-warm zig selection" "freshly-built zig missing at ${_zig_bin_fresh}; used bootstrap ${_zig_bin} instead"
      elif [[ "${_tgt_arch}" != "${_bld_arch}" ]]; then
        # EXPECTED on cross lanes: target-arch binary, unrunnable here. Not a
        # defect, so it must NOT enter the diag accumulator -- otherwise every
        # cross lane would report a false failure.
        echo "INFO: [_mingw] freshly-built zig is ${_tgt_arch} and cannot run on this ${_bld_arch} build host (cross lane); cache-warm using BOOTSTRAP zig: ${_zig_bin}" >&2
        echo "INFO: [_mingw] consequence: import libs staged here are NOT produced by the zig our mingw patches govern; that pairing only holds on native lanes." >&2
      else
        # Same arch yet still will not run: the build produced a broken binary.
        echo "WARN: [_mingw] freshly-built zig at ${_zig_bin_fresh} is same-arch (${_tgt_arch}) but failed to execute; cache-warm falling back to BOOTSTRAP zig: ${_zig_bin}" >&2
        diag_fail "cache-warm zig selection" "same-arch freshly-built zig at ${_zig_bin_fresh} failed to run: ${_zig_fresh_ver}; used bootstrap ${_zig_bin} instead"
      fi
    fi
    if [[ -x "${_zig_bin}" ]]; then
      echo "INFO: [_mingw] cache-warm compiler: ${_zig_bin} (version $("${_zig_bin}" version 2>&1 || true))" >&2
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

    dbg echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ==="
    if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
      dbg echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
      _gen_count=0

      # Helper: generate .a from a processed .def file
      function _gen_implib() {
        local stem="$1" def="$2"
        local lib="${_mingw_common}/lib${stem}.a"
        [[ -f "${lib}" ]] && return 0
        local dll
        dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
        [[ -z "${dll}" ]] && dll="${stem}.dll"
        "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
        _gen_count=$(( _gen_count + 1 ))
      }

      # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
      for _def in "${_mingw_common}"/*.def; do
        [[ -f "${_def}" ]] || continue
        _stem="$(basename "${_def%.def}")"
        _gen_implib "${_stem}" "${_def}"
      done

      # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
      # Process through zig's C preprocessor with x86_64 defines so architecture
      # macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
      for _def_in in "${_mingw_common}"/*.def.in; do
        [[ -f "${_def_in}" ]] || continue
        _stem="$(basename "${_def_in%.def.in}")"
        _lib="${_mingw_common}/lib${_stem}.a"
        [[ -f "${_lib}" ]] && continue
        _def="${_mingw_common}/${_stem}.def"
        if [[ ! -f "${_def}" ]]; then
          "${_zig_bin}" cc -E -P \
            -target "${_win_target}" \
            -x assembler-with-cpp \
            -I"${_def_include}" \
            "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
        fi
        _gen_implib "${_stem}" "${_def}"
      done

      # Step 3: uuid -- compiled from C source (no DLL, no import lib needed).
      # zig compiles libsrc/uuid.c into a static archive.
      _uuid_lib="${_mingw_common}/libuuid.a"
      _uuid_src="${_mingw_libsrc}/uuid.c"
      if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
        _uuid_obj="${_mingw_common}/_uuid.o"
        "${_zig_bin}" cc -target "${_win_target}" -c "${_uuid_src}" \
            -o "${_uuid_obj}" 2>/dev/null && \
          "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
        rm -f "${_uuid_obj}"
        _gen_count=$(( _gen_count + 1 ))
      fi

      dbg echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="

      # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
      # Zig doesn't ship msvcrt.def -- we provide a complete mingw-w64 version
      # that covers all exports (stdio, math, POSIX I/O, etc.).
      # msvcrt.def.in uses #include "func.def.in" and #include "crt-aliases.def.in",
      # both of which live in zig's own def-include/.  We also include zig's
      # lib-common/ so any future templates can resolve ucrtbase-common.def.in etc.
      # _supp_defs remains first so pthread.def and msvcrt.def.in are still found.
      _supp_defs="${RECIPE_DIR}/building/mingw-defs"
      if [[ -d "${_supp_defs}" ]]; then
        dbg echo "=== Processing supplemental mingw-w64 .def.in templates ==="
        for _supp_in in "${_supp_defs}"/*.def.in; do
          [[ -f "${_supp_in}" ]] || continue
          _supp_stem="$(basename "${_supp_in%.def.in}")"
          # Skip pure include helpers (not standalone DLL definitions)
          case "${_supp_stem}" in
            func|ucrtbase-common|crt-aliases) continue ;;
          esac
          _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
          [[ -f "${_supp_lib}" ]] && continue
          _supp_def="${_mingw_common}/${_supp_stem}.def"
          if [[ ! -f "${_supp_def}" ]]; then
            "${_zig_bin}" cc -E -P \
              -target "${_win_target}" \
              -x assembler-with-cpp \
              -I"${_supp_defs}" \
              -I"${_def_include}" \
              -I"${_mingw_common}" \
              "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
          fi
          _gen_implib "${_supp_stem}" "${_supp_def}"
        done
        # Also process plain .def files (no preprocessing needed)
        for _supp_def in "${_supp_defs}"/*.def; do
          [[ -f "${_supp_def}" ]] || continue
          _supp_stem="$(basename "${_supp_def%.def}")"
          _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
          [[ -f "${_supp_lib}" ]] && continue
          _gen_implib "${_supp_stem}" "${_supp_def}"
        done
        dbg echo "=== Supplemental import libs done (total ${_gen_count}) ==="
      fi

      # Step 5: arch-specific stubs and CRT output directory routing.
      # aarch64 emits CRT objects into libarm64/ (arch-specific dir, prevents
      # cross-arch contamination); i386 into lib32/; x86_64 keeps lib-common/.
      if [[ "${_win_arch}" == "aarch64" ]]; then
        _mingw_libarm64="${_mingw_common}/../libarm64"
        mkdir -p "${_mingw_libarm64}"
        _crt_outdir="${_mingw_libarm64}"
      elif [[ "${_win_arch}" == "x86" || "${_win_arch}" == "i386" || "${_win_arch}" == "i686" ]]; then
        _mingw_lib32="${_mingw_common}/../lib32"
        mkdir -p "${_mingw_lib32}"
        _crt_outdir="${_mingw_lib32}"
      else
        _crt_outdir="${_mingw_common}"
      fi

      # Pre-compile MinGW CRT startup objects.
      # Consumers explicitly link crt2.o (console exe), crt2win.o (GUI exe),
      # and dllcrt2.o (DLL) as the first object file.  Zig compiles these
      # internally, but flexlink searches for them on disk via -print-search-dirs
      # paths.  Compile from zig's bundled MinGW CRT sources.
      _mingw_crt="${_mingw_common}/../crt"
      _mingw_inc="${_mingw_common}/../include"
      _win_inc="${_zig_lib}/libc/include/any-windows-any"

      if [[ -d "${_mingw_crt}" ]]; then
        dbg echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} -> ${_crt_outdir} ==="
        dbg echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="

        # Diagnostic: confirm both header search roots exist in the installed tree
        # before the CRT compiles depend on them. Informational only, never fatal.
        for _inc_probe in "${_win_inc}" "${_mingw_inc}"; do
          if [[ -d "${_inc_probe}" ]]; then
            echo "INFO: [_mingw] include root present: ${_inc_probe} ($(ls -1 "${_inc_probe}" 2>/dev/null | wc -l) entries)"
          else
            echo "WARN: [_mingw] include root MISSING: ${_inc_probe}" >&2
          fi
        done
        if [[ -f "${_win_inc}/crtdefs.h" ]]; then
          echo "INFO: [_mingw] crtdefs.h resolved at ${_win_inc}/crtdefs.h"
        else
          echo "WARN: [_mingw] crtdefs.h NOT present at ${_win_inc}/crtdefs.h" >&2
        fi

        # ZIGDIAG[mingw-incdir]: full listing of the SMALL include root.
        # Round-20 established that the -cc1 -v search list is CORRECT and that
        # any-windows-any is on it carrying crtdefs.h, yet clang still fails with
        #   cannot open file '<mingw_inc>/crtdefs.h': No such file or directory
        # That is a resolved-then-failed-open, not a search miss. Entry COUNTS
        # alone (the loop above) cannot reveal a broken symlink or an unreadable
        # entry, so list the directory itself. Only _mingw_inc is listed in full:
        # any-windows-any holds ~1463 entries and would flood the log.
        echo "ZIGDIAG[mingw-incdir]: ls -la ${_mingw_inc}"
        ls -la "${_mingw_inc}" 2>&1 | sed 's/^/ZIGDIAG[mingw-incdir]: /' || true
        echo "ZIGDIAG[mingw-incdir]: realpath = $(readlink -f "${_mingw_inc}" 2>/dev/null || echo '(unresolvable)')"

        # ZIGDIAG[crtdefs]: per-directory verdict for crtdefs.h. Distinguishes the
        # states that a bare `-f` test collapses into one: absent, present+readable,
        # present-but-unreadable, and BROKEN SYMLINK (-L true, -e false). The last
        # is the only state that explains a successful existence probe followed by
        # a failed open, which is exactly the observed failure signature.
        for _cd_dir in "${_mingw_inc}" "${_win_inc}"; do
          _cd="${_cd_dir}/crtdefs.h"
          if [[ -L "${_cd}" && ! -e "${_cd}" ]]; then
            echo "ZIGDIAG[crtdefs]: BROKEN SYMLINK ${_cd} -> $(readlink "${_cd}" 2>/dev/null)" >&2
          elif [[ -L "${_cd}" ]]; then
            echo "ZIGDIAG[crtdefs]: symlink ${_cd} -> $(readlink "${_cd}" 2>/dev/null) (target exists)"
          elif [[ -f "${_cd}" && -r "${_cd}" ]]; then
            echo "ZIGDIAG[crtdefs]: regular file ${_cd} ($(wc -c <"${_cd}" 2>/dev/null) bytes, readable)"
          elif [[ -e "${_cd}" ]]; then
            echo "ZIGDIAG[crtdefs]: present but NOT a readable regular file: ${_cd}" >&2
          else
            echo "ZIGDIAG[crtdefs]: absent: ${_cd}"
          fi
        done

        # PR #123 round 26: the -I/-isystem mitigation below (added after Azure
        # buildId 1563426) did NOT stop crtdefs.h failing again in buildId 1565080.
        # clang reports a resolved-then-failed-open against <mingw_inc>/crtdefs.h
        # while ZIGDIAG[crtdefs] reports it ABSENT there. Rather than permute the
        # search path a third time, make the resolved path real: stage the header
        # where clang already looks. Real mingw-w64 ships crtdefs.h in its include
        # root; zig is the outlier for keeping it only under any-windows-any.
        if [[ ! -e "${_mingw_inc}/crtdefs.h" && -f "${_win_inc}/crtdefs.h" ]]; then
          if cp -f "${_win_inc}/crtdefs.h" "${_mingw_inc}/crtdefs.h"; then
            echo "  [_mingw] staged crtdefs.h into ${_mingw_inc} (from ${_win_inc})"
          else
            echo "WARN: [_mingw] failed to stage crtdefs.h into ${_mingw_inc}" >&2
          fi
        fi

        # CRT compile flags must match zig's internal addCrtCcArgs (src/libs/mingw.zig)
        # exactly, otherwise oscalls.h and other internal headers reject inclusion via
        # `#error ERROR: Use of C runtime library internal header file.`. Keep this in
        # lockstep with upstream zig's addCcArgs+addCrtCcArgs flag set: -isystem
        # any-windows-any right after -D__USE_MINGW_ANSI_STDIO=0, THEN the CRT -D flags,
        # THEN -I mingw/include last (verified against zig-0.16.0 src/libs/mingw.zig
        # addCcArgs/addCrtCcArgs, 2026-08-06).
        #
        # any-windows-any is ALSO listed via -I (in addition to -isystem): a confirmed CI
        # failure (osx-64, Azure buildId 1563426) showed crtdefs.h -- which lives only under
        # libc/include/any-windows-any -- failing to resolve from oscalls.h's
        # `#include <crtdefs.h>`, even though the compiler's own -v search-list dump proved
        # any-windows-any was present in the isystem group. zig cc's own target
        # auto-detection already injects "-isystem .../any-windows-any" ahead of these flags
        # for any windows-gnu target, so our explicit -isystem copy gets clang-deduped away
        # as a "duplicate directory". -I populates a separate, independently-deduped search
        # group (searched before -isystem), giving crtdefs.h a resolution path that survives
        # the isystem-group dedup. The original -isystem copy is kept too, since other
        # windows-gnu cross targets (aarch64/i386) may not get the same auto-detected list.
        _crt_flags=(-target "${_win_target}" -mcpu=baseline -c
                    -std=gnu11
                    -D__USE_MINGW_ANSI_STDIO=0
                    -isystem "${_win_inc}"
                    -D__MSVCRT_VERSION__=0x700
                    -D_CRTBLD
                    -D_SYSCRT=1
                    -D_WIN32_WINNT=0x0f00
                    -DCRTDLL=1
                    -DHAVE_CONFIG_H
                    -I"${_mingw_inc}"
                    -I"${_win_inc}")

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
          echo "  invocation: ${_zig_bin} cc ${_crt_flags[*]} ${extra} ${src} -o ${obj}" >&2
          cat "${log}" >&2
          rm -f "${log}"
          # Diagnostic re-run: -v prints the resolved include search list; -H
          # prints the header-inclusion tree with the FULL resolved path of every
          # header actually opened. Round-20 proved the search list is correct, so
          # -H is the probe that matters: it shows which directory clang committed
          # crtdefs.h to before the open failed. Never fatal, never affects the
          # return code below.
          local vlog; vlog=$(mktemp)
          # shellcheck disable=SC2086
          "${_zig_bin}" cc "${_crt_flags[@]}" ${extra} -v -H "${src}" -o /dev/null >"${vlog}" 2>&1 || true
          echo "  --- diagnostic -v include search dump ---" >&2
          cat "${vlog}" >&2
          echo "  --- end -v dump ---" >&2
          rm -f "${vlog}"
          return 1
        }

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
      else
        dbg echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
      fi

      # Step 6: empty stub archives for libs external consumers expect by convention
      # but zig folds elsewhere (winpthread -> mingw32), uses compiler-rt for
      # (gcc, gcc_eh, ssp), or doesn't provide (stdc++).  These satisfy -lXXX
      # filename checks without symbols; any actual symbol references must be
      # satisfied by other libs the consumer links.
      #
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
        local stub_c="${out_dir}/.zig_${sym_name}_stub.c"
        local stub_o="${out_dir}/.zig_${sym_name}_stub.o"
        printf 'int __zig_%s_stub __attribute__((weak)) = 0;\n' "${sym_name}" > "${stub_c}"
        if ! "${_zig_bin}" cc -c "${stub_c}" -o "${stub_o}" -target "${target_triple}" 2>/dev/null; then
          rm -f "${stub_c}" "${stub_o}"
          return 1
        fi
        if ! "${_zig_bin}" ar rcs "${lib_path}" "${stub_o}" 2>/dev/null; then
          rm -f "${stub_c}" "${stub_o}"
          return 1
        fi
        rm -f "${stub_c}" "${stub_o}"
        dbg echo "[_mingw] stub archive: ${lib_path}"
      }

      dbg echo "=== Generating stub archives for ${_win_target} in ${_crt_outdir} ==="
      # Real archives ship for all three arches now (cache-warm loop below),
      # so only the toolchain convenience libs need empty stubs.
      local _stub_libs=(gcc gcc_eh stdc++ ssp)
      for _stub_lib in "${_stub_libs[@]}"; do
        _create_stub_lib_archive "${_crt_outdir}" "${_win_target}" "${_stub_lib}"
      done

      # Cache-warm + stage real libmingw32.lib for all three Windows targets so
      # non-zig linkers (flexlink, mingw-gcc) can resolve -lmingw32 / -lucrt /
      # -lmingwex / -lwinpthread without falling back to empty stubs. Zig compiles
      # its full mingw source tree into a single ~10MB libmingw32.lib at link time
      # and caches it; we trigger materialization with a real link of a tiny program
      # that references snprintf + pthread_self, then harvest the cached artifact.
      # Each target gets its own ZIG_GLOBAL_CACHE_DIR to avoid cross-arch contamination.
      # Soft-fail on missing libmingw32.lib: WARN + continue (not a hard error).
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

      # Pre-initialize cross-arch staging paths so the multi-target cache-warm loop
      # below can reference them regardless of which arch this function call targets.
      # The if/elif block at lines 205–215 only sets these conditionally per arch.
      : "${_mingw_libarm64:=${_mingw_common}/../libarm64}"
      : "${_mingw_lib32:=${_mingw_common}/../lib32}"

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
          local _warm_rc=0
          ZIG_GLOBAL_CACHE_DIR="${_warm_cache}" \
                  "${_zig_bin}" cc -target "${_warm_tgt}" -pthread \
                  "${_warm_dir}/warm.c" \
                  -o "${_warm_cache}/warm.exe" 2>"${_warm_cache}/warm.err" || _warm_rc=$?
          if [[ ${_warm_rc} -ne 0 ]]; then
              echo "WARN: cache-warm failed for ${_warm_tgt}; skipping stage. Errors:" >&2
              tail -5 "${_warm_cache}/warm.err" >&2 || true
              # Non-fatal skip-and-continue is unchanged; also record it so a real
              # linker error here (e.g. PR #123's swallowed lld-link "unable to
              # automatically import from _fpreset" / "undefined symbol: __setjmp3")
              # surfaces in the end-of-run diag_report instead of only in mid-log WARN.
              diag_fail "cache-warm ${_warm_tgt}" "exit ${_warm_rc}: $(tail -5 "${_warm_cache}/warm.err")"
              continue
          fi

          local _warm_lib
          _warm_lib="$(find "${_warm_cache}" -name 'libmingw32.lib' -print -quit 2>/dev/null)"
          if [[ -z "${_warm_lib}" || ! -f "${_warm_lib}" ]]; then
              echo "WARN: libmingw32.lib not found in cache for ${_warm_tgt}; skipping stage" >&2
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

      dbg echo "=== Stub archive generation done ==="

    else
      dbg echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
    fi
  fi
}
