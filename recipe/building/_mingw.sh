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

  # Canonical Windows-arch table for import-lib generation (Step 1/2/4 below).
  # Which Windows arch's implibs we generate has nothing to do with this
  # lane's target arch (_win_arch above) -- consumers need all three.
  # Fields: winarch|dlltool_machine|target_triple. NOTE: '|' delimiter --
  # the x86_64 dlltool machine string "i386:x86-64" contains a colon, so
  # ':' cannot be used to split fields here.
  _mingw_arch_specs=(
    "x86_64|i386:x86-64|x86_64-windows-gnu"
    "aarch64|arm64|aarch64-windows-gnu"
    "x86|i386|x86-windows-gnu"
  )

  if [[ -d "${_mingw_common}" ]]; then
    # Per-arch output dirs, hoisted here (previously set inside Step 5 and
    # re-defaulted before Step 6) so Steps 1/2/4 can write straight into the
    # correct arch dir instead of always writing lib-common.
    _mingw_libarm64="${_mingw_common}/../libarm64"
    _mingw_lib32="${_mingw_common}/../lib32"
    mkdir -p "${_mingw_libarm64}" "${_mingw_lib32}"
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

    # Preferred archiver: llvm-ar if found, else fall back to `zig ar`.
    # Hoisted here (was local to _create_stub_lib_archive) so the uuid
    # archive step (Step 3) shares the same osx-64/Rosetta workaround.
    if [[ -n "${_llvm_ar}" ]]; then
      _ar_cmd=("${_llvm_ar}")
    else
      _ar_cmd=("${_zig_bin}" ar)
    fi

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
        local stem="$1" def="$2" outdir="$3" machine="$4"
        local lib="${outdir}/lib${stem}.a"
        if [[ -f "${lib}" ]]; then
          _gen_skipped=$(( _gen_skipped + 1 ))
          return 0
        fi
        local dll
        dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
        [[ -z "${dll}" ]] && dll="${stem}.dll"
        if "${_dlltool}" -m "${machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null; then
          _gen_ok=$(( _gen_ok + 1 ))
        else
          _gen_fail=$(( _gen_fail + 1 ))
          echo "WARNING: dlltool failed to generate lib${stem}.a from ${def} (machine=${machine})" >&2
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

      # Steps 1/2/4 iterate all three Windows arches: implib generation is
      # independent of this lane's target arch (see _mingw_arch_specs above).
      for _spec in "${_mingw_arch_specs[@]}"; do
        _spec_arch="${_spec%%|*}"
        _spec_rest="${_spec#*|}"
        _spec_machine="${_spec_rest%%|*}"
        _spec_triple="${_spec_rest#*|}"
        case "${_spec_arch}" in
          aarch64) _spec_outdir="${_mingw_libarm64}" ;;
          x86)     _spec_outdir="${_mingw_lib32}" ;;
          *)       _spec_outdir="${_mingw_common}" ;;
        esac

        # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
        # Source .def files are arch-independent (no preprocessing) and shared
        # from lib-common; only the generated .a goes to the per-arch outdir.
        for _def in "${_mingw_common}"/*.def; do
          [[ -f "${_def}" ]] || continue
          _stem="$(basename "${_def%.def}")"
          _gen_implib "${_stem}" "${_def}" "${_spec_outdir}" "${_spec_machine}"
        done

        # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
        # Process through zig's C preprocessor with per-arch defines so
        # architecture macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
        # The preprocessed .def is arch-dependent, so unlike the plain .def
        # files above it is written into the per-arch outdir too, not cached
        # back to lib-common.
        for _def_in in "${_mingw_common}"/*.def.in; do
          [[ -f "${_def_in}" ]] || continue
          _stem="$(basename "${_def_in%.def.in}")"
          # Skip include-only fragments (no LIBRARY/EXPORTS; macros defined externally)
          case "${_stem}" in
            ucrtbase-common|vcruntime140-common) continue ;;
          esac
          _lib="${_spec_outdir}/lib${_stem}.a"
          [[ -f "${_lib}" ]] && continue
          _def="${_spec_outdir}/${_stem}.def"
          if [[ ! -f "${_def}" ]]; then
            "${_zig_bin}" cc -E -P \
              -target "${_spec_triple}" \
              -x assembler-with-cpp \
              -I"${_def_include}" \
              "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
          fi
          _gen_implib "${_stem}" "${_def}" "${_spec_outdir}" "${_spec_machine}"
        done
      done

      # Step 3: uuid -- compiled from C source (no DLL, no import lib needed).
      # Per-arch: the object is COFF, so an x86_64 libuuid.a cannot link into
      # an aarch64 or i386 binary.
      _uuid_src="${_mingw_libsrc}/uuid.c"
      if [[ -f "${_uuid_src}" ]]; then
        for _spec in "${_mingw_arch_specs[@]}"; do
          _spec_arch="${_spec%%|*}"
          _spec_rest="${_spec#*|}"
          _spec_triple="${_spec_rest#*|}"
          case "${_spec_arch}" in
            aarch64) _spec_outdir="${_mingw_libarm64}" ;;
            x86)     _spec_outdir="${_mingw_lib32}" ;;
            *)       _spec_outdir="${_mingw_common}" ;;
          esac
          _uuid_lib="${_spec_outdir}/libuuid.a"
          [[ -f "${_uuid_lib}" ]] && continue
          _uuid_obj="${_spec_outdir}/_uuid.o"
          if "${_zig_bin}" cc -target "${_spec_triple}" -c "${_uuid_src}" \
              -o "${_uuid_obj}" 2>/dev/null && \
            "${_ar_cmd[@]}" rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null; then
            _gen_ok=$(( _gen_ok + 1 ))
          else
            _gen_fail=$(( _gen_fail + 1 ))
            echo "WARNING: failed to compile/archive libuuid.a for ${_spec_triple}" >&2
          fi
          rm -f "${_uuid_obj}"
          _gen_count=$(( _gen_count + 1 ))
        done
      fi

      _gen_common_a=$(ls -1 "${_mingw_common}"/*.a 2>/dev/null | wc -l || true); _gen_common_a=$(( _gen_common_a + 0 ))
      _gen_arm64_a=$(ls -1 "${_mingw_libarm64}"/*.a 2>/dev/null | wc -l || true); _gen_arm64_a=$(( _gen_arm64_a + 0 ))
      _gen_x86_a=$(ls -1 "${_mingw_lib32}"/*.a 2>/dev/null | wc -l || true); _gen_x86_a=$(( _gen_x86_a + 0 ))
      dbg echo "=== Generated ${_gen_count} import lib attempts (${_gen_pre} pre-existing, ${_gen_ok} ok, ${_gen_fail} failed, ${_gen_skipped} skipped-present); per-arch .a counts: x86_64=${_gen_common_a} aarch64=${_gen_arm64_a} x86=${_gen_x86_a} ==="

      # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
      # Zig doesn't ship msvcrt.def -- we provide a complete mingw-w64 version
      # that covers all exports (stdio, math, POSIX I/O, etc.).
      # msvcrt.def.in uses #include "func.def.in" and #include "crt-aliases.def.in",
      # both of which live in zig's own def-include/.  We also include zig's
      # lib-common/ so any future templates can resolve ucrtbase-common.def.in etc.
      # _supp_defs remains first so pthread.def and msvcrt.def.in are still found.
      # Iterates all three Windows arches for the same reason as Step 1/2.
      _supp_defs="${RECIPE_DIR}/building/mingw-defs"
      if [[ -d "${_supp_defs}" ]]; then
        dbg echo "=== Processing supplemental mingw-w64 .def.in templates ==="
        for _spec in "${_mingw_arch_specs[@]}"; do
          _spec_arch="${_spec%%|*}"
          _spec_rest="${_spec#*|}"
          _spec_machine="${_spec_rest%%|*}"
          _spec_triple="${_spec_rest#*|}"
          case "${_spec_arch}" in
            aarch64) _spec_outdir="${_mingw_libarm64}" ;;
            x86)     _spec_outdir="${_mingw_lib32}" ;;
            *)       _spec_outdir="${_mingw_common}" ;;
          esac

          for _supp_in in "${_supp_defs}"/*.def.in; do
            [[ -f "${_supp_in}" ]] || continue
            _supp_stem="$(basename "${_supp_in%.def.in}")"
            # Skip pure include helpers (not standalone DLL definitions)
            case "${_supp_stem}" in
              func|ucrtbase-common|crt-aliases) continue ;;
            esac
            _supp_lib="${_spec_outdir}/lib${_supp_stem}.a"
            [[ -f "${_supp_lib}" ]] && continue
            _supp_def="${_spec_outdir}/${_supp_stem}.def"
            if [[ ! -f "${_supp_def}" ]]; then
              "${_zig_bin}" cc -E -P \
                -target "${_spec_triple}" \
                -x assembler-with-cpp \
                -I"${_supp_defs}" \
                -I"${_def_include}" \
                -I"${_mingw_common}" \
                "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
            fi
            _gen_implib "${_supp_stem}" "${_supp_def}" "${_spec_outdir}" "${_spec_machine}"
          done
          # Also process plain .def files (no preprocessing needed, shared source)
          for _supp_def in "${_supp_defs}"/*.def; do
            [[ -f "${_supp_def}" ]] || continue
            _supp_stem="$(basename "${_supp_def%.def}")"
            _supp_lib="${_spec_outdir}/lib${_supp_stem}.a"
            [[ -f "${_supp_lib}" ]] && continue
            _gen_implib "${_supp_stem}" "${_supp_def}" "${_spec_outdir}" "${_spec_machine}"
          done
        done
        _gen_common_a=$(ls -1 "${_mingw_common}"/*.a 2>/dev/null | wc -l || true); _gen_common_a=$(( _gen_common_a + 0 ))
        _gen_arm64_a=$(ls -1 "${_mingw_libarm64}"/*.a 2>/dev/null | wc -l || true); _gen_arm64_a=$(( _gen_arm64_a + 0 ))
        _gen_x86_a=$(ls -1 "${_mingw_lib32}"/*.a 2>/dev/null | wc -l || true); _gen_x86_a=$(( _gen_x86_a + 0 ))
        dbg echo "=== Supplemental import libs done (${_gen_pre} pre-existing, total ${_gen_count} attempts, ${_gen_ok} ok, ${_gen_fail} failed, ${_gen_skipped} skipped-present); per-arch .a counts: x86_64=${_gen_common_a} aarch64=${_gen_arm64_a} x86=${_gen_x86_a} ==="
      fi

      if [[ "${_mingw_xt}" == "1" ]]; then { set -x; } 2>/dev/null; fi

      # Post-loop check: a successful dlltool/ar exit does not guarantee a
      # usable archive, and per-arch generation must not silently produce
      # nothing for one of the three arches. Sweep every outdir, accumulate
      # failures, then FATAL once -- same accumulate-then-FATAL style as
      # the cache-warm final check below.
      _gen_failed_count=0
      _gen_failed_list=""
      for _gen_pair in \
          "x86_64:${_mingw_common}" \
          "aarch64:${_mingw_libarm64}" \
          "x86:${_mingw_lib32}"; do
        _gen_pair_arch="${_gen_pair%%:*}"
        _gen_pair_dir="${_gen_pair##*:}"
        _gen_arch_empty=0
        _gen_arch_count=0
        for _lib in "${_gen_pair_dir}"/*.a; do
          [[ -f "${_lib}" ]] || continue
          _gen_arch_count=$(( _gen_arch_count + 1 ))
          if [[ ! -s "${_lib}" ]]; then
            echo "WARNING: zero-byte import lib: ${_lib}" >&2
            _gen_arch_empty=$(( _gen_arch_empty + 1 ))
          fi
        done
        if [[ "${_gen_arch_count}" -eq 0 ]]; then
          _gen_failed_count=$(( _gen_failed_count + 1 ))
          _gen_failed_list="${_gen_failed_list}  - ${_gen_pair_arch} (${_gen_pair_dir}): 0 import libs generated
"
        elif [[ "${_gen_arch_empty}" -gt 0 ]]; then
          _gen_failed_count=$(( _gen_failed_count + 1 ))
          _gen_failed_list="${_gen_failed_list}  - ${_gen_pair_arch} (${_gen_pair_dir}): ${_gen_arch_empty} zero-byte import lib(s)
"
        fi

        # Machine-type sanity check: verify a representative generated import
        # lib actually carries the COFF machine type expected for this arch
        # spec (e.g. libarm64/ must contain arm64 code, not a stray x86_64
        # import lib). Soft path: any tooling/parsing problem (helper
        # missing, python3 missing, UNKNOWN result) only WARNs and never
        # fails the build -- CI is the only feedback loop this round and a
        # flaky assertion here would redden every lane. Only a definite,
        # known-vs-known mismatch feeds the existing FATAL counter. Skipped
        # when the dir has no .a at all -- the count check above already
        # reports that case, avoid double-reporting.
        if [[ "${_gen_arch_count}" -gt 0 ]]; then
          case "${_gen_pair_arch}" in
            x86_64)  _gen_expect_machine="x86_64" ;;
            aarch64) _gen_expect_machine="arm64" ;;
            x86)     _gen_expect_machine="i386" ;;
            *)       _gen_expect_machine="" ;;
          esac
          _gen_rep_lib="${_gen_pair_dir}/libkernel32.a"
          if [[ ! -f "${_gen_rep_lib}" ]]; then
            _gen_rep_lib=""
            for _cand_lib in "${_gen_pair_dir}"/*.a; do
              [[ -f "${_cand_lib}" ]] || continue
              _gen_rep_lib="${_cand_lib}"
              break
            done
          fi
          _coff_helper="${RECIPE_DIR}/building/coff_machine.py"
          if [[ -n "${_gen_rep_lib}" ]] && [[ -n "${_gen_expect_machine}" ]]; then
            if command -v python3 >/dev/null 2>&1 && [[ -f "${_coff_helper}" ]]; then
              _gen_actual_machine="$(python3 "${_coff_helper}" "${_gen_rep_lib}" 2>/dev/null | awk '{print $2}')"
              if [[ -z "${_gen_actual_machine}" || "${_gen_actual_machine}" == "UNKNOWN" ]]; then
                echo "WARNING: could not determine machine type of ${_gen_rep_lib} (helper returned '${_gen_actual_machine:-empty}'); skipping machine-type check for ${_gen_pair_arch}" >&2
              elif [[ "${_gen_actual_machine}" != "${_gen_expect_machine}" ]]; then
                _gen_failed_count=$(( _gen_failed_count + 1 ))
                _gen_failed_list="${_gen_failed_list}  - ${_gen_pair_arch} (${_gen_pair_dir}): machine-type mismatch in $(basename "${_gen_rep_lib}"): expected ${_gen_expect_machine}, got ${_gen_actual_machine}
"
              fi
            else
              echo "WARNING: coff_machine.py helper or python3 unavailable; skipping machine-type check for ${_gen_pair_arch} (${_gen_pair_dir})" >&2
            fi
          fi
        fi
      done
      if [[ "${_gen_fail}" -gt 0 ]]; then
        _gen_failed_count=$(( _gen_failed_count + 1 ))
        _gen_failed_list="${_gen_failed_list}  - dlltool reported ${_gen_fail} failure(s) across all arches
"
      fi
      if [[ "${_gen_failed_count}" -gt 0 ]]; then
        echo "FATAL: mingw import-lib generation failed:" >&2
        printf '%s' "${_gen_failed_list}" >&2
        echo "Refusing to produce a package with missing or empty import libs." >&2
        return 1
      fi

      # Step 5: arch-specific stubs and CRT output directory routing.
      # aarch64 emits CRT objects into libarm64/ (arch-specific dir, prevents
      # cross-arch contamination); i386 into lib32/; x86_64 keeps lib-common/.
      # _mingw_libarm64/_mingw_lib32 are now defined near the top of this
      # function (hoisted for Step 1/2/4 implib generation); only route
      # _crt_outdir here.
      if [[ "${_win_arch}" == "aarch64" ]]; then
        _crt_outdir="${_mingw_libarm64}"
      elif [[ "${_win_arch}" == "x86" || "${_win_arch}" == "i386" || "${_win_arch}" == "i686" ]]; then
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

        # ZIGDIAG[crt-hdrs]: per-directory verdict for every CRT-internal header in
        # crtdefs.h's include chain. Distinguishes the states that a bare `-f` test
        # collapses into one: absent, present+readable, present-but-unreadable, and
        # BROKEN SYMLINK (-L true, -e false). The last is the only state that explains
        # a successful existence probe followed by a failed open, which is exactly the
        # observed failure signature.
        #
        # Round-27 widened this from crtdefs.h alone to the whole cluster. Round 26
        # probed only crtdefs.h, so when buildId 1565182 then failed on corecrt.h we
        # had no stat verdict for it at all -- its presence was inferable from the log
        # but never measured. Probing the whole set costs nothing and means ONE log
        # reports the full state, instead of learning about one header per ~2h round.
        _crt_hdrs=(crtdefs.h corecrt.h _mingw.h _mingw_mac.h _mingw_secapi.h
                   _mingw_unicode.h vadefs.h)
        for _cd_dir in "${_mingw_inc}" "${_win_inc}"; do
          for _cd_name in "${_crt_hdrs[@]}"; do
            _cd="${_cd_dir}/${_cd_name}"
            if [[ -L "${_cd}" && ! -e "${_cd}" ]]; then
              echo "ZIGDIAG[crt-hdrs]: BROKEN SYMLINK ${_cd} -> $(readlink "${_cd}" 2>/dev/null)" >&2
            elif [[ -L "${_cd}" ]]; then
              echo "ZIGDIAG[crt-hdrs]: symlink ${_cd} -> $(readlink "${_cd}" 2>/dev/null) (target exists)"
            elif [[ -f "${_cd}" && -r "${_cd}" ]]; then
              echo "ZIGDIAG[crt-hdrs]: regular file ${_cd} ($(wc -c <"${_cd}" 2>/dev/null) bytes, readable)"
            elif [[ -e "${_cd}" ]]; then
              echo "ZIGDIAG[crt-hdrs]: present but NOT a readable regular file: ${_cd}" >&2
            else
              echo "ZIGDIAG[crt-hdrs]: absent: ${_cd}"
            fi
          done
        done

        # PR #123 round 27. buildId 1565182 CONFIRMED the round-26 single-file staging
        # worked -- `crtdefs.h absent` did not recur -- but the SAME failure reappeared
        # one header deeper, on the staged crtdefs.h's own `#include <corecrt.h>`.
        #
        # It is still NOT a missing-file bug: that same -H dump shows corecrt.h opening
        # successfully four times in the SAME translation unit off the SAME 3-entry
        # search list (_mingw_inc -> zig/include -> _win_inc). The discriminating
        # pattern across both rounds is the INCLUDER, not the includee:
        #   oscalls.h        (in _mingw_inc) -> <crtdefs.h>  FAILED   (buildId 1565080)
        #   crtdefs.h staged (in _mingw_inc) -> <corecrt.h>  FAILED   (buildId 1565182)
        #   windows.h chain  (in _win_inc)   -> <corecrt.h>  SUCCEEDED x4
        # i.e. an angled include issued from a file sitting in _mingw_inc does not
        # reach _win_inc, while the same include from _win_inc resolves fine. If that
        # holds, satisfying the whole chain locally inside _mingw_inc ends it in one
        # round -- hence the widening below from one header to the cluster.
        #
        # This remains symptom-treatment: a green lane does NOT explain the mechanism.
        # Deliberately NOT mirroring all of any-windows-any (~1463 entries) -- that
        # would bloat the shipped package for no additional diagnostic value. Note the
        # staged copies DO change shipped package contents under
        # $PREFIX/lib/zig/libc/mingw/include; real mingw-w64 ships these headers in its
        # include root, so zig is the outlier for keeping them only in any-windows-any.
        for _cd_name in "${_crt_hdrs[@]}"; do
          if [[ ! -e "${_mingw_inc}/${_cd_name}" && -f "${_win_inc}/${_cd_name}" ]]; then
            if cp -f "${_win_inc}/${_cd_name}" "${_mingw_inc}/${_cd_name}"; then
              echo "  [_mingw] staged ${_cd_name} into ${_mingw_inc} (from ${_win_inc})"
            else
              echo "WARN: [_mingw] failed to stage ${_cd_name} into ${_mingw_inc}" >&2
            fi
          fi
        done

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
        local log; log=$(mktemp)
        if ! "${_zig_bin}" cc -c "${stub_c}" -o "${stub_o}" -target "${target_triple}" >"${log}" 2>&1; then
          echo "ERROR: failed to compile stub object for lib${lib_name}.a (${target_triple}):" >&2
          cat "${log}" >&2
          rm -f "${stub_c}" "${stub_o}" "${log}"
          return 1
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

      # _mingw_libarm64/_mingw_lib32 staging paths for the cache-warm loop
      # below are already set near the top of this function (hoisted for
      # Step 1/2/4 implib generation).

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
          local _warm_rc=0
          ZIG_GLOBAL_CACHE_DIR="${_warm_cache}" \
                  "${_zig_bin}" cc -target "${_warm_tgt}" -pthread \
                  "${_warm_dir}/warm.c" \
                  -o "${_warm_cache}/warm.exe" 2>"${_warm_cache}/warm.err" || _warm_rc=$?
          if [[ ${_warm_rc} -ne 0 ]]; then
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
          # DO NOT overwrite libpthread.a -- it's the 2KB import lib for
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
