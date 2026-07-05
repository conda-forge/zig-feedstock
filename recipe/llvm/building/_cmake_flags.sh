# Clear conda's compiler flags — zig handles optimization internally.
# CMAKE_ARGS: conda-build sets this with architecture-specific flags (e.g.
# -DCMAKE_OSX_ARCHITECTURES=x86_64, -mcpu=core2 for osx-64 cross-builds)
# that conflict with zig's own target/CPU handling.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CMAKE_ARGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

dbg "ZIG_TRIPLET: ${ZIG_TRIPLET}"
dbg "ZIG_CC: ${ZIG_CC}"
dbg "ZIG_CXX: ${ZIG_CXX}"
dbg "ZIG_AR: ${ZIG_AR}"

# LLVM_TRIPLET is set by recipe.yaml env (standard LLVM triple, no glibc version suffix)
dbg "LLVM_TRIPLET: ${LLVM_TRIPLET}"

# Platform-specific CMake flags
CMAKE_PLATFORM_FLAGS=()

is_linux && CMAKE_PLATFORM_FLAGS=(
  -DHAVE_DECL_ARC4RANDOM=0
  -DHAVE_MALLINFO2=0
  -DHAVE_PTHREAD_GETNAME_NP=0
  -DHAVE_PTHREAD_SETNAME_NP=0
  -DLLVM_ENABLE_ZSTD=ON
)

# --------------------------------------------------------------------
# Conditional zstd pin: only when zig-zstd is actually installed.
# zig-zstd ships only for riscv64 (per recipe.yaml ${{ zig }}zstd which
# expands to 'zig-zstd' only when ${{ zig }} == 'zig-'); other platforms
# use plain conda-forge zstd in $PREFIX/lib + $PREFIX/include. Pinning
# unconditionally caused cmake configure to fail on linux-64 native:
#   Imported target "zstd::libzstd_shared" includes non-existent path
#     "$PREFIX/lib/zig-zstd/include"
# because the pin pointed at a path that doesn't exist on non-riscv64.
# zig-zstd installs zstdConfig.cmake at a non-default path; pin zstd_DIR so
# CMake's find_package(zstd CONFIG) doesn't pick up BUILD_PREFIX's x86_64
# zstd via CMAKE_PREFIX_PATH (caused riscv64 cross-link 'incompatible with
# elf64lriscv' against $BUILD_PREFIX/lib/libzstd.so). All three vars are
# typed (:PATH/:FILEPATH) so CMake stores them as INITIALIZED in the cache —
# without type annotations CMake marks them UNINITIALIZED and find_package
# ignores them, falling back to CMAKE_PREFIX_PATH (which includes BUILD_PREFIX).
# --------------------------------------------------------------------
if is_linux && [[ -d "${PREFIX}/lib/zig-zstd/lib/cmake/zstd" ]]; then
    CMAKE_PLATFORM_FLAGS+=(
        -Dzstd_DIR:PATH="${PREFIX}/lib/zig-zstd/lib/cmake/zstd"
        -Dzstd_LIBRARY:FILEPATH="${PREFIX}/lib/zig-zstd/lib/libzstd.so"
        -Dzstd_INCLUDE_DIR:PATH="${PREFIX}/lib/zig-zstd/include"
    )
    echo "  cmake_flags: zstd pinned to zig-zstd (riscv64 layout)"
elif is_linux; then
    echo "  cmake_flags: zig-zstd not installed, leaving zstd to CMAKE_PREFIX_PATH"
fi

# riscv64-only: even with the zstd_DIR/_LIBRARY/_INCLUDE_DIR pin above,
# find_package(zstd) can still re-resolve against the HOST x86_64
# ${BUILD_PREFIX}/lib/libzstd.so via CMAKE_PREFIX_PATH (set in
# _llvm_build.sh's outer cmake invocation), pulling an x86_64 object into
# the riscv64 target libLLVM.so.20.1 link and failing with
# "ld.lld: incompatible with elf64lriscv". riscv64 already excludes
# conda's host zstd from requirements and uses static lld (recipe.yaml),
# so disabling optional zstd compression entirely for this build is safe
# and removes the leak path outright rather than fighting find_package
# resolution order. Appended LAST so it wins over line ~24's ON default.
if [[ "${target_platform}" == "linux-riscv64" ]]; then
    CMAKE_PLATFORM_FLAGS+=(
        -DLLVM_ENABLE_ZSTD=OFF
        -DCMAKE_DISABLE_FIND_PACKAGE_zstd=ON
    )
    echo "  cmake_flags: riscv64 — zstd disabled entirely (host x86_64 libzstd.so ELF-arch leak fix)"
