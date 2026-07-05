#!/usr/bin/env bash
# ============================================================================
# Bootstrap native (build-arch) TableGen pre-pass.
#
# STATUS: DRAFT — authored 2026-07-14, NOT yet validated by a real build.
#         Exercised on the NEXT build cycle for the ppc64le / riscv64 / osx-64
#         cross columns. Do not treat any tuning point flagged below as
#         confirmed until a green build says so.
#
# WHY THIS EXISTS (bootstrap chicken-and-egg)
#   Cross builds need a BUILD-host-arch llvm-tblgen/clang-tblgen to generate
#   LLVM's .inc files. _cross_compile.sh's _find_build_tool() looks for those
#   as a PREBUILT shipped by the zig_impl_${build_platform} build dep. But no
#   package ships a zig-built tblgen YET — this very PR is what first produces
#   one. So on the current bootstrap builds discovery legitimately finds
#   NOTHING, and without a tblgen the main build falls back to LLVM's in-tree
#   NATIVE sub-project, which hits the riscv64 "incompatible with elf64lriscv"
#   ELF mismatch. This pre-pass fills that gap: it BUILDS llvm-tblgen +
#   clang-tblgen build-arch, and feeds them to the main configure.
#
#   Forward path (why this is bootstrap-only): once THIS PR merges,
#   zig_impl_${build_platform} ships the zig-built native tblgen. Future cross
#   builds then DISCOVER it via _find_build_tool and must REUSE it rather than
#   rebuild. Hence the guard below only runs the pre-pass when discovery came
#   up empty (LLVM_TBLGEN / CLANG_TBLGEN unset by _cross_compile.sh) — a
#   successful discovery bypasses this file entirely.
#
# ORDER / SCOPE
#   Sourced from llvm_build.sh AFTER _cross_compile.sh (so LLVM_TBLGEN /
#   CLANG_TBLGEN reflect discovery) and BEFORE _llvm_build.sh (so appended
#   flags reach the main configure via CMAKE_CROSS_FLAGS).
#
# LINKING STRATEGY (proven pattern, per _cross_compile.sh:403-418)
#   A host-arch tblgen is a throwaway build-host tool with no target-ABI
#   constraint. The proven-simplest recipe — the same one native (non-cross)
#   zig_impl builds use for ALL of LLVM incl. tblgen, and which succeeds — is:
#   build-arch zig-cc/zig-cxx + zig's BUNDLED libc++ (NO external
#   native-libcxx-install, NO -nostdinc++ -I; that approach CAUSED the osx
#   ~190-object <string.h> #error failures). The only wrinkle is the global
#   ZIG_SHARED_LIBCXX_DIR export (Linux/ppc64le), which would redirect the
#   build-arch zig-cxx at the TARGET libc++ -> ELF mismatch; we unset it for
#   the pre-pass so zig falls back to its bundled build-arch libc++.
#
# GUARD: is_cross && is_unix && discovery-empty. Windows (is_not_unix) cross
#   builds are intentionally deferred — the win-64 failure is the empty-implib
#   issue, not tblgen, and the native-win triple plumbing (_cross_compile.sh:432+)
#   is not mirrored here yet.
# ============================================================================

