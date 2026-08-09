mkdir -p "${LLVM_BUILD}"

echo "=== Building libc++/libc++abi/libunwind with zig cc ==="
# Build runtimes BEFORE LLVM so shared libraries (libLLVM.so/.dylib/.dll)
# link against the already-installed shared libc++ instead of zig bundling
# a static copy into each one.
LIBCXX_SRC="${LLVM_SOURCE_ROOT}/runtimes"

_RUNTIMES_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  -DCMAKE_C_COMPILER="${ZIG_CC}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
  -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
  -DCMAKE_AR="${ZIG_AR}"
  -DCMAKE_RANLIB="${ZIG_RANLIB}"
)

# Runtimes to build and platform-specific flags.
# libc++abi is statically merged into libc++ on ALL platforms for consistency:
#   - Windows REQUIRES it (circular dependency, no lazy binding)
#   - Unix BENEFITS from it (fewer dylibs to manage, eliminates @rpath/libc++abi
#     reference, simplifies post-install fixups, matches zig's own bundling model)
_RUNTIMES_LIST="libcxxabi;libcxx"
_RUNTIMES_FLAGS=(
  -DLIBCXXABI_ENABLE_SHARED=OFF
  -DLIBCXXABI_ENABLE_STATIC=ON
  -DLIBCXXABI_USE_COMPILER_RT=ON
  -DLIBCXX_ENABLE_SHARED=ON
  -DLIBCXX_ENABLE_STATIC=OFF
  -DLIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON
  -DLIBCXX_USE_COMPILER_RT=ON
  -DLIBCXX_CXX_ABI=libcxxabi
)

# libunwind provides _Unwind_* / _GCC_specific_handler symbols needed by
# libc++abi's exception handling. On Unix: DWARF unwinding (shared lib).
# On Windows (MinGW): SEH-based unwinding via libunwind's SEH adapter, built
# STATIC-only so it embeds into libc++abi.dll (see Windows overrides below).
# Without libunwind, the libc++abi.dll link fails with undefined _Unwind_Resume,
# _Unwind_RaiseException, _GCC_specific_handler, etc.
_RUNTIMES_LIST="libunwind;${_RUNTIMES_LIST}"
_RUNTIMES_FLAGS+=(
  -DLIBUNWIND_ENABLE_SHARED=ON
  -DLIBUNWIND_ENABLE_STATIC=OFF
  -DLIBUNWIND_USE_COMPILER_RT=ON
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON
)

if is_unix; then
  # Override zig cc's default -fvisibility=hidden so libc++ symbols are public
  # and genuinely shared between libLLVM.so and libclang-cpp.so.
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_FLAGS="-fvisibility=default"
    -DCMAKE_CXX_FLAGS="-fvisibility=default -Wno-nullability-completeness"
    -DCMAKE_SKIP_RPATH=ON
  )
  # Cross: use the self-sufficient BUILD-arch llvm-config staged under lib/zig-llvm
  # by build_native_llvm_config; native keeps the same-arch build-dep copy in bin/.
  if is_cross; then
    _RUNTIMES_CMAKE+=(-DLLVM_CONFIG_PATH="${BUILD_PREFIX}/lib/zig-llvm/bin/llvm-config")
  else
    _RUNTIMES_CMAKE+=(-DLLVM_CONFIG_PATH="${BUILD_PREFIX}/bin/llvm-config")
  fi
fi

if is_linux; then
  # zig's clang auto-embeds .deplibs sections (dl, pthread) in shared-lib objects.
  # lld processes .deplibs separately from explicit -l flags and fails when the
  # library path isn't directly resolvable. zig's cc driver also does not forward
  # -Wl,--ignore-dependent-libraries to lld, so fix this at compile time instead:
  # -fno-autolink suppresses .deplibs generation entirely. The explicit -ldl/-lpthread
  # on the cmake command line still cover the same dependencies.
  # Note: this overrides is_unix CMAKE_C/CXX_FLAGS — -fvisibility=default is preserved.
  _RUNTIMES_CMAKE+=(
    "-DCMAKE_C_FLAGS=-fvisibility=default -fno-autolink"
    "-DCMAKE_CXX_FLAGS=-fvisibility=default -fno-autolink -Wno-nullability-completeness"
  )
fi