fi

if is_osx; then
  # Determine the correct macOS architecture from the target platform.
  # cmake auto-detects from the host (build) machine, which is wrong for
  # cross-builds (e.g. build=osx-arm64, target=osx-64 → need x86_64).
  _osx_arch="arm64"
  [[ "${target_platform}" == "osx-64" ]] && _osx_arch="x86_64"
  CMAKE_PLATFORM_FLAGS=(
    -DLLVM_ENABLE_ZSTD=ON
    -Dzstd_ROOT="${PREFIX}"
    -DCMAKE_OSX_ARCHITECTURES="${_osx_arch}"
    # zig's Mach-O linker dead-strips LLVMInitialize* and LLVM C API symbols from
    # libLLVM.dylib because nothing inside the dylib references them — they're only
    # called by external consumers (libclang-cpp.dylib, tools). LLVM's own cmake
    # adds -Wl,-dead_strip via add_link_opts(); this knob prevents that.
    -DLLVM_NO_DEAD_STRIP=ON
    # macos-14 runner has 7 GB RAM; parallel link of libLLVM.dylib + libclang-cpp.dylib
    # exceeds it. Serialize link jobs to prevent OOM kill of runner agent.
    -DLLVM_PARALLEL_LINK_JOBS=1
  )

  # macOS sysroot propagation:
  #
  # Previously this block injected `-Wl,-syslibroot,${CONDA_BUILD_SYSROOT}`
  # into CMAKE_*_LINKER_FLAGS to compensate for zig ld64.lld not translating
  # -isysroot to -syslibroot at link time. Zig 0.15.2 build 27 REJECTS the
  # -syslibroot linker arg outright (`error: unsupported linker arg: -syslibroot`)
  # — it is no longer a translation gap, it is a rejection.
  #
  # On zig 0.15.2 the compiler-driven -isysroot pathway is sufficient: clang
  # propagates the SDK path to its integrated MachO linker invocation. cmake
  # passes -isysroot automatically when CMAKE_OSX_SYSROOT is set (conda-build
  # sets this from CONDA_BUILD_SYSROOT).
  #
  # If linking later fails with `library not found for -lSystem` or unresolved
  # _abort, the fix is to add a zig-native sysroot flag (likely via the upstream
  # wrapper's --sysroot translation), NOT to re-add -Wl,-syslibroot.
  if [[ -n "${CONDA_BUILD_SYSROOT:-}" && -d "${CONDA_BUILD_SYSROOT}/usr/lib" ]]; then
    echo "  macOS sysroot: relying on -isysroot/CMAKE_OSX_SYSROOT (${CONDA_BUILD_SYSROOT})"
  else
    echo "  WARNING: CONDA_BUILD_SYSROOT not set or has no usr/lib — link may fail with 'library not found for -lSystem'"
  fi
fi

