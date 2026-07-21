# Clear conda's compiler flags — zig handles optimization internally.
# CMAKE_ARGS: conda-build sets this with architecture-specific flags (e.g.
# -DCMAKE_OSX_ARCHITECTURES=x86_64, -mcpu=core2 for osx-64 cross-builds)
# that conflict with zig's own target/CPU handling.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CMAKE_ARGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""


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
#
# riscv64 is excluded from this pin: zstd is disabled entirely for riscv64
# below (CMAKE_DISABLE_FIND_PACKAGE_zstd=ON means find_package(zstd) never
# runs there), so pinning zstd_DIR/_LIBRARY/_INCLUDE_DIR for riscv64 would
# just be dead cache entries that are never consulted.
# --------------------------------------------------------------------
if is_linux && [[ "${target_platform}" != "linux-riscv64" ]] && [[ -d "${PREFIX}/lib/zig-zstd/lib/cmake/zstd" ]]; then
    CMAKE_PLATFORM_FLAGS+=(
        -Dzstd_DIR:PATH="${PREFIX}/lib/zig-zstd/lib/cmake/zstd"
        -Dzstd_LIBRARY:FILEPATH="${PREFIX}/lib/zig-zstd/lib/libzstd.so"
        -Dzstd_INCLUDE_DIR:PATH="${PREFIX}/lib/zig-zstd/include"
    )
    dbg "cmake_flags: zstd pinned to zig-zstd layout"
elif is_linux; then
    dbg "cmake_flags: zig-zstd not installed, leaving zstd to CMAKE_PREFIX_PATH"
fi
# riscv64: find_package(zstd) can re-resolve against ${BUILD_PREFIX}/lib/libzstd.so
# via CMAKE_PREFIX_PATH (set in _llvm_build.sh), and the native x86_64 libzstd.so
# then fails the target link with "libzstd.so is incompatible with elf64lriscv".
# Disable zstd entirely for riscv64 rather than fighting resolution order
# (matches the reference feedstock).
if [[ "${target_platform}" == "linux-riscv64" ]]; then
    CMAKE_PLATFORM_FLAGS+=(
        -DLLVM_ENABLE_ZSTD=OFF
        -DCMAKE_DISABLE_FIND_PACKAGE_zstd=ON
    )
    dbg "cmake_flags: riscv64 zstd disabled entirely (host x86_64 libzstd.so ELF-arch leak fix)"
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

  # macOS: zig 0.15.2 build 27 rejects -Wl,-syslibroot outright (unsupported linker arg).
  # Rely on compiler-driven -isysroot instead (cmake sets it via CMAKE_OSX_SYSROOT).
  # If '-lSystem not found' resurfaces, use a zig-native --sysroot flag, not -syslibroot.
  if [[ -n "${CONDA_BUILD_SYSROOT:-}" && -d "${CONDA_BUILD_SYSROOT}/usr/lib" ]]; then
    dbg "macOS sysroot: relying on -isysroot/CMAKE_OSX_SYSROOT (${CONDA_BUILD_SYSROOT})"
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
    CMAKE_PLATFORM_FLAGS=(
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
      # MSVC-style /version:N forms are rejected by zig lld (InvalidVersion); use GNU-ld style below.
      -DCMAKE_EXE_LINKER_FLAGS_INIT="-Wl,--major-image-version,1,--minor-image-version,0"
      -DCMAKE_SHARED_LINKER_FLAGS_INIT="-Wl,--export-all-symbols,--major-image-version,1,--minor-image-version,0"
      # PR #123 win-64: the final libclang-cpp.dll link (~1500 archives) died with
      # `Argument list too long` at the bash wrapper's exec of zig.exe, BEFORE zig
      # ran. CMake already rsp-files the OBJECT list; this forces ninja to rsp-file
      # the FLAG portion of link/compile lines too, shrinking the wrapper's own argv.
      # Cheap and low-risk, but insufficient alone if the real bloat is the ENV block
      # (see the exec-size diagnostics added to _llvm_build.sh Phase 2).
      -DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON
    )
}

# win-arm64: pass the .def file path to cmake so the conditional in patch 0004
# (llvm/tools/llvm-shlib/CMakeLists.txt) routes to --def instead of
# --export-all-symbols, avoiding the PE/COFF 65535 export-ordinal cap.
if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    CMAKE_PLATFORM_FLAGS+=(
      -DLLVM_ARM64_EXPORT_DEF="${LLVM_BUILD}/libLLVM.def"
    )
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
    dbg "linux cross: CMAKE_CXX_STANDARD_LIBRARIES=-L${_zig_libcxx_lib} -lc++ -lunwind (libLLVM.so -nostdlib++ undefined sym fix)"
    unset _zig_libcxx_lib
fi