if is_not_unix; then
  # MinGW: Win32 threading API (no pthreads on Windows)
  _RUNTIMES_FLAGS+=(
    -DLIBCXX_HAS_WIN32_THREAD_API=ON
    -DLIBCXXABI_HAS_WIN32_THREAD_API=ON
    -DLIBCXX_HAS_PTHREAD_API=OFF
    -DLIBCXXABI_HAS_PTHREAD_API=OFF
    # dl and pthread are not standalone libraries on Windows (dl=kernel32,
    # pthread=Win32 API). With CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    # cmake's check_library_exists() compiles without linking, so it falsely
    # reports these libraries as present and adds -ldl/-lpthread to the link.
    # Pre-set the check results to NO to suppress the erroneous -l flags.
    -DLIBUNWIND_HAS_DL_LIB=NO
    -DLIBUNWIND_HAS_PTHREAD_LIB=NO
  )
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_FLAGS="-fvisibility=default"
    -DCMAKE_CXX_FLAGS="-fvisibility=default -Wno-nullability-completeness"
  )
fi

# Windows (all arches): skip CMake C/CXX compiler ABI probe — zig's bundled
# LLD/COFF emits /MANIFEST:EMBED which CMake's link-test doesn't expect.
# Use STATIC_LIBRARY mode so the probe compiles only (no link step).
if is_not_unix && [[ "${LLVM_TRIPLET}" == *-windows* ]]; then
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER_WORKS=TRUE
    -DCMAKE_CXX_COMPILER_WORKS=TRUE
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    # Native win-64 (build==target, is_cross=false) never enters the cross block
    # near the bottom of this file that sets CMAKE_*_ABI_COMPILED=TRUE, so live ABI
    # detection runs and, under LLVM 21, libcxx/src/CMakeLists.txt FATALs on an
    # unresolved compiler feature set ("No known features for CXX compiler").
    # The win cross lanes (win-32/win-arm64) pass only because they inherit these
    # from the is_cross block. Set them here too so all three windows lanes skip
    # ABI detection identically. Duplicated (not moved) so linux/osx cross keep theirs.
    -DCMAKE_C_ABI_COMPILED=TRUE
    -DCMAKE_CXX_ABI_COMPILED=TRUE
    # CMAKE_C/CXX_COMPILER_WORKS=TRUE above bypasses CMakeDetermineCXXCompiler /
    # CMakeTestCXXCompiler, which are what normally populate COMPILER_ID/VERSION.
    # Left blank, libcxx's CMAKE_CXX_COMPILE_FEATURES lookup FATALs with "No known
    # features for CXX compiler \"\" version .". zig's C++ frontend is
    # clang-compatible, so pre-seed the identity CMake would have detected.
    -DCMAKE_C_COMPILER_ID=Clang
    -DCMAKE_CXX_COMPILER_ID=Clang
    -DCMAKE_C_COMPILER_VERSION="${LLVM_SRC_VERSION}"
    -DCMAKE_CXX_COMPILER_VERSION="${LLVM_SRC_VERSION}"
    # Even with COMPILER_ID/VERSION pre-seeded above, CMake's Clang-C.cmake /
    # Clang-CXX.cmake still calls __compiler_check_default_language_standard,
    # which normally derives CMAKE_<LANG>_STANDARD_COMPUTED_DEFAULT and
    # CMAKE_<LANG>_EXTENSIONS_COMPUTED_DEFAULT by invoking the real compiler
    # with CMAKE_<LANG>_COMPILER_PREDEFINES_COMMAND (-dM -E -x <lang> -) to
    # read back __STDC_VERSION__/__cplusplus/__STRICT_ANSI__. Under zig cc's
    # Windows wrapper this probe comes back empty (stdin "-" handling), so
    # CMakeCommonCompilerMacros.cmake:42 FATALs with "CMAKE_C_STANDARD_COMPUTED_
    # DEFAULT and CMAKE_C_EXTENSIONS_COMPUTED_DEFAULT should be set for Clang".
    # Clang >=16 defaults to gnu17/gnu++17 (extensions ON) on mingw targets;
    # pre-seed those values directly, same pattern as COMPILER_ID/VERSION above.
    # Harmless for the actual runtimes build: libcxx/libcxxabi/libunwind each
    # set their own explicit -std= flags and do not rely on this default.
    -DCMAKE_C_STANDARD_COMPUTED_DEFAULT=17
    -DCMAKE_C_EXTENSIONS_COMPUTED_DEFAULT=ON
    -DCMAKE_CXX_STANDARD_COMPUTED_DEFAULT=17
    -DCMAKE_CXX_EXTENSIONS_COMPUTED_DEFAULT=ON
  )

  # Windows COFF: build libunwind STATIC-ONLY and embed it (and libc++abi) into libc++.dll.
  #
  # The unwind.lib collision (`ninja: error: multiple rules generate lib/unwind.lib`)
  # historically happened when both `unwind` (shared, import lib → unwind.lib) and
  # `unwind_static` (static → unwind.lib) targets were enabled — both emit the same
  # filename on COFF. Unix is unaffected because .a vs .so extensions differ.
  #
  # Solution: build only the STATIC libunwind on Windows (LIBUNWIND_ENABLE_SHARED=OFF,
  # LIBUNWIND_ENABLE_STATIC=ON — overriding the Unix defaults set earlier), and embed
  # it into libcxxabi (LIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=ON). The
  # default LIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON then folds libcxxabi
  # (with its embedded unwind) into libc++.dll — the standard Unix-like layout.
  #
  # Why ABI-in-shared can stay ON on Windows now: the original reason for the OFF
  # override (LIBUNWIND_ENABLE_SHARED=ON triggering the unwind.lib name collision)
  # is gone now that the shared libunwind variant is disabled. With only one unwind
  # target, no rule collision occurs. Without ABI-in-shared, libc++abi.dll builds
  # as a separate DLL and fails to link against std::__1::__libcpp_mutex_* /
  # __libcpp_condvar_* threading primitives that live in libc++ — a circular
  # dependency that the merged layout avoids.
  _RUNTIMES_FLAGS+=(
    -DLIBUNWIND_ENABLE_SHARED=OFF
    -DLIBUNWIND_ENABLE_STATIC=ON
    -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=ON
  )

  # Windows ARM64 only: cmake compiler link test additionally fails with:
  #   lld-link: unable to automatically import from _fpreset with relocation
  #   type IMAGE_REL_ARM64_BRANCH26 in crt2.obj / libmingw32.lib
  # ARM64 branch instructions (BL) can't be redirected to DLL import thunks
  # the way x86 auto-import works. Inject the _fpreset stub into all linker
  # invocations so shared lib builds (libunwind.dll, libc++.dll, etc.) don't
  # hit the same error.
  if [[ "${LLVM_TRIPLET}" == aarch64-* ]]; then
    _fpreset_stub="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common/_fpreset_arm64.o"
    # If zig-gcc package didn't ship the stub, build it inline as a fallback.
    # Mirrors recipes/zig-gcc/building/_win_arm64_stubs.sh:create_fpreset_stub.
    # ARM64 has no x87 FPU; _fpreset is a no-op.
    if [[ ! -f "${_fpreset_stub}" ]]; then
      echo "  _fpreset_arm64.o stub missing from zig-gcc package; building inline fallback"
      _fpreset_stub="${LLVM_BUILD}/_fpreset_arm64.o"
      _fpreset_src="${LLVM_BUILD}/_fpreset_arm64.c"
      mkdir -p "${LLVM_BUILD}"
      cat > "${_fpreset_src}" << 'EOF'
