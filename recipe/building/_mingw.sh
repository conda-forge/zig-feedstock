# MinGW import lib pre-generation helpers.
# Source this file and call generate_mingw_import_libs().
# Requires: PREFIX, BUILD_PREFIX, BUILD_ZIG, ZIG_TRIPLET, RECIPE_DIR
# and the dbg() function defined in build.sh.

generate_mingw_import_libs() {
  # Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
  # libsynchronization.a when cross-compiling to Windows (consumers using -lsynchronization).
  # IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
  # "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name -- it doesn't
  # exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
  # libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
  # Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
  if is_not_unix; then
    _zig_lib="${PREFIX}/Library/lib/zig"
    _mingw_common="${_zig_lib}/libc/mingw/lib-common"
  else
    _zig_lib="${PREFIX}/lib/zig"
    _mingw_common="${_zig_lib}/libc/mingw/lib-common"
  fi
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
    x86_64)       _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
    aarch64)      _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
    *)            _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                  echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
  esac
  if [[ -d "${_mingw_common}" ]]; then
    # Use the BUILD machine's zig binary (CONDA_ZIG_BUILD) so this works even
    # for cross-compilation targets (e.g. win-arm64 built on win-64) where the
    # installed zig binary is for the wrong architecture and can't execute.
    # BUILD_ZIG is the binary name (not a full path), so resolve via PATH first,
    # then fall back to explicit BUILD_PREFIX locations.
    _zig_bin="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
    if [[ -z "${_zig_bin}" ]]; then
      if is_not_unix; then
        _zig_bin="${BUILD_PREFIX}/Library/bin/${BUILD_ZIG}"
      else
        _zig_bin="${BUILD_PREFIX}/bin/${BUILD_ZIG}"
      fi
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
      # Zig doesn't ship msvcrt.def or ucrtbase.def -- we provide complete
      # mingw-w64 versions that cover all exports (stdio, math, POSIX I/O, etc.).
      # These use #include "func.def.in" for arch macros, so -I must point to
      # our mingw-defs/ directory (NOT zig's def-include/).
      _supp_defs="${RECIPE_DIR}/building/mingw-defs"
      if [[ -d "${_supp_defs}" ]]; then
        dbg echo "=== Processing supplemental mingw-w64 .def.in templates ==="
        for _supp_in in "${_supp_defs}"/*.def.in; do
          [[ -f "${_supp_in}" ]] || continue
          _supp_stem="$(basename "${_supp_in%.def.in}")"
          # Skip support files (included by other .def.in, not standalone libs)
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

      # Step 5: ARM64 intrinsic stubs (only for aarch64-windows-gnu).
      # Sets _crt_outdir for the subsequent CRT object compilation block:
      # aarch64 emits CRT objects into libarm64/ (arch-specific dir, prevents
      # cross-arch contamination); other archs keep historical lib-common/.
      if [[ "${_win_arch}" == "aarch64" ]]; then
        _mingw_libarm64="${_mingw_common}/../libarm64"
        mkdir -p "${_mingw_libarm64}"
        source "${RECIPE_DIR}/building/_win_arm64_stubs.sh"
        create_win_arm64_stubs "${_zig_bin}" "${_win_target}" "${_mingw_libarm64}"
        _crt_outdir="${_mingw_libarm64}"
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

    else
      dbg echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
    fi
  fi
}
