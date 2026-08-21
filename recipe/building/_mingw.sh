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
  # Target arch detection for dlltool machine type and zig cc -target.
  # NOTE: ZIG_TRIPLET is the TARGET triple, NOT a Windows triple -- e.g.
  # "x86_64-macos.11.0-none" on the osx-64 lane, "aarch64-macos.11.0-none"
  # on osx-arm64. Only its ARCH component is used here, which is why the
  # Windows CRT routing below happens to be correct: the arch prefix
  # (x86_64 / aarch64 / x86) coincides between the target triple and the
  # Windows triple we want. Do not assume the rest of ZIG_TRIPLET says
  # anything about Windows.
  _win_arch="${ZIG_TRIPLET%%-*}"
  case "${_win_arch}" in
    x86_64)         _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
    aarch64)        _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
    x86|i386|i686)  _dlltool_machine="i386";         _win_target="x86-windows-gnu" ;;
    *)              _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                    echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
  esac
  if [[ -d "${_mingw_common}" ]]; then
    # Prefer the freshly built zig (${CONDA_TRIPLET}-zig, produced earlier in
    # build.sh) since it carries this recipe's own mingw patches (e.g.
    # mingw-arm64-stubs.patch, mingw-include-setjmp-s.patch). The `-x` +
    # `zig version` exec probe below only confirms the binary CAN run -- it
    # CANNOT detect emulation: on linux-ppc64le CI, GitHub Actions registers
    # qemu-user via binfmt_misc and the foreign-arch fresh zig runs
    # transparently under QEMU; on osx-64, Rosetta does the same. Both make
    # the probe succeed even though execution is emulated (slow). Whether
    # this is a cross build is determined separately below via is_cross()
    # (build_platform vs target_platform, from _common.sh), used only to
    # WARN about the expected emulation slowdown -- NOT to change which zig
    # is selected: the bootstrap zig lacks this recipe's mingw patches, so
    # falling back on cross targets would break the build outright. Fall
    # back to the BUILD machine's bootstrap zig (CONDA_ZIG_BUILD / BUILD_ZIG)
    # only when the fresh binary genuinely cannot execute at all -- resolve
    # via PATH first, then explicit BUILD_PREFIX locations.
    if is_not_unix; then
      _fresh_zig_bin="${PREFIX}/Library/bin/${CONDA_TRIPLET}-zig"
    else
      _fresh_zig_bin="${PREFIX}/bin/${CONDA_TRIPLET}-zig"
    fi
    if [[ -x "${_fresh_zig_bin}" ]] && "${_fresh_zig_bin}" version >/dev/null 2>&1; then
      _zig_bin="${_fresh_zig_bin}"
      echo "INFO: using freshly built zig for mingw CRT cache warm: ${_zig_bin}"
      if is_cross; then
        echo "WARN: build_platform (${build_platform}) != target_platform (${target_platform}) -- the fresh zig is a foreign-arch binary running under emulation (QEMU user-mode via binfmt_misc, or Rosetta on osx). The exec probe above cannot detect this since emulation makes it succeed transparently. Mingw CRT cache-warm links will be SLOW under emulation (observed ~54 min on linux-ppc64le vs ~19 min native); this is expected, not a hang."
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
      echo "INFO: using bootstrap zig for mingw CRT cache warm: ${_zig_bin}"
      echo "WARN: staged mingw CRT archives will derive from the BOOTSTRAP zig's mingw sources, not this recipe's patched tree"
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

    # llvm-ar, discovered the same way as llvm-dlltool above. Required because
    # zig 0.16.0's own `ar` frontend deterministically fails to create archives
    # on the osx-64 lane, where the freshly built x86_64 zig runs under Rosetta
    # on an arm64 host: `ar: error: unable to open '<path>': No such file or
    # directory` on a present, non-empty .o in a writable directory. Verified in
    # CI (PR #143, build 1566883): an identical retry fails, while llvm-ar on the
    # same .o in the same directory succeeds. Falls back to `zig ar` if absent.
    _llvm_ar=""
    for _cand in \
        "${BUILD_PREFIX}/bin/llvm-ar" \
        "${BUILD_PREFIX}/bin/llvm-ar.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-ar.exe" \
        "${BUILD_PREFIX}/Library/bin/llvm-ar" \
        "$(command -v llvm-ar 2>/dev/null || true)"; do
      if [[ -x "${_cand}" ]]; then
        _llvm_ar="${_cand}"
        break
      fi
    done

    dbg echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ==="
    if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
      dbg echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
      _gen_count=0
      _gen_ok=0
      _gen_fail=0
      _gen_skipped=0

      # Pre-generation census: how many .a archives already existed in
      # ${_mingw_common} before any generation ran. Distinguishes "zig's
      # tarball already shipped everything, our loop is a no-op" from "our
      # loop failed to produce anything" -- both show up as generated=0,
      # skipped=N otherwise, with opposite implications. `|| true` guards
      # the pipe under `set -o pipefail` (recipe/build.sh): when the glob
      # matches nothing, `ls` exits non-zero (2) even though `wc -l` itself
      # still succeeds and prints 0, so without `|| true` pipefail would
      # propagate ls's failure and set -e would abort the build. The
      # `+ 0` arithmetic re-normalizes in case `wc -l` pads its output
      # (e.g. leading spaces on some platforms). Plain counter, not a bash
      # array: `${#arr[@]}` on an empty array trips `set -u` under bash 3.2
      # (see _warm_failed_count above).
      _gen_pre=$(ls -1 "${_mingw_common}"/*.a 2>/dev/null | wc -l || true)
      _gen_pre=$(( _gen_pre + 0 ))

      # Helper: generate .a from a processed .def file.
      # Captures dlltool's real exit status (was previously discarded via
      # `2>/dev/null || true`, so a failed dlltool run left no trace beyond
      # the attempt counter). set -e safe: a single failure must not abort
      # the ~800-iteration loop, so the failure branch is handled explicitly
      # rather than left to propagate.
      function _gen_implib() {
        local stem="$1" def="$2"
        local lib="${_mingw_common}/lib${stem}.a"
        if [[ -f "${lib}" ]]; then
          _gen_skipped=$(( _gen_skipped + 1 ))
          return 0
        fi
        local dll
        dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
        [[ -z "${dll}" ]] && dll="${stem}.dll"
        if "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null; then
          _gen_ok=$(( _gen_ok + 1 ))
        else
          _gen_fail=$(( _gen_fail + 1 ))
          echo "WARNING: dlltool failed to generate lib${stem}.a from ${def}" >&2
        fi
        _gen_count=$(( _gen_count + 1 ))
      }

      # Silence xtrace across the import-lib loops below. Each .def costs ~14
      # trace lines (for / [[ -f ]] / basename / the locals inside _gen_implib /
      # awk / dlltool / counter) and there are ~800 .def and .def.in files, so
      # this region alone emits several thousand CI log lines with no diagnostic
      # value: dlltool failures now emit a WARNING each (see _gen_implib above)
      # and the post-loop summaries report the counts. Restored immediately
      # after the loops so Step 5 onward (CRT compile, stub archives -- where
      # the real failures have occurred) stays fully traced.
      _mingw_xt=0
      if [[ "${DEBUG_ZIG_BUILD:-0}" != "1" ]]; then
        case $- in *x*) _mingw_xt=1 ;; esac
        { set +x; } 2>/dev/null
      fi

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
        # Skip include-only fragments (no LIBRARY/EXPORTS; macros defined externally)
        case "${_stem}" in
          ucrtbase-common|vcruntime140-common) continue ;;
        esac
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
        if "${_zig_bin}" cc -target "${_win_target}" -c "${_uuid_src}" \
            -o "${_uuid_obj}" 2>/dev/null && \
          "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null; then
          _gen_ok=$(( _gen_ok + 1 ))
        else
          _gen_fail=$(( _gen_fail + 1 ))
          echo "WARNING: failed to compile/archive libuuid.a from ${_uuid_src}" >&2
        fi
        rm -f "${_uuid_obj}"
        _gen_count=$(( _gen_count + 1 ))
      fi

      dbg echo "=== Generated ${_gen_count} import lib attempts (${_gen_pre} pre-existing, ${_gen_ok} ok, ${_gen_fail} failed, ${_gen_skipped} skipped-present) in ${_mingw_common} [win_arch=${_win_arch}] ==="

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
        dbg echo "=== Supplemental import libs done (${_gen_pre} pre-existing, total ${_gen_count} attempts, ${_gen_ok} ok, ${_gen_fail} failed, ${_gen_skipped} skipped-present) [win_arch=${_win_arch}] ==="
      fi

      if [[ "${_mingw_xt}" == "1" ]]; then { set -x; } 2>/dev/null; fi

      # Post-loop check: a successful dlltool/ar exit does not guarantee a
      # usable archive. Sweep every *.a produced above and flag zero-byte
      # files, which would otherwise ship silently and only surface as an
      # undefined symbol at a downstream Windows link. WARN (not FATAL): each
      # .def covers one specific Windows DLL's API surface out of ~800, most
      # of which a given downstream consumer never links against -- unlike
      # the CRT startup objects and cache-warm libmingw32/libucrt/libmingwex/
      # libwinpthread below (Step 5/6, FATAL at :507-513), which every mingw
      # target unconditionally needs. This subsystem is already best-effort:
      # a totally absent dlltool/zig only WARNs and skips pre-generation
      # entirely (see the final `else` branch of this function), so a single
      # empty import lib among hundreds should not be build-fatal either.
      _gen_empty=0
      for _lib in "${_mingw_common}"/*.a; do
        [[ -f "${_lib}" ]] || continue
        if [[ ! -s "${_lib}" ]]; then
          echo "WARNING: zero-byte import lib: ${_lib}" >&2
          _gen_empty=$(( _gen_empty + 1 ))
        fi
      done
      if [[ "${_gen_empty}" -gt 0 ]]; then
        echo "WARNING: ${_gen_empty} zero-byte import lib(s) in ${_mingw_common}; downstream Windows links referencing these will fail with undefined symbols." >&2
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
        local log; log=$(mktemp)
        if ! "${_zig_bin}" cc -c "${stub_c}" -o "${stub_o}" -target "${target_triple}" >"${log}" 2>&1; then
          echo "ERROR: failed to compile stub object for lib${lib_name}.a (${target_triple}):" >&2
          cat "${log}" >&2
          rm -f "${stub_c}" "${stub_o}" "${log}"
          return 1
        fi
        local _ar_cmd
        if [[ -n "${_llvm_ar}" ]]; then
          _ar_cmd=("${_llvm_ar}")
        else
          _ar_cmd=("${_zig_bin}" ar)
        fi
        if ! "${_ar_cmd[@]}" rcs "${lib_path}" "${stub_o}" >"${log}" 2>&1; then
          echo "ERROR: failed to archive lib${lib_name}.a (${target_triple}):" >&2
          cat "${log}" >&2
          rm -f "${stub_c}" "${stub_o}" "${log}"
          return 1
        fi
        rm -f "${stub_c}" "${stub_o}" "${log}"
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

      # A failed warm iteration used to `continue` with only a WARN, which
      # shipped a package silently missing an entire arch's CRT archives and
      # surfaced downstream as bogus undefined-symbol errors.  Collect failures
      # and fail the build after the loop, so one run reports every bad target.
      # Plain counter + string rather than a bash array: `${#arr[@]}` on an
      # empty array trips `set -u` under bash 3.2.
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
              echo "ERROR: cache-warm link failed for ${_warm_tgt}; no CRT archives can be staged for this arch. Errors:" >&2
              tail -20 "${_warm_cache}/warm.err" >&2 || true
              _warm_failed_count=$((_warm_failed_count + 1))
              _warm_failed_list="${_warm_failed_list}  - ${_warm_tgt} (warm link failed)
"
              continue
          fi

          local _warm_lib
          _warm_lib="$(find "${_warm_cache}" -name 'libmingw32.lib' -print -quit 2>/dev/null)"
          if [[ -z "${_warm_lib}" || ! -f "${_warm_lib}" ]]; then
              echo "ERROR: libmingw32.lib not found in cache for ${_warm_tgt}; no CRT archives can be staged for this arch" >&2
              _warm_failed_count=$((_warm_failed_count + 1))
              _warm_failed_list="${_warm_failed_list}  - ${_warm_tgt} (libmingw32.lib absent from cache)
"
              continue
          fi

          # Size floor: a truncated or zero-byte archive would otherwise be staged as 8
          # empty files and pass silently. Mirrors the 1MB floor in
          # recipe/testing/test_mingw_crt.py, whose invocation is gated `if: xc_w64` and so
          # never runs on non-w64 lanes -- this check covers every lane.
          local _warm_size
          _warm_size="$(wc -c < "${_warm_lib}" 2>/dev/null | tr -d '[:space:]')"
          : "${_warm_size:=0}"
          if [ "${_warm_size}" -lt 1000000 ]; then
              echo "ERROR: libmingw32.lib for ${_warm_tgt} is only ${_warm_size} bytes (expected >1MB); refusing to stage a truncated archive" >&2
              _warm_failed_count=$((_warm_failed_count + 1))
              _warm_failed_list="${_warm_failed_list}  - ${_warm_tgt} (libmingw32.lib truncated: ${_warm_size} bytes)
"
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

      if [ "${_warm_failed_count}" -gt 0 ]; then
          echo "FATAL: mingw CRT cache-warm failed for ${_warm_failed_count} target(s):" >&2
          printf '%s' "${_warm_failed_list}" >&2
          echo "Each failed target ships NO libmingw32/libucrt/libmingwex/libwinpthread" >&2
          echo "archives, which surfaces in downstream consumers as undefined CRT symbols" >&2
          echo "(e.g. 'undefined symbol: wcstold' or a wall of undefined pthread_*)." >&2
          echo "Refusing to produce a package that is missing an entire architecture." >&2
          return 1
      fi

      dbg echo "=== Stub archive generation done ==="

    else
      dbg echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
    fi
  fi
}