// Inline fallback for _fpreset_arm64.o (mirror of zig-gcc _win_arm64_stubs.sh).
// ARM64 has no x87 FPU; _fpreset is a no-op. Resolves IMAGE_REL_ARM64_BRANCH26
// auto-import error from CRT objects (crt2.obj, libmingw32.lib).
void _fpreset(void) {}
EOF
      "${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe" cc \
        -target aarch64-windows-gnu -c "${_fpreset_src}" -o "${_fpreset_stub}" \
        || { echo "ERROR: failed to compile inline _fpreset_arm64.o stub"; exit 1; }
      rm -f "${_fpreset_src}"
      [[ -f "${_fpreset_stub}" ]] || { echo "ERROR: _fpreset stub still missing after compile"; exit 1; }
      echo "    inline stub: ${_fpreset_stub} ($(wc -c < "${_fpreset_stub}") bytes)"
    fi
    _RUNTIMES_CMAKE+=(
      -DCMAKE_SHARED_LINKER_FLAGS="${_fpreset_stub}"
      -DCMAKE_EXE_LINKER_FLAGS="${_fpreset_stub}"
    )
  fi
fi

# macOS: tell cmake the correct arch (prevents -mcpu=core2 on cross-builds)
if is_osx; then
  _RUNTIMES_CMAKE+=(-DCMAKE_OSX_ARCHITECTURES="${_osx_arch}")