# non-Unix: path-length workaround, zstd config, and symbol export fixes
is_not_unix && {
    # zstd on conda-forge Windows: only libzstd.dll exists (no import library).
    # conda's zstdConfig.cmake declares zstd::libzstd_shared with IMPORTED_IMPLIB
    # pointing to a non-existent .lib file, causing cmake to error.
    # Disable zstd to avoid the broken cmake config.
    #
    # Symbol export fixes (two patches + dlltool post-processing):
    # - Patch 0004: adds --export-all-symbols to libLLVM (backport from LLVM 22.1.0)
    #   Without this, data symbols (vtables, ::ID) aren't exported.
    # - build.sh Phase 1.5/2.5: zig dlltool regenerates import libs without atexit
    #   (zig's driver rejects --exclude-symbols, so we post-process instead)
    # - CMAKE_SHARED_LINKER_FLAGS: force --export-all-symbols on ALL shared libs
    #   as a belt-and-suspenders with the CMakeLists.txt guards. This ensures
    #   libclang-cpp.dll exports all symbols even if CMake's MINGW detection
    #   doesn't trigger the if(MINGW OR CYGWIN) block.
    #
    # win-64/win-32 only: append --export-all-symbols to the shared-linker init.
    # This is the belt-and-suspenders global flag described above (previously only
    # a comment): it covers libclang-cpp.dll AND the case where CMake's MINGW var
    # is false under zig-cc (so patch 0004's if(MINGW OR CYGWIN) block never fires).
    # Excluded on win-arm64, which uses LLVM_ARM64_EXPORT_DEF (.def) instead to stay
    # under the PE/COFF 65535 export-ordinal cap.
    #
    # 2026-07-24 win-64 CI post-mortem: the raw --export-all-symbols text above IS
    # present in build.ninja's per-target LINK_FLAGS (verified by _llvm_build.sh's
    # pre-build assertion), yet libclang-cpp.dll linked with ZERO exported symbols.
    # Root cause: zig's Windows linker backend always invokes LLD's native COFF
    # driver (lld-link / MSVC option syntax), never LLD's separate GNU/MinGW
    # frontend (ld.lld -flavor gnu) — this holds even for *-windows-gnu targets,
    # confirmed by zig-wrapper.c needing hand-written per-flag GNU->MSVC
    # translations (-Wl,--stack,N -> -Wl,/STACK:N, -Wl,-Map,F -> -Wl,/MAP:F,
    # -Wl,-e<sym> -> -Wl,/ENTRY:<sym>). --export-all-symbols has no such
    # translation and no COFF-native equivalent (it is defined only in LLD's
    # MinGW option table, lld/MinGW/Options.td, not lld/COFF/Options.td), so
    # lld-link silently ignores it rather than erroring — exactly matching
    # "flag present in LINK_FLAGS, zero effect at actual link". This is the
    # same category of gap that win-arm64 already routes around below via
    # LINKER:-def:<file> (/DEF: has a native lld-link alias, so it works).
    #
    # CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS is CMake's own toolchain-agnostic
    # implementation of MinGW auto-export: it scans compiled objects for a
    # symbol list (via CMAKE_NM/dumpbin) and links with the resulting .def
    # file via /DEF:, the same COFF-native mechanism win-arm64 already proves
    # works with zig's linker.
    #
    # 2026-07-25 CI (build 1557557): CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON alone
    # produced the EXACT SAME failure as the raw --export-all-symbols flag —
    # Phase 2.5b still reports "Total symbols in libclang-cpp.dll.a: 0" and
    # "libclang-cpp.dll exported symbols (nm): 0". Confirmed root cause:
    # cmake's default CMAKE_NM discovery finds no usable nm for the zig cross
    # toolchain (only CMAKE_AR/CMAKE_RANLIB/CMAKE_C_COMPILER/CMAKE_CXX_COMPILER
    # are set in _llvm_build.sh's _CMAKE array — no CMAKE_NM), so the
    # auto-export custom-command rule that WINDOWS_EXPORT_ALL_SYMBOLS wires up
    # silently produces an empty/no export set instead of erroring.
    #
    # Fix: point CMAKE_NM at a thin .bat wrapper around `zig nm`, the same
    # mechanism win-arm64 already proves works for its extract_symbols.py
    # Stage 2 .def generation (_llvm_build.sh's zig-nm-wrapper.bat, ~line 584).
    # _zig_bindir and CONDA_ZIG_BUILD are already set globally by
    # _zig_wrappers.sh (sourced earlier in the same shell by llvm_build.sh).
    _shared_link_init="-Wl,--major-image-version,1,--minor-image-version,0"
    _win_export_all_flags=()
    if [[ "${ZIG_TRIPLET}" != aarch64-* ]]; then
        _shared_link_init+=",--export-all-symbols"
        _win_export_all_flags+=( -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON )

        mkdir -p "${LLVM_BUILD}"
        _cmake_nm_wrapper="${LLVM_BUILD}/zig-nm-wrapper.bat"
        cat > "${_cmake_nm_wrapper}" <<EOF
@echo off
"${_zig_bindir}/${CONDA_ZIG_BUILD}" nm %*
EOF
        _win_export_all_flags+=( -DCMAKE_NM="${_cmake_nm_wrapper}" )
        dbg "win-64/win-32: CMAKE_NM=${_cmake_nm_wrapper} (zig-nm wrapper, fixes CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS no-op)"
    fi
    CMAKE_PLATFORM_FLAGS+=(
      -DCMAKE_OBJECT_PATH_MAX=1024
      -DLLVM_USE_INTEL_JITEVENTS=ON
      -DLLVM_ENABLE_DUMP=ON
      -DLLVM_ENABLE_ZSTD=OFF
      -DLLVM_ENABLE_LIBXML2=OFF
      -DLLVM_EXPORT_SYMBOLS_FOR_PLUGINS=OFF
      # llvm-config.cpp uses CMAKE_CFG_INTDIR as a string literal. With Ninja
      # single-config the correct value is "." but the quotes around "Release"
      # are lost through the zig-cxx wrapper, producing a bare token (undeclared
      # identifier). Override with "." which is safe on all generators.
      -DCMAKE_CFG_INTDIR=.
      # CheckAtomic.cmake link-test for __atomic_fetch_add_4 fails on
      # aarch64-windows-gnu cross-build because zig-cc's compiler-rt (which
      # provides the atomic intrinsics) isn't linked during CMake's standalone
      # check_function_exists/check_library_exists probe. Pre-set the cache
      # variables so CheckAtomic.cmake skips its runtime probe — the intrinsics
      # are actually present at full-link time via zig-cc's bundled compiler-rt.
      # Safe on x86_64 Windows too: the variables match reality there.
      -DHAVE_CXX_ATOMICS_WITHOUT_LIB=ON
      -DHAVE_CXX_ATOMICS64_WITHOUT_LIB=ON
      -DHAVE_C_ATOMICS_WITHOUT_LIB=ON
      -DHAVE_C_ATOMICS64_WITHOUT_LIB=ON
      # zig lld-link rejects /version:0.0 (zero minor) with InvalidVersion.
      # CMake emits /version:0.0 by default for Windows executables/DLLs when
      # no version is specified. Override for all real targets here; NATIVE
      # sub-project is handled separately in _cross_compile.sh via
      # CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY (which avoids linking).
      #
      # /version:N in ALL forms (dot-decimal /version:1.0 round-3, integer-only
      # /version:1 round-4) is rejected by zig lld with InvalidVersion — zig lld
      # does not implement the MSVC lld-link /version parser.
      # GNU-ld style --major-image-version,N,--minor-image-version,N is accepted.
      # Drop /version entirely; use GNU-ld form for both EXE and SHARED.
      -DCMAKE_EXE_LINKER_FLAGS_INIT="-Wl,--major-image-version,1,--minor-image-version,0"
      -DCMAKE_SHARED_LINKER_FLAGS_INIT="${_shared_link_init}"
      "${_win_export_all_flags[@]}"
    )
}