if is_cross && is_unix && { [[ -z "${LLVM_TBLGEN:-}" ]] || [[ -z "${CLANG_TBLGEN:-}" ]]; }; then
  echo "=== bootstrap native TableGen pre-pass (build-arch ${build_platform}) ==="
  echo "  discovery result: LLVM_TBLGEN='${LLVM_TBLGEN:-}' CLANG_TBLGEN='${CLANG_TBLGEN:-}' -> building in-tree"

  _NATIVE_TBLGEN_BUILD="${SRC_DIR}/conda-llvm-native-tblgen-build"
  _NATIVE_TBLGEN_BIN="${_NATIVE_TBLGEN_BUILD}/bin"

  # Build-arch compilers: the zig wrappers from the zig build dep default their
  # --target to the BUILD host (they only inject their compile-time default when
  # the caller supplies no --target), so NOT passing *_COMPILER_TARGET yields a
  # correct native compile. Mirrors the compiler selection in _cross_compile.sh.
  _nt_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
  _nt_cxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
  _nt_asm="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"   # zig 0.15.2 has no `as`; route .S/.s via -cc

  _nt_platform_flags=()
  if is_osx; then
    # NATIVE sub-tool must run as the BUILD arch, not the TARGET arch. Derive
    # from ${build_platform} (mirrors _cross_compile.sh:396-397).
    _nt_osx_arch="arm64"
    [[ "${build_platform}" == "osx-64" ]] && _nt_osx_arch="x86_64"
    _nt_platform_flags+=(-DCMAKE_OSX_ARCHITECTURES="${_nt_osx_arch}")
    # Null FindBacktrace (config-ix.cmake calls it unconditionally and injects
    # the Xcode SDK usr/include as a plain -I that beats zig's bundled libc++
    # include_next) — same lever as _cross_compile.sh:419-428.
    _nt_platform_flags+=(-DBacktrace_INCLUDE_DIR= -DBacktrace_INCLUDE_DIRS=)
    # The pre-pass tblgen is RUN during this build (to generate .inc files).
    # zig c++ on macOS links libc++ DYNAMICALLY (@rpath/libc++.1.dylib) and the
    # produced binary carries no rpath entry that resolves it -> llvm-min-tblgen
    # SIGABRTs at runtime ("Library not loaded: @rpath/libc++.1.dylib"; observed
    # PR #109 @ 69cb1b81, osx-64 Azure build 1552328). Link the STATIC build-arch
    # libc++ from _runtimes_build.sh's native pass so the host tool is
    # self-contained. LINK-ONLY flag (no -nostdinc++, no -I): zig's bundled
    # libc++ HEADERS still win, so this does NOT reintroduce the -I header
    # injection that caused the earlier <string.h> #error. Mirrors
    # _cross_compile.sh:430 (the proven osx host-tblgen link recipe).
    _nt_platform_flags+=(-DCMAKE_CXX_STANDARD_LIBRARIES="-L${SRC_DIR}/native-libcxx-install/lib -lc++ -lunwind")
    # The pre-pass tblgen's existing rpath resolves to its own build-tree bin/../lib,
    # which does NOT hold libc++.1.dylib -> dyld "Library not loaded: @rpath/libc++.1.dylib"
    # SIGABRT (PR #109 @ 50b1ab16, osx-64 build 1552414). The native libc++ dylib lives
    # in ${SRC_DIR}/native-libcxx-install/lib, so add an absolute LC_RPATH pointing there.
    _nt_platform_flags+=(-DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,${SRC_DIR}/native-libcxx-install/lib")
  fi

  # Configure a minimal, self-contained LLVM tree for tblgen only.
  #   - LLVM_ENABLE_PROJECTS=clang  : clang-tblgen lives in the clang project.
  #   - LLVM_TARGETS_TO_BUILD=Native: tblgen needs no target backends; Native is
  #       the small, always-valid choice (empty "" is rejected by some LLVM 20
  #       configs). TUNING POINT — revisit if configure complains.
  #   - zstd/zlib/libxml2 OFF: avoids the riscv64/s390x "incompatible with
  #       elf64lriscv" bundled-lib ELF mismatch entirely.
  # ZIG_SHARED_LIBCXX_DIR unset (see header): forces zig's bundled build-arch
  # libc++ for this throwaway host tool.
  env -u ZIG_SHARED_LIBCXX_DIR \
    cmake -S "${LLVM_SRC}" -B "${_NATIVE_TBLGEN_BUILD}" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="${_nt_cc}" \
      -DCMAKE_CXX_COMPILER="${_nt_cxx}" \
      -DCMAKE_ASM_COMPILER="${_nt_asm}" \
      -DLLVM_ENABLE_PROJECTS=clang \
      -DLLVM_TARGETS_TO_BUILD=Native \
      -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_ZLIB=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DLLVM_ENABLE_LIBEDIT=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      "${_nt_platform_flags[@]}"

  env -u ZIG_SHARED_LIBCXX_DIR \
    cmake --build "${_NATIVE_TBLGEN_BUILD}" --target llvm-tblgen clang-tblgen

  _nt_llvm_tblgen="${_NATIVE_TBLGEN_BIN}/llvm-tblgen"
  _nt_clang_tblgen="${_NATIVE_TBLGEN_BIN}/clang-tblgen"

  if [[ ! -x "${_nt_llvm_tblgen}" || ! -x "${_nt_clang_tblgen}" ]]; then
    echo "ERROR: bootstrap native TableGen pre-pass did not produce both binaries:"
    echo "  llvm-tblgen : ${_nt_llvm_tblgen} $([[ -x ${_nt_llvm_tblgen} ]] && echo OK || echo MISSING)"
    echo "  clang-tblgen: ${_nt_clang_tblgen} $([[ -x ${_nt_clang_tblgen} ]] && echo OK || echo MISSING)"
    exit 1
  fi

  # LLVM's TableGen.cmake resolves native tools by a LITERAL filename EXISTS
  # check under LLVM_NATIVE_TOOL_DIR, incl. llvm-min-tblgen. The full llvm-tblgen
  # is a strict superset, so satisfy the min-tblgen lookup with a symlink (same
  # trick as _cross_compile.sh:271-279, but in our own pre-pass bin dir).
  if [[ ! -e "${_NATIVE_TBLGEN_BIN}/llvm-min-tblgen" ]]; then
    ln -sf llvm-tblgen "${_NATIVE_TBLGEN_BIN}/llvm-min-tblgen" \
      && echo "  linked ${_NATIVE_TBLGEN_BIN}/llvm-min-tblgen -> llvm-tblgen"
  fi

  # Provide the tblgen flags to the main configure. Discovery was empty (guard
  # above), so there are no competing Layer-1 flags — the pre-pass is the sole
  # tblgen source here. Variable set mirrors _cross_compile.sh:237-248 (LLVM 20
  # TableGen resolution).
  CMAKE_CROSS_FLAGS+=(
    -DLLVM_TABLEGEN="${_nt_llvm_tblgen}"
    -DLLVM_TABLEGEN_EXE="${_nt_llvm_tblgen}"
    -DLLVM_MIN_TABLEGEN_EXE="${_nt_llvm_tblgen}"
    -DCLANG_TABLEGEN_EXE="${_nt_clang_tblgen}"
    -DLLVM_NATIVE_TOOL_DIR="${_NATIVE_TBLGEN_BIN}"
  )
  echo "  bootstrap native TableGen pre-pass flags appended to CMAKE_CROSS_FLAGS"
  echo "    LLVM_TABLEGEN     = ${_nt_llvm_tblgen}"
  echo "    CLANG_TABLEGEN_EXE= ${_nt_clang_tblgen}"
  echo "    LLVM_NATIVE_TOOL_DIR = ${_NATIVE_TBLGEN_BIN}"

  # NOTE: the pre-pass bin dir must persist until the main LLVM build finishes
  # running tblgen. A `rm -rf ${_NATIVE_TBLGEN_BUILD}` reclaim belongs in
  # _post_build.sh (disk, see LLVM_LLM_REFERENCE.md §4) — deferred, out of scope
  # for this draft.
elif is_cross && is_unix; then
  echo "=== native TableGen pre-pass SKIPPED: discovery already resolved tblgen ==="
  echo "    LLVM_TBLGEN='${LLVM_TBLGEN:-}' CLANG_TBLGEN='${CLANG_TBLGEN:-}' (prebuilt from zig_impl build dep) ==="
fi