fi

# ppc64le: skip CMake compiler link test (same as main LLVM build).
# The ld wrapper (created above) injects --sysroot + -lpthread/-ldl for shared
# lib builds. Additionally suppress glibc-version-gated symbols that are NOT
# available in the glibc 2.17 sysroot but zig's bundled headers enable:
# - __cxa_thread_atexit_impl: added in glibc 2.18. zig's check_library_exists
#   tests against zig's bundled libc (newer glibc), so LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL
#   comes back ON. Override to OFF so the fallback implementation is compiled.
# - copy_file_range: added in glibc 2.27 libc wrapper. Guarded by
#   _LIBCPP_GLIBC_PREREQ(2,27) but zig's bundled libc++ headers may resolve
#   this as true. Undefine _LIBCPP_FILESYSTEM_USE_COPY_FILE_RANGE so the
#   sendfile/fstream fallback is used instead.
if [[ "${LLVM_TRIPLET}" == powerpc64le-* ]]; then
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER_WORKS=TRUE
    -DCMAKE_CXX_COMPILER_WORKS=TRUE
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    "-DCMAKE_CXX_FLAGS=-fvisibility=default -fno-autolink -D__GLIBC_MINOR__=17 -Wno-nullability-completeness"
  )
  _RUNTIMES_FLAGS+=(
    -DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF
  )
fi

# Cross-compilation: tell cmake the compiler's target triple explicitly.
# Without this, cmake's ABI detection probes the wrapper by filename and may
# infer the build-host triple (x86_64) instead of the target triple (e.g.
# aarch64-unknown-linux-gnu), caching x86_64 for all C/C++ compile+link steps.
# ASM escapes the problem because it is compiled differently, so C/C++ objects
# end up as elf_x86_64 while ASM objects are aarch64 — causing ld.lld errors.
# ZIG_LLVM_TRIPLET (3-component zig triple; see _cross_compile.sh:291-296 for
# the "-unknown-" stripping rationale) is recomputed here — independently of
# _cross_compile.sh, whose own copy of this line only runs inside its
# CONDA_BUILD_CROSS_COMPILATION guard — because this file's `is_cross` block
# below needs the value regardless of how _cross_compile.sh's guard evaluated.
ZIG_LLVM_TRIPLET="$(zig_triplet_from_llvm "${LLVM_TRIPLET}")"

# libunwind (LLVM 21, libunwind/src/CMakeLists.txt:92-98) FATAL_ERRORs unless
# CXX_SUPPORTS_FNO_EXCEPTIONS_FLAG AND CXX_SUPPORTS_FUNWIND_TABLES_FLAG are TRUE.
# The check_cxx_compiler_flag probes false-negative under this toolchain, but zig
# cc / clang genuinely supports these, so force them unconditionally (all lanes).
_RUNTIMES_CMAKE+=(
  -DCXX_SUPPORTS_FUNWIND_TABLES_FLAG=TRUE
  -DCXX_SUPPORTS_FNO_EXCEPTIONS_FLAG=TRUE
  -DCXX_SUPPORTS_FNO_RTTI_FLAG=TRUE
  -DCXX_SUPPORTS_NOSTDLIBXX_FLAG=TRUE
  -DCXX_SUPPORTS_UNWINDLIB_EQ_NONE_FLAG=TRUE
)