# win-arm64: pass the .def file path to cmake so the conditional in patch 0004
# (llvm/tools/llvm-shlib/CMakeLists.txt) routes to --def instead of
# --export-all-symbols, avoiding the PE/COFF 65535 export-ordinal cap.
if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    CMAKE_PLATFORM_FLAGS+=(
      -DLLVM_ARM64_EXPORT_DEF="${LLVM_BUILD}/libLLVM.def"
    )
    dbg "win-arm64: LLVM_ARM64_EXPORT_DEF=${LLVM_BUILD}/libLLVM.def (PE 65535 export-cap workaround)"
fi

# linux cross builds (aarch64, ppc64le, riscv64, s390x): libLLVM.so is linked
# with -nostdlib++ and -Wl,-z,defs. The whole-archive LLVM .a files pull in
# libc++ symbols (operator new, std::__1::*, __cxxabiv1 vtables) that are
# undefined at link time unless libc++ is explicitly on the link line.
# libc++abi is statically merged into libc++.so.1 (LIBCXX_STATICALLY_LINK_ABI
# _IN_SHARED_LIBRARY=ON), so -lc++ alone resolves all __cxxabiv1 vtable symbols.
# libunwind is a separate shared lib (LIBUNWIND_ENABLE_SHARED=ON); its unversioned
# linker symlink (libunwind.so) is installed by the Phase-1 runtimes build.
#
# CMAKE_CXX_STANDARD_LIBRARIES: cmake appends this variable at the END of every
# C++ link line (after the archives), which is the correct slot for -lc++ when
# -nostdlib++ is active. An explicit -lc++ passes through -nostdlib++.
#
# This supersedes the broken ppc64le-only CMAKE_SHARED/EXE_LINKER_FLAGS_INIT
# block (which was overridden by _cross_compile.sh's rpath-link INIT and never
# appeared on the shlib link). CMAKE_CXX_STANDARD_LIBRARIES is not set anywhere
# else in this recipe, so there is no override risk.
#
# Path: zig-libcxx (build dep) installs shared libs to ${PREFIX}/lib/zig-llvm/lib/
# (same location used by ZIG_LIBCXX_DIR in _cross_compile.sh and ld.bfd wrapper).
if is_linux && [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    _zig_libcxx_lib="${PREFIX}/lib/zig-llvm/lib"
    CMAKE_PLATFORM_FLAGS+=(
        "-DCMAKE_CXX_STANDARD_LIBRARIES=-L${_zig_libcxx_lib} -lc++ -lunwind"
    )
    echo "  linux cross: CMAKE_CXX_STANDARD_LIBRARIES=-L${_zig_libcxx_lib} -lc++ -lunwind (libLLVM.so -nostdlib++ undefined sym fix)"
    unset _zig_libcxx_lib
fi

# === BUILD CACHE ===
# For faster iteration on packaging/tests, cache built artifacts in recipe folder
# Cache location: ${RECIPE_DIR}/cache/zig-llvm/
#
# To populate cache from a successful build:
#   cp -r output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm recipes/zig-llvm/cache/
#   cp output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm-path.txt recipes/zig-llvm/cache/
#
# Set ZIG_LLVM_FORCE_BUILD=1 to ignore cache and rebuild

CACHE_DIR="${RECIPE_DIR}/cache"

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" == "1" ]] && [[ -d "${CACHE_DIR}" ]] && \
   [[ -x "${CACHE_DIR}/bin/llvm-config" ]] && \
   [[ -n "$(ls "${CACHE_DIR}/lib/"libLLVM*.{dll,dylib,so}* 2>/dev/null | head -1)" ]]; then
  echo "=== USING CACHED LLVM BUILD ==="
  echo "  Cache found at: ${CACHE_DIR}"
  echo "  llvm-config version: $("${CACHE_DIR}/bin/llvm-config" --version)"
  echo ""
  echo "  Copying cache to: ${LLVM_INSTALL}"

  mkdir -p "${PREFIX}/lib"
  cp -a "${CACHE_DIR}" "${LLVM_INSTALL}"
  post_install
  build_lld_bundle
  remove_unneeded
  fix_lld_cmake_deps

  # Create marker file
  echo "${LLVM_INSTALL}" > "$(dirname "${LLVM_INSTALL}")/zig-llvm-path.txt"

  echo "  Cache installed successfully!"
  echo "  Set ZIG_LLVM_FORCE_BUILD=1 to rebuild from source"
  ls -la "${LLVM_INSTALL}/lib/"*.so* | head -10
  exit 0
fi

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" != "1" ]]; then
  echo "=== LLVM Full BUILD (ZIG_LLVM_SKIP_BUILD=0) ==="
elif [[ -d "${CACHE_DIR}" ]]; then
  echo "=== Cache found but incomplete, rebuilding ==="
else
  echo "=== No cache found, building from source ==="
  dbg "To speed up future builds, populate cache after successful build:"
  dbg "  mkdir -p ${RECIPE_DIR}/cache"
  dbg "  cp -r \${PREFIX}/lib/zig-llvm ${RECIPE_DIR}/cache/"
fi

