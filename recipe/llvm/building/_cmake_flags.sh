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
  )

  # zig's self-hosted Mach-O linker rejects -Wl,-syslibroot; the wrapper's
  # _use_lld=0 macOS override makes the lld pass-through dead. Use CMAKE_OSX_SYSROOT
  # so cmake propagates the SDK to all compile steps via -isysroot (which the
  # zig wrapper rewrites to the conda SDK).
  if [[ -n "${CONDA_BUILD_SYSROOT:-}" && -d "${CONDA_BUILD_SYSROOT}/usr/lib" ]]; then
    CMAKE_CROSS_FLAGS+=("-DCMAKE_OSX_SYSROOT=${CONDA_BUILD_SYSROOT}")
    echo "DBG cmake_flags: CMAKE_OSX_SYSROOT=${CONDA_BUILD_SYSROOT}"
    echo "DBG cmake_flags: ZIG_CC=${ZIG_CC:-unset}"
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

# === Hotfix: ppc64le wrapper LLD block ===
# The zig wrapper hard-errors on ppc64le when it sees standard ELF linker flags
# (--version-script, --gc-sections, etc.) because it classifies them as "LLD-only"
# and LLD lacks ppc64le relocation support. But these flags are standard GNU ld
# flags that ld.bfd handles natively. Patch the installed wrapper to:
# 1. Only error on explicit -fuse-ld=lld, not auto-promoted ELF flags
# 2. Filter -Bsymbolic* on ppc64le (zig's self-hosted linker rejects it before ld.bfd)
# TODO: Remove once zig-feedstock publishes a build with this fix.
_zig_common="${ZIG_WRAPPERS}/_zig-cc-common.sh"
if [[ -f "${_zig_common}" ]] && grep -q 'Block LLD on ppc64le' "${_zig_common}" 2>/dev/null; then
    echo "=== Patching installed zig wrapper for ppc64le LLD compatibility ==="
    python3 - "${_zig_common}" << 'PATCH_EOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
# 1. Replace hard-error LLD block with graceful fallback:
#    only error on explicit -fuse-ld=lld, reset _use_lld=0 for auto-promoted flags
old_block = re.compile(r'# --- Block LLD on ppc64le.*?^fi', re.MULTILINE | re.DOTALL)
new_block = (
    '# --- ppc64le: LLD lacks relocation support, but ld.bfd handles ELF flags ---\n'
    'if (( _use_lld )) && [[ "powerpc64le" == "powerpc64le" ]]; then\n'
    '    _explicit_lld=0\n'
    '    for _a in "$@"; do\n'
    '        [[ "$_a" == "-fuse-ld=lld" ]] && _explicit_lld=1 && break\n'
    '    done\n'
    '    if (( _explicit_lld )); then\n'
    '        echo "zig cc: error: -fuse-ld=lld is not supported on ppc64le" >&2\n'
    '        exit 1\n'
    '    fi\n'
    '    _use_lld=0\n'
    'fi'
)
t = old_block.sub(new_block, t)
# 2. Filter -Bsymbolic* on ppc64le (zig rejects before ld.bfd sees it)
rpath_line = '-Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags) ;;'
if rpath_line in t and 'Bsymbolic) ;;' not in t:
    t = t.replace(
        rpath_line,
        '-Wl,-Bsymbolic-functions|-Wl,-Bsymbolic|-Bsymbolic-functions|-Bsymbolic) ;;\n'
        '        ' + rpath_line
    )
open(p, 'w').write(t)
print('  Wrapper patched successfully')
PATCH_EOF
fi