# === NATIVE (build-arch) libc++/libc++abi/libunwind for host tools ===
# On cross builds the main runtimes below are TARGET-arch (installed to
# ${LLVM_INSTALL}); the host tools LLVM builds in Phase 2 (e.g. llvm-tblgen) are
# BUILD-arch executables that link libc++ and must LOAD a build-arch libc++ at
# runtime. The original zig-llvm recipe satisfied this with a solver-installed
# zig-libcxx package; this feedstock cannot rely on that, so build the build-arch
# libc++ here and stage it into the zig probe dir (see probe-dir section below).
# Cloned from _RUNTIMES_CMAKE BEFORE the target-triple CMAKE_*_COMPILER_TARGET
# overrides are appended, so it genuinely targets the build arch.
# Also runs for native osx (build_platform == target_platform): unlike native linux,
# native osx's build-time llvm-min-tblgen still dyld-fails without this build-arch
# libc++.1.dylib staged (PR #123, osx-64 native) -- there is no other source for it.
if is_cross || is_osx; then
  echo "=== Building NATIVE (build-arch) libc++ for host tools (e.g. host-tblgen) ==="
  _NATIVE_RUNTIMES_CMAKE=("${_RUNTIMES_CMAKE[@]}")
  _NATIVE_RUNTIMES_FLAGS=("${_RUNTIMES_FLAGS[@]}")
  _native_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
  _native_cxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
  _NATIVE_RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER="${_native_cc}"
    -DCMAKE_CXX_COMPILER="${_native_cxx}"
    # ASM uses cc; without this override it inherits the cloned target ${ZIG_ASM}
    # (cross wrapper), assembling build-arch .S files (libunwind UnwindRegisters*.S)
    # for the target arch and failing the build-arch shared link (elf mismatch).
    -DCMAKE_ASM_COMPILER="${_native_cc}"
    -DCMAKE_INSTALL_PREFIX="${SRC_DIR}/native-libcxx-install"
  )
  # Floor the native (build-arch) runtimes to the conda linux-64 glibc floor (2.17,
  # variants.yaml c_stdlib_version) so libdl/libpthread/librt exist as separate real
  # libs and the libunwind/libc++ dependent-library records resolve. Without the
  # floor, zig cc native-targets the build machine's modern glibc (dl/pthread/rt
  # merged into libc); those standalone .so's do not exist and the shared links fail
  # with "unable to find library from dependent library specifier: dl/pthread/rt".
  # This keeps local (modern glibc) and CI (cos7 glibc-2.17) builds consistent, and
  # matches the TARGET build's floor. Linux only: ZIG_TARGET_BUILD has no glibc suffix
  # for linux-64 (osx/windows already carry theirs).
  if is_linux; then
    _native_target="${ZIG_TARGET_BUILD}.2.17"
    _NATIVE_RUNTIMES_CMAKE+=(
      -DCMAKE_C_COMPILER_TARGET="${_native_target}"
      -DCMAKE_CXX_COMPILER_TARGET="${_native_target}"
      -DCMAKE_ASM_COMPILER_TARGET="${_native_target}"
      "-DCMAKE_ASM_FLAGS=--target=${_native_target}"
    )
  fi

  # Native (build-arch) libunwind emits .deplibs records for dl/pthread that
  # lld cannot resolve from zig's synthesized glibc dir (the explicit -ldl/
  # -lpthread on the link DO resolve, but the embedded dependent-library
  # specifiers search a different path; -fno-autolink does not suppress them).
  # Compile out libunwind's optional dladdr/pthread paths so no unresolvable
  # deplib record is emitted. Safe: this is the build-arch host-tool libunwind
  # (for llvm-tblgen etc.), not a shipped runtime. libc++/libc++abi cannot be
  # cleaned up this way (they emit the same deplib records but genuinely use
  # pthread, and -Wl,-z,defs forbids stubbing) -- those are handled by the
  # build-sysroot -L injection immediately below.
  if is_linux; then
    _NATIVE_RUNTIMES_FLAGS+=(
      -DLIBUNWIND_HAS_DL_LIB=NO
      -DLIBUNWIND_HAS_PTHREAD_LIB=NO
    )
  fi

  # libc++ (cxa_guard.cpp.o -> pthread) and libc++abi/libc++ (chrono.cpp.o -> rt)
  # embed .deplibs (SHT_LLVM_DEPENDENT_LIBRARIES) specifiers that -fno-autolink
  # does NOT strip (see the note at the is_linux -fno-autolink block near the top
  # of this file) and that no HAS_*_LIB knob suppresses. The explicit -lpthread/-lc
  # on the link already provide the real linkage; only the embedded auto-link hints
  # fail to resolve.
  #
  # Build 0 REFUTED the earlier "inject build-sysroot -L so lld resolves the
  # specifiers" theory: the failing native libc++.so.1 link already carried
  # -L${sysroot}/usr/lib64 ... /usr/lib ... /lib64 ... /lib and lld STILL reported
  # "unable to find library from dependent library specifier: pthread/rt". zig cc
  # does not search the user -L when resolving deplib records for a
  # --target=...gnu.2.17 link, so no amount of -L fixes it.
  #
  # Instead tell lld to ignore the deplib records outright -- the command-line -l
  # flags cover the real deps. The correct lld ELF spelling is
  # --no-dependent-libraries (the earlier --ignore-dependent-libraries the top-of-
  # file note tried is NOT an lld option, which is why it appeared "not forwarded").
  # The -L is kept as a harmless belt-and-suspenders fallback. CMAKE_SHARED_LINKER_
  # FLAGS is unset on the native Linux path (only win-arm64 sets it), so this sets
  # rather than clobbers.
  if is_linux; then
    # --no-dependent-libraries is DEAD: zig cc's -Wl, translator silently
    # drops it before it reaches lld (verified: ppc64le_deplib_experiment.sh),
    # regardless of -fuse-ld=lld. The actual fix is objcopy --remove-section=
    # .deplibs on the compiled objects, applied by the ZIG_STRIP_DEPLIBS=1
    # hook in the ${CONDA_ZIG_BUILD}-cc/-cxx wrappers (recipe/build.sh),
    # exported around this cmake --build call below. -fuse-ld=lld and the -L
    # belt-and-suspenders are kept (harmless, no longer load-bearing).
    _native_ldflags="-fuse-ld=lld -v"
    _native_sr="${CONDA_BUILD_SYSROOT:-}"
    [[ ! -d "${_native_sr}" ]] && _native_sr="${BUILD_PREFIX}/${CONDA_ZIG_BUILD%-zig}/sysroot"
    if [[ -d "${_native_sr}" ]]; then
      _native_ldflags="${_native_ldflags} -L${_native_sr}/usr/lib64 -L${_native_sr}/usr/lib -L${_native_sr}/lib64 -L${_native_sr}/lib"
    else
      echo "WARNING: build sysroot not found for native libc++ deplib -L injection" \
           "(looked at CONDA_BUILD_SYSROOT and ${BUILD_PREFIX}/${CONDA_ZIG_BUILD%-zig}/sysroot)"
    fi
    _NATIVE_RUNTIMES_CMAKE+=(
      "-DCMAKE_SHARED_LINKER_FLAGS=${_native_ldflags}"
      "-DCMAKE_EXE_LINKER_FLAGS=${_native_ldflags}"
    )
  fi
  # _NATIVE_RUNTIMES_CMAKE was cloned from _RUNTIMES_CMAKE, which already carries
  # -DCMAKE_OSX_ARCHITECTURES for the TARGET arch. Left as-is, the native
  # (BUILD-arch) zig-cc is invoked with the wrong -arch (e.g. an arm64 host
  # cross-building to osx-64 would compile host-tblgen with -arch x86_64 and fail
  # with "unknown target CPU apple-m1"). CMake honours the last -D on the command
  # line, so append the BUILD-arch value here to override the stale clone.
  if is_osx; then
    _native_osx_arch="arm64"
    [[ "${build_platform}" == "osx-64" ]] && _native_osx_arch="x86_64"
    _NATIVE_RUNTIMES_CMAKE+=(-DCMAKE_OSX_ARCHITECTURES="${_native_osx_arch}")
  fi
  # Build-arch libc++ must be SHARED on Unix so the zig probe dir gets a real
  # libc++.so.1 (Linux) / libc++.1.dylib (macOS). Host tools load it at runtime:
  # Linux via LD_LIBRARY_PATH (_llvm_build.sh:702), macOS via DYLD (zig-cxx links
  # libc++ dynamically regardless of a static -lc++). Keep the static libs too.
  # Windows stays static-only (COFF emits unwind.lib for both shared and static
  # libunwind, which collides as a duplicate ninja rule).
  # NOTE: on cross, the build-arch libc++.so.1 staged here shares the single,
  # arch-unqualified probe path with whatever the Phase-2 TARGET .so links may
  # want (target-arch). If libLLVM.so static-merges libc++ or host-tblgen hits an
  # arch mismatch, revisit this single-probe-path design (see session learning).
  _NATIVE_RUNTIMES_FLAGS+=(
    -DLIBCXX_ENABLE_STATIC=ON
    -DLIBUNWIND_ENABLE_STATIC=ON
  )
  if is_unix; then
    _NATIVE_RUNTIMES_FLAGS+=(
      -DLIBCXX_ENABLE_SHARED=ON
      -DLIBUNWIND_ENABLE_SHARED=ON
    )
  else
    _NATIVE_RUNTIMES_FLAGS+=(
      -DLIBCXX_ENABLE_SHARED=OFF
      -DLIBUNWIND_ENABLE_SHARED=OFF
    )
  fi
  mkdir -p "${SRC_DIR}/conda-runtimes-build-native"
  cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build-native" \
    "${_NATIVE_RUNTIMES_CMAKE[@]}" \
    -DLLVM_ENABLE_RUNTIMES="${_RUNTIMES_LIST}" \
    "${_NATIVE_RUNTIMES_FLAGS[@]}" \
    -G Ninja \
    || {
      _native_configure_rc=$?
      echo "===== zig-feedstock DIAGNOSTIC: native cmake configure FAILED (rc=${_native_configure_rc}), dumping probe logs ====="
      find "${SRC_DIR}/conda-runtimes-build-native" -name CMakeError.log -exec sh -c 'echo "----- {} -----"; cat "{}"' \; 2>/dev/null || true
      find "${SRC_DIR}/conda-runtimes-build-native" -name CMakeOutput.log -exec sh -c 'echo "----- {} -----"; cat "{}"' \; 2>/dev/null || true
      find "${SRC_DIR}/conda-runtimes-build-native" \( -path '*CMakeFiles*CompilerId*' -o -path '*CMakeFiles*CMakeError*' \) 2>/dev/null | head -40 || true
      echo "FATAL: native (build-arch) libc++ cmake configure failed"
      exit "${_native_configure_rc}"
    }
  export ZIG_STRIP_DEPLIBS=1
  cmake --build "${SRC_DIR}/conda-runtimes-build-native" -j"${CPU_COUNT}" --verbose \
    || { echo "FATAL: native (build-arch) libc++ build failed"; exit 1; }
  cmake --install "${SRC_DIR}/conda-runtimes-build-native" \
    || { echo "FATAL: native (build-arch) libc++ install failed"; exit 1; }
  unset ZIG_STRIP_DEPLIBS
  if [[ -f "${SRC_DIR}/.zig_local_iterate" ]]; then
    echo "  .zig_local_iterate sentinel present: preserving conda-runtimes-build-native for incremental local rebuilds"
  else
    rm -rf "${SRC_DIR}/conda-runtimes-build-native"
  fi
  # Do not claim success unless the build-arch libc++ actually landed.
  if ! ls "${SRC_DIR}/native-libcxx-install/lib/"libc++* >/dev/null 2>&1; then
    echo "FATAL: native (build-arch) libc++ missing from ${SRC_DIR}/native-libcxx-install/lib after install"
    exit 1
  fi
  # PR #123 round 26: libunwind was NOT asserted here, so a failed shared-libunwind
  # build passed silently and only surfaced ~2h later as llvm-config dying with
  # "error while loading shared libraries: libunwind.so.1". Assert it too.
  if ! ls "${SRC_DIR}/native-libcxx-install/lib/"libunwind* >/dev/null 2>&1; then
    echo "FATAL: native (build-arch) libunwind missing from ${SRC_DIR}/native-libcxx-install/lib after install"
    exit 1
  fi
  echo "  native build-arch libc++ installed to ${SRC_DIR}/native-libcxx-install/lib"
fi


# --- Early stage: put the build-arch libc++/libunwind on the zig-cxx probe path NOW ---
# build_native_llvm_config (recipe/zig-llvm/build.sh) runs NEXT and builds llvm-config with
# zig-cxx, whose shared-libc++ probe (<zig_lib_dir>/../../lib/zig-llvm/lib) must find a
# runnable build-arch libc++.{so.1,1.dylib} or llvm-config/llvm-min-tblgen link @rpath to a
# missing dylib and dyld-fail. The full probe-stage loop in _runtimes_target.sh re-copies
# idempotently later. Unix cross, plus native osx (build_native_llvm_config is
# is_unix && (is_cross || is_osx) -- see _native_llvm_config.sh).
if (is_cross || is_osx) && is_unix; then
  _probe_dir_early="${BUILD_PREFIX}/lib/zig-llvm/lib"
  mkdir -p "${_probe_dir_early}"
  for _f in "${SRC_DIR}/native-libcxx-install/lib/"libc++* "${SRC_DIR}/native-libcxx-install/lib/"libunwind*; do
    [[ -f "${_f}" ]] && cp -f "${_f}" "${_probe_dir_early}/"
  done
  echo "  early-staged build-arch libc++/libunwind to ${_probe_dir_early} (pre-llvm-config)"
fi
