_CLANG=(
  -DCLANG_ENABLE_OBJC_REWRITER=ON
  -DCLANG_LINK_CLANG_DYLIB=ON

  -DCLANG_BUILD_TOOLS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_TOOL_APINOTES_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_DIFF_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

# LLVM_TARGETS_TO_BUILD: full standard-target list matching zig's unconditional
# LLVMInitialize<Target>AsmPrinter/AsmParser call sites. On aarch64-windows-gnu
# the resulting libLLVM-20.dll would exceed the PE/COFF 65535 export-ordinal
# limit because GPU + many backends have large TableGen instruction-selection
# tables. Keep the win-arm64 pruned list to three safe targets only.
_llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX;BPF;Hexagon;Lanai;LoongArch;Mips;MSP430;Sparc;VE;XCore"
# SPIRV is experimental (not part of LLVM_TARGETS_TO_BUILD) but zig calls
# LLVMInitializeSPIRVAsmPrinter unconditionally — build it as an experimental
# target so the symbol resolves at link time.
_llvm_experimental_targets="SPIRV"
if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    _llvm_targets="X86;AArch64;WebAssembly"
    _llvm_experimental_targets=""
    echo "  win-arm64: pruned LLVM_TARGETS_TO_BUILD (dropped ARM, RISCV, AVR, AMDGPU, NVPTX, PowerPC, SystemZ, BPF, Hexagon, Lanai, LoongArch, Mips, MSP430, Sparc, VE, XCore) to fit PE/COFF 65535 export limit"
fi

_LLVM=(
  # LLVM_BUILD_TOOLS=ON with individual disables. Both ON and OFF are "leaky":
  # ON requires explicit disables per tool (whack-a-mole on LLVM bumps).
  # OFF prevents cmake --install from installing even whitelisted tools.
  # ON + explicit list is the lesser evil — at least llvm-config gets installed.
  -DLLVM_BUILD_TOOLS=ON
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DYLIB_COMPONENTS="all"
  -DLLVM_ENABLE_LIBCXX=ON
  -DLLVM_ENABLE_LIBXML2=ON
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_TARGETS_TO_BUILD="${_llvm_targets}"

  -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_BACKTRACES=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_CRASH_OVERRIDES=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DLLVM_ENABLE_PLUGINS=OFF
  -DLLVM_ENABLE_Z3_SOLVER=OFF
  -DLLVM_HAS_LOGF128=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF
  # Disable ALL tools except llvm-config and llvm-shlib (libLLVM.so/.dylib).
  # Generated from LLVM 20.1.8 llvm/tools/ source tree (add_llvm_implicit_projects
  # auto-discovers every subdirectory with CMakeLists.txt via file(GLOB)).
  # LLVM_BUILD_TOOLS=ON is REQUIRED — OFF prevents cmake --install from installing
  # even whitelisted tools. Individual LLVM_TOOL_*_BUILD=OFF skips add_subdirectory()
  # entirely (no configure, no build, no install).
  # On macOS: tools linking against libLLVM.dylib fail (zig cc visibility issue).
  # On Windows: saves ~60min build time.
  # KEEP: llvm-config (ON above), llvm-shlib (builds libLLVM shared library)
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF
  -DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_DXIL_DIS_BUILD=OFF
  -DLLVM_TOOL_GOLD_BUILD=OFF
  -DLLVM_TOOL_LLC_BUILD=OFF
  -DLLVM_TOOL_LLI_BUILD=OFF
  -DLLVM_TOOL_LLVM_AR_BUILD=ON  # ON: llvm-ar creates llvm-dlltool symlink (needed for MinGW import lib generation)
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF
  -DLLVM_TOOL_LLVM_CGDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF
  -DLLVM_TOOL_LLVM_CTXPROF_UTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF
  -DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DRIVER_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF
  -DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF
  -DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF
  -DLLVM_TOOL_LLVM_NM_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF
  -DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF
  -DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF
  -DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIZE_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF
  -DLLVM_TOOL_LTO_BUILD=OFF
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF
  -DLLVM_TOOL_OPT_BUILD=OFF
  -DLLVM_TOOL_OPT_VIEWER_BUILD=OFF
  -DLLVM_TOOL_REDUCE_CHUNK_LIST_BUILD=OFF
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF
  -DLLVM_TOOL_SANCOV_BUILD=OFF
  -DLLVM_TOOL_SANSTATS_BUILD=OFF
  -DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF
  -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF
  -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF
  -DLLVM_TOOL_YAML2OBJ_BUILD=OFF
)
if [[ -n "${_llvm_experimental_targets}" ]]; then
    _LLVM+=("-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=${_llvm_experimental_targets}")
fi

# BLAKE3 asm guard: LLVM's lib/Support/BLAKE3/CMakeLists runs
# check_symbol_exists(__x86_64__) with ZIG_CC, which targets the OUTPUT
# platform (x86_64), so IS_X64=TRUE and it appends the x86 AVX-512 asm with
# -mavx512vl. On a non-x86_64 build host that object is assembled for the host
# arch (e.g. aarch64), which has no avx512vl -> ISA error. Disable asm-file
# selection on non-x86_64 hosts; the portable C + NEON BLAKE3 path is used
# instead (negligible perf cost — BLAKE3 is only used for LLVM module hashing).
if [[ "$(uname -m)" != "x86_64" ]]; then
  _LLVM+=(-DLLVM_DISABLE_ASSEMBLY_FILES=ON)
fi

# === Host tablegen pre-build + tablegen bypass flags ===
# Must run HERE (in _llvm_build.sh) — NOT in _cross_compile.sh — because the
# wrapper binaries (${BUILD_PREFIX}/bin/<triplet>-zig-cc) are compiled by
# _zig_wrappers.sh, which build.sh sources AFTER _cross_compile.sh
# but BEFORE _llvm_build.sh.  Calling cmake with a non-existent C compiler
# triggers "is not a full path to an existing compiler tool".
#
# After the pre-build, we append LLVM_TABLEGEN / CLANG_TABLEGEN_EXE /
# LLVM_NATIVE_TOOL_DIR to CMAKE_CROSS_FLAGS so the main cmake invocation
# below uses host-runnable binaries instead of cross-compiled ones.
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  _host_tblgen_build="${SRC_DIR}/_host_tblgen_build"

  if is_linux; then
    # _native_zig_{cc,cxx,asm} and _native_zig_triplet were set in
    # _cross_compile.sh — they are shell variables still in scope.
    if [[ ! -x "${_host_tblgen_build}/bin/llvm-tblgen" ]]; then
      echo "Pre-building host llvm-tblgen + clang-tblgen for linux cross-compile..."
      cmake -G Ninja -S "${LLVM_SRC}" -B "${_host_tblgen_build}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${_native_zig_cc}" \
        -DCMAKE_CXX_COMPILER="${_native_zig_cxx}" \
        -DCMAKE_ASM_COMPILER="${_native_zig_asm}" \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_ASM_COMPILER_WORKS=TRUE \
        -DLLVM_TARGETS_TO_BUILD=host \
        -DLLVM_ENABLE_PROJECTS='clang' \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF
      cmake --build "${_host_tblgen_build}" --target llvm-tblgen llvm-min-tblgen clang-tblgen
    fi
  elif is_osx; then
    if [[ ! -x "${_host_tblgen_build}/bin/llvm-tblgen" ]]; then
      echo "Pre-building host llvm-tblgen + clang-tblgen for osx cross-compile..."
      cmake -G Ninja -S "${LLVM_SRC}" -B "${_host_tblgen_build}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${_native_zig_cc}" \
        -DCMAKE_CXX_COMPILER="${_native_zig_cxx}" \
        -DCMAKE_ASM_COMPILER="${_native_zig_asm}" \
        -DCMAKE_OSX_SYSROOT="${CONDA_BUILD_SYSROOT}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_ASM_COMPILER_WORKS=TRUE \
        -DLLVM_TARGETS_TO_BUILD=host \
        -DLLVM_ENABLE_PROJECTS='clang' \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF
      cmake --build "${_host_tblgen_build}" --target llvm-tblgen llvm-min-tblgen clang-tblgen
    fi
  fi

  # Tablegen bypass flags: set LLVM_TBLGEN / CLANG_TBLGEN and append to
  # CMAKE_CROSS_FLAGS.  For linux/osx the pre-build above provides binaries;
  # for windows cross-builds fall back to finding tblgen in BUILD_PREFIX
  # (provided by zig-llvm as a build dep).
  if is_linux || is_osx; then
    LLVM_TBLGEN="${_host_tblgen_build}/bin/llvm-tblgen"
    CLANG_TBLGEN="${_host_tblgen_build}/bin/clang-tblgen"
    echo "  LLVM_TBLGEN resolved to: ${LLVM_TBLGEN} (pre-built host tool)"
    echo "  CLANG_TBLGEN resolved to: ${CLANG_TBLGEN} (pre-built host tool)"
  else
    # Windows cross-build: find tblgen from BUILD_PREFIX (zig-llvm build dep).
    if [[ -z "${LLVM_TBLGEN:-}" ]]; then
      LLVM_TBLGEN=$(find "${BUILD_PREFIX}" \
          \( -name llvm-tblgen -o -name llvm-tblgen.exe \) \
          ! -name 'llvm-min-tblgen' ! -name 'llvm-min-tblgen.exe' \
          -type f 2>/dev/null | head -1)
      echo "  LLVM_TBLGEN resolved to: ${LLVM_TBLGEN:-<not found>} (from BUILD_PREFIX)"
    fi
    CLANG_TBLGEN=$(find "${BUILD_PREFIX}" \
        \( -name clang-tblgen -o -name clang-tblgen.exe \) \
        -type f 2>/dev/null | head -1)
    echo "  CLANG_TBLGEN resolved to: ${CLANG_TBLGEN:-<not found>} (from BUILD_PREFIX)"
  fi

  # Append tablegen bypass flags to CMAKE_CROSS_FLAGS (already populated by
  # _cross_compile.sh with CROSS_TOOLCHAIN_FLAGS_NATIVE, compiler-target, etc.).
  if [[ -n "${LLVM_TBLGEN:-}" ]]; then
    # LLVM 20+ TableGen variable resolution:
    #   LLVM_TABLEGEN: legacy cache variable (still honored).
    #   LLVM_TABLEGEN_EXE: internal var consulted by tablegen() macro on LLVM 20+.
    #     Without this, the macro may fall back to MIN tblgen for some generators
    #     (e.g. -gen-asm-matcher on WebAssembly), producing "Unknown command line argument" errors.
    #   LLVM_MIN_TABLEGEN_EXE: bootstrap-only minimal tblgen. Pointed at the FULL
    #     llvm-tblgen since it is a strict superset (handles every generator
    #     min-tblgen handles, plus the rest). Safe and avoids the asm-matcher mismatch.
    CMAKE_CROSS_FLAGS+=(
      -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
      -DLLVM_TABLEGEN_EXE="${LLVM_TBLGEN}"
      -DLLVM_MIN_TABLEGEN_EXE="${LLVM_TBLGEN}"
      # LLVM_MIN_TABLEGEN (no _EXE suffix) is the cache variable LLVM's
      # CrossCompile.cmake reads to skip compiling llvm-min-tblgen from
      # source. Without this, LLVM still tries to build min-tblgen via
      # the outer cross-target CMake (using ZIG_CC=riscv64 wrapper),
      # which fails to link against x86_64 BUILD_PREFIX/lib/libzstd.so.
      -DLLVM_MIN_TABLEGEN="${LLVM_TBLGEN}"
    )
    # Pre-built tablegen dir: tells CrossCompile.cmake where to find llvm-tblgen
    # without triggering a NATIVE sub-cmake rebuild.
    _tblgen_dir=$(dirname "${LLVM_TBLGEN}")
    CMAKE_CROSS_FLAGS+=(-DLLVM_NATIVE_TOOL_DIR="${_tblgen_dir}")
  else
    echo "WARNING: LLVM_TBLGEN not found — cross tablegen will likely fail"
  fi
  [[ -n "${CLANG_TBLGEN:-}" ]] && CMAKE_CROSS_FLAGS+=(-DCLANG_TABLEGEN_EXE="${CLANG_TBLGEN}")

  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN:-<not set>}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN:-<not set>}"
  echo "  LLVM_NATIVE_TOOL_DIR: ${_tblgen_dir:-<not set>}"
fi
# === End host tablegen pre-build ===

echo "=== Configuring LLVM ==="
echo "  Install prefix: ${LLVM_INSTALL} (separate from conda-forge llvmdev)"
_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  # Exclude $BUILD_PREFIX from CMAKE_PREFIX_PATH on cross-builds: it contains
  # x86_64 host libs that must never link into target-arch artifacts (see
  # ld.lld 'incompatible with elf64lriscv' style errors). Native build-tools
  # are located via PATH, not find_package. On native builds, $BUILD_PREFIX
  # is retained for parity with the prior behavior.
  -DCMAKE_PREFIX_PATH="${LLVM_INSTALL};${PREFIX}$( [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]] || echo ";${BUILD_PREFIX}" )"
  -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF

  -DCMAKE_AR="${ZIG_AR}"
  -DCMAKE_C_COMPILER="${ZIG_CC}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
  -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
  -DCMAKE_RANLIB="${ZIG_RANLIB}"

  # Rpath settings - build tools (llvm-min-tblgen, etc) need to find conda libs at runtime
  # LLVM_BUILD/lib is where libLLVM.so lives during the build phase - required so
  # libclang-cpp.so links against it by bare soname (not a relative lib/ path).
  -DCMAKE_BUILD_RPATH="${LLVM_INSTALL}/lib;${LLVM_BUILD}/lib;${BUILD_PREFIX}/lib;${PREFIX}/lib"
  -DCMAKE_INSTALL_RPATH="${LLVM_INSTALL}/lib"

  -DCMAKE_C_FLAGS="-fvisibility=default"
  # Isolate the C++ compile from zig's BUNDLED libc++ headers. The bootstrap
  # zig (0.16.0) ships libc++ 21.1.0 headers (lib/zig/libcxx/include) that
  # `zig c++` auto-injects; they declare std::__1::__hash_memory (new in libc++
  # 21) which the recipe's linked libc++ 20.1.8 never implements -> ld.lld
  # undefined symbol when linking llvm-tblgen. -nostdinc++ drops zig's bundled
  # headers (zig cc is clang; the wrapper forwards -nostdinc++ untouched);
  # -I (NOT -isystem) points at the freshly-built 20.1.8 libc++ headers so they
  # are searched in clang's user bracket, BEFORE zig's bundled glibc C-header
  # dir. libc++'s <cstring>/<cmath> require libc++'s own v1/string.h,math.h to
  # win over glibc's (they #include_next the real ones); with -isystem, zig's
  # glibc dir preceded v1 and libc++ #error'd "didn't find libc++'s <string.h>"
  # (CheckAtomic failure). -I fixes the order. __config_site is present under
  # ${LLVM_INSTALL}/include/c++/v1 so compile and link both use 20.1.8.
  -DCMAKE_CXX_FLAGS="-fvisibility=default -nostdinc++ -I${LLVM_INSTALL}/include/c++/v1"

  # -nostdinc++ (above) also lands on the LINK line, which makes zig cc STOP
  # auto-linking its bundled libc++ -> a flood of undefined std::__1::/operator
  # new-delete/__cxa_/vtable-__cxxabiv1 symbols at the first executable link
  # (llvm-min-tblgen). Explicitly link the freshly-built 20.1.8 libc++/libc++abi/
  # libunwind. CMAKE_CXX_STANDARD_LIBRARIES is appended at the END of every C++
  # link line (after objects and the static libLLVM*.a), which is required so
  # those archives' libc++ references resolve, and it survives -Wl,--as-needed.
  # libc++abi is static-only (.a); libunwind is shared; all under ${LLVM_INSTALL}/lib.
  "-DCMAKE_CXX_STANDARD_LIBRARIES=-L${LLVM_INSTALL}/lib -lc++ -lc++abi -lunwind"
)

# Inject glibc-capped target to zig-cc so libclang-cpp.so and liblld.so don't
# reference newer glibc symbols than the .2.17 cap allows (ZIG_TRIPLET comes
# from recipe.yaml env, e.g. x86_64-linux-gnu.2.17 on linux-64).
if is_linux; then
  _CMAKE+=(
    "-DCMAKE_C_COMPILER_TARGET=${ZIG_TRIPLET}"
    "-DCMAKE_CXX_COMPILER_TARGET=${ZIG_TRIPLET}"
  )
fi

# RC compiler (resource compiler for Windows .exe version info).
# On Windows, Platform/Windows-GNU.cmake auto-enables RC language during
# project(). CMake 4.2 converts ALL paths to native backslashes, then chokes
# on escape sequences (\a from D:\a\..., \p from \package-..., etc.) when
# writing CMakeRCCompiler.cmake. EVERY Windows CI path triggers this.
# Semicolon syntax ("zig;rc") also fails — get_filename_component treats
# "rc" as a component arg.
#
# Since we use zig (Clang, not MSVC), the RC resource is never compiled
# (add_windows_version_resource_file guards on MSVC).
# Fix: use _BUILD_PREFIX (forward-slash unix path) in the -C initial-cache
# script. Forward slashes have no escape issues in CMake string literals.
# Two cmake script files:
#
# 1. _cmake_init.cmake: initial-cache file (-C). For CACHE variables only
#    (e.g. RC compiler). Loaded before project().
#
# 2. _cmake_project_include.cmake: project include file
#    (-DCMAKE_PROJECT_INCLUDE=...). Runs as the LAST step of project(),
#    AFTER all language initialization and platform modules.
#    Sets CMAKE_CXX_CREATE_SHARED_LIBRARY as a normal variable in the
#    top-level project scope — guaranteed to override any platform default.
#
#    Approaches that FAILED (CI confirmed):
#    - -D: creates :UNINITIALIZED cache entry, overridden by platform module
#      (win-64, 2026-03-21)
#    - -C with CACHE FORCE: cache var overridden by normal var from platform
#      module (osx-arm64, 2026-03-22)
#    - CMAKE_USER_MAKE_RULES_OVERRIDE: loaded during language init but
#      overridden by later platform module processing (osx-arm64, 2026-03-22)
_cmake_init="${SRC_DIR}/_cmake_init.cmake"
_cmake_project_include="${SRC_DIR}/_cmake_project_include.cmake"
: > "${_cmake_init}"
: > "${_cmake_project_include}"
# Diagnostic: cmake will print this message if the project include file is read.
cat >> "${_cmake_project_include}" << 'CMINIT'
message(STATUS ">>> CMAKE_PROJECT_INCLUDE: file loaded successfully")
CMINIT

CMAKE_RC_FLAGS=()
if is_not_unix; then
  # _BUILD_PREFIX: forward-slash unix path version of BUILD_PREFIX,
  # created by build.bat (e.g. /d/a/package-incubator/.../build_env).
  _rc_path="${_BUILD_PREFIX}/Library/bin/${ZIG_TARGET_HOST}-zig-rc.exe"
  cat >> "${_cmake_init}" << CMINIT
# RC compiler with forward-slash path — avoids CMake 4.2 backslash escape bug.
set(CMAKE_RC_COMPILER "${_rc_path}" CACHE FILEPATH "RC compiler")
set(CMAKE_RC_COMPILER_WORKS TRUE CACHE BOOL "RC compiler works")
CMINIT
elif [[ -n "${ZIG_RC:-}" ]]; then
  CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

ulimit -n 4096 2>/dev/null || true
echo "=== cmake initial-cache file (${_cmake_init}) ==="
sed 's/^/  /' "${_cmake_init}" || true
echo "=== cmake project include file (${_cmake_project_include}) ==="
sed 's/^/  /' "${_cmake_project_include}" || true

# Tail-visible zstd diagnostic via EXIT trap so it fires on both success and
# ninja failure (set -e otherwise exits before our inline diagnostic).
if [[ "${target_platform}" == "linux-"* ]]; then
  _zstd_diag() {
    if [[ -f "${LLVM_BUILD}/CMakeCache.txt" ]]; then
      echo "=== zstd CMake resolution (tail-visible, on-exit) ==="
      grep -iE '^zstd|libzstd' "${LLVM_BUILD}/CMakeCache.txt" 2>/dev/null || true
      echo "===================================================="
    fi
  }
  trap '_zstd_diag' EXIT
fi

cmake "-C${_cmake_init}" \
  -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
  -DCMAKE_PROJECT_INCLUDE="${_cmake_project_include}" \
  "${CMAKE_CROSS_FLAGS[@]}" \
  "${CMAKE_PLATFORM_FLAGS[@]}" \
  "${CMAKE_RC_FLAGS[@]}" \
  -DHAS_LOGF128=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  "${_CMAKE[@]}" \
  "${_CLANG[@]}" \
  "${_LLVM[@]}" \
  -G Ninja

  # Diagnostic: confirm CMake resolved zstd to the riscv64 zig-zstd, not BUILD_PREFIX x86_64.
  # If this regresses, the link will fail with 'incompatible with elf64lriscv'.
  echo "=== zstd CMake resolution ==="
  grep -i '^zstd' "${LLVM_BUILD}/CMakeCache.txt" 2>/dev/null || true
  echo "============================="

  # === ppc64le ld.real shim (Option A diagnostic) ===
  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    _ld_real="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld.real"
    _ld_orig="${_ld_real}.orig"
    _ld_log="${LLVM_BUILD}/ld-real-invocations.log"
    if [[ -f "${_ld_real}" && ! -f "${_ld_orig}" ]]; then
      cp "${_ld_real}" "${_ld_orig}"
      cat > "${_ld_real}" <<LDSHIM
#!/usr/bin/env bash
{
  printf '\\n[%s] cwd=%s\\n' "\$(date +%H:%M:%S.%N)" "\$(pwd)"
  printf '  argv (\$# args):\\n'
  for _a in "\$@"; do printf '    %s\\n' "\$_a"; done
  printf '  --- end ---\\n'
} >> "${_ld_log}" 2>/dev/null
exec "${_ld_orig}" "\$@"
LDSHIM
      chmod +x "${_ld_real}"
      echo "[ld-shim] installed: ${_ld_real} (orig at ${_ld_orig}, log at ${_ld_log})"
    fi
  fi

  # === ppc64le SONAME probe (Option B diagnostic) ===
  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    echo "=== ppc64le pre-link SONAME probe ==="
    for _dir in "${PREFIX}/lib" "${PREFIX}/lib/zig-zstd/lib" \
                "${PREFIX}/lib/zig-zlib/lib" "${PREFIX}/lib/zig-libxml2/lib" \
                "${PREFIX}/lib/zig-xml2/lib" "${BUILD_PREFIX}/lib"; do
      echo "--- ${_dir} ---"
      if [[ -d "${_dir}" ]]; then
        ls -la "${_dir}"/libzstd* "${_dir}"/libz.so* "${_dir}"/libxml2.so* \
          2>/dev/null | sed 's/^/  /' || echo "  (no matching SONAMEs)"
      else
        echo "  (directory does not exist)"
      fi
    done
    echo "===================================="
  fi

# === Quick-fail: verify --export-all-symbols in ALL shared library link rules ===
# libLLVM and libclang-cpp each get their own CXX_SHARED_LIBRARY_LINKER rule in
# rules.ninja.  If --export-all-symbols is missing from either, the import lib
# will be 8 KiB instead of 100+ KiB — but we'd only discover that AFTER 2+ hours.
#
# win-arm64: skip this assertion — patch 0004 routes to --def (not --export-all-symbols)
# for aarch64 to avoid the PE/COFF 65535 export-ordinal cap. The .def file is generated
# in Phase 0 below; its presence (not --export-all-symbols) is what matters there.
if is_not_unix && ! { [[ "${ZIG_TRIPLET}" == aarch64-* ]]; }; then
  { set +x; } 2>/dev/null
  echo "=== Quick-fail: verifying --export-all-symbols in ALL shared library rules ==="
  _export_fail=0
  while IFS= read -r _rule_name; do
    # Extract the command line for this rule (next 8 lines after the rule declaration)
    _rule_cmd=$(grep -A8 "^rule ${_rule_name}$" "${_rules_ninja}" 2>/dev/null | grep 'command =' || true)
    echo "  ${_rule_name}:"
    if echo "${_rule_cmd}" | grep -q 'export-all-symbols'; then
      echo "    OK: --export-all-symbols present"
    else
      echo "    FAIL: --export-all-symbols NOT in command line!"
      echo "    command = ${_rule_cmd}"
      _export_fail=1
    fi
  done < <(grep '^rule CXX_SHARED_LIBRARY_LINKER' "${_rules_ninja}" 2>/dev/null | sed 's/^rule //')
  if [[ ${_export_fail} -ne 0 ]]; then
    echo "  FATAL: --export-all-symbols missing from one or more shared library link rules."
    echo "  libclang-cpp.dll.a will be ~8 KiB instead of 100+ KiB."
    echo "  Aborting to avoid wasting 2+ hours on a build that will fail."
    set -x
    exit 1
  fi
  echo "  All shared library rules have --export-all-symbols"
  set -x
elif is_not_unix && [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
  dbg "win-arm64: skipping --export-all-symbols ninja-rule assertion (using .def file instead)"
fi


echo "=== Building LLVM ==="
if is_not_unix; then
  # Two-phase build on Windows:
  # Phase 1: Build libLLVM.dll (patch 0004 adds --export-all-symbols for data symbols)
  # Phase 1.5: atexit from dllcrt2.obj leaks into the import lib via --export-all-symbols.
  #   Zig's driver rejects --exclude-symbols. We use ar d to surgically remove the atexit
  #   import entry, preserving the short-import format. This prevents duplicate symbol
  #   errors in Phase 2 when libclang-cpp links against the cleaned import lib.
  # Phase 2: Build everything else (libclang-cpp links against cleaned import lib)

  # Add libc++ DLL location to PATH so build-time executables (llvm-min-tblgen etc.)
  # can find libc++.dll at runtime.  With zig _14's libc++ probe, zig links
  # executables against shared libc++ — but the DLL must be discoverable via PATH.
  export PATH="${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
  echo "  Added ${LLVM_INSTALL}/bin and lib to PATH for runtime DLL discovery"

  # Phase 1: Build libLLVM DLL only.
  # win-arm64: two-stage pre-link approach to generate libLLVM.def before the dll
  # link runs (PE/COFF 65535 export-ordinal cap workaround via patch 0004 --def flag).
  # Stage 1 builds LLVM static archives; Stage 2 generates libLLVM.def from them;
  # Stage 3 then links libLLVM-20.dll using the .def file.
  # Other Windows targets: single cmake --build --target LLVM as before.
  echo "  Phase 1: Building LLVM shared library..."
  if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
    dbg "win-arm64: two-stage build to generate libLLVM.def before dll link"

    # Stage 1: build LLVM static archives WITHOUT the libLLVM dll.
    # Strategy: build a representative set of LLVM* static lib targets that pull in
    # all transitive LLVM* static archives via ninja dependency resolution.
    # These are always present regardless of LLVM_TARGETS_TO_BUILD pruning.
    # AArch64/X86/WebAssembly backends are included because our pruned target list
    # is exactly X86;AArch64;WebAssembly for win-arm64 (see _llvm_targets above).
    cmake --build "${LLVM_BUILD}" --config Release -- \
      LLVMSupport LLVMCore LLVMMC LLVMAnalysis LLVMTransformUtils LLVMCodeGen \
      LLVMTarget LLVMMCParser LLVMBinaryFormat LLVMBitWriter LLVMBitReader \
      LLVMAArch64CodeGen LLVMAArch64AsmParser LLVMAArch64Desc LLVMAArch64Info LLVMAArch64Utils \
      LLVMX86CodeGen LLVMX86AsmParser LLVMX86Desc LLVMX86Info \
      LLVMWebAssemblyCodeGen LLVMWebAssemblyAsmParser LLVMWebAssemblyDesc LLVMWebAssemblyInfo
    # ninja resolves transitive deps; this populates ${LLVM_BUILD}/lib/*.lib with all
    # LLVM core + 3-target backend statics.

    # Stage 2: generate libLLVM.def from the static archives.
    # === win-arm64: libLLVM.def diagnostics + multi-attempt extraction ===
    _def_out="${LLVM_BUILD}/libLLVM.def"
    _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

    echo "=== win-arm64 extract_symbols diagnostics ==="

    echo "--- nm tools available ---"
    if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm" ]]; then
      echo "  Library/bin/llvm-nm (Windows path): FOUND"
      "${BUILD_PREFIX}/Library/bin/llvm-nm" --version 2>&1 | head -5
    elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" ]]; then
      echo "  Library/bin/llvm-nm.exe: FOUND"
      "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" --version 2>&1 | head -5
    elif [[ -x "${BUILD_PREFIX}/bin/llvm-nm" ]]; then
      echo "  bin/llvm-nm (fallback): FOUND"
      "${BUILD_PREFIX}/bin/llvm-nm" --version 2>&1 | head -5
    else
      echo "  host llvm-nm: NOT FOUND in Library/bin or bin"
    fi
    "${_zig_bin}" version 2>&1 | head -3 \
      || echo "  zig: NOT FOUND or errored"

    echo "--- extract_symbols.py --help ---"
    python3 "${LLVM_SRC}/utils/extract_symbols.py" --help 2>&1 | head -40 || true

    echo "--- archive listing (LLVM*.lib + libLLVM*.a) ---"
    shopt -s nullglob
    _archives=( "${LLVM_BUILD}"/lib/LLVM*.lib "${LLVM_BUILD}"/lib/libLLVM*.a )
    echo "  archive count: ${#_archives[@]}"
    ls -la "${_archives[@]}" 2>/dev/null | head -10 || true
    shopt -u nullglob

    echo "--- sample archive symbol probe ---"
    _sample=""
    for _cand in "${LLVM_BUILD}/lib/libLLVMAArch64Info.a" \
                 "${LLVM_BUILD}/lib/libLLVMSupport.a"; do
      if [[ -f "${_cand}" ]]; then _sample="${_cand}"; break; fi
    done

    # Resolve host llvm-nm: Windows installs under Library/bin, not bin.
    if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm" ]]; then
      _host_nm="${BUILD_PREFIX}/Library/bin/llvm-nm"
    elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-nm.exe" ]]; then
      _host_nm="${BUILD_PREFIX}/Library/bin/llvm-nm.exe"
    elif [[ -x "${BUILD_PREFIX}/bin/llvm-nm" ]]; then
      _host_nm="${BUILD_PREFIX}/bin/llvm-nm"
    else
      _host_nm=""
      echo "  WARNING: no llvm-nm found in BUILD_PREFIX"
    fi
    echo "  selected host nm: ${_host_nm}"

    # Resolve host llvm-readobj: same search order as llvm-nm above.
    if [[ -x "${BUILD_PREFIX}/Library/bin/llvm-readobj" ]]; then
      _host_readobj="${BUILD_PREFIX}/Library/bin/llvm-readobj"
    elif [[ -x "${BUILD_PREFIX}/Library/bin/llvm-readobj.exe" ]]; then
      _host_readobj="${BUILD_PREFIX}/Library/bin/llvm-readobj.exe"
    elif [[ -x "${BUILD_PREFIX}/bin/llvm-readobj" ]]; then
      _host_readobj="${BUILD_PREFIX}/bin/llvm-readobj"
    else
      _host_readobj=""
      echo "  WARNING: no llvm-readobj found in BUILD_PREFIX"
    fi
    echo "  selected host readobj: ${_host_readobj}"

    if [[ -n "${_sample}" ]]; then
      echo "  sample: ${_sample}"
      echo "  size: $(stat -c %s "${_sample}" 2>/dev/null || stat -f %z "${_sample}")"
      if [[ -n "${_host_nm}" ]]; then
        echo "  host llvm-nm output (first 10 lines):"
        "${_host_nm}" "${_sample}" 2>&1 | head -10 | sed 's/^/    /' || true
      fi
      echo "  zig nm output (first 10 lines):"
      "${_zig_bin}" nm "${_sample}" 2>&1 | head -10 | sed 's/^/    /' || true
    else
      echo "  no sample archive found"
    fi

    # Windows-invocable wrapper for `zig nm`. extract_symbols.py calls subprocess
    # with the path directly; on Windows it must be a .bat or .exe.
    _nm_wrapper="${LLVM_BUILD}/zig-nm-wrapper.bat"
    cat > "${_nm_wrapper}" <<EOF
@echo off
"${_zig_bin}" nm %*
EOF

    # Try multiple --nm x --mangling combinations. zig MinGW uses Itanium mangling
    # (not Microsoft); Linux ELF also uses Itanium mangling.
    declare -a _attempts=()
    if [[ -n "${_host_nm}" ]]; then
      _attempts+=( "host-itanium|${_host_nm}|itanium" )
    fi
    if [[ -f "${_nm_wrapper}" ]]; then
      _attempts+=( "zignm-itanium|${_nm_wrapper}|itanium" )
    fi

    shopt -s nullglob
    _real_archives=( "${LLVM_BUILD}"/lib/LLVM*.lib "${LLVM_BUILD}"/lib/libLLVM*.a )
    shopt -u nullglob

    _winner_def=""
    _winner_lines=0
    _winner_label=""
    for _entry in "${_attempts[@]}"; do
      IFS="|" read -r _label _nm _os <<< "${_entry}"
      _cand="${LLVM_BUILD}/libLLVM.def.${_label}"
      _errf="${LLVM_BUILD}/libLLVM.def.${_label}.err"
      echo "--- attempt: ${_label} (--nm=${_nm##*/} --mangling=${_os}) ---"
      _extra_args=()
      if [[ -n "${_host_readobj}" ]]; then
        _extra_args+=(--readobj "${_host_readobj}")
      fi
      python3 "${LLVM_SRC}/utils/extract_symbols.py" \
        --nm "${_nm}" --mangling "${_os}" \
        "${_extra_args[@]}" \
        "${_real_archives[@]}" \
        > "${_cand}" 2> "${_errf}" && _rc=0 || _rc=$?
      _lines=$(wc -l < "${_cand}" 2>/dev/null || echo 0)
      echo "  exit: ${_rc}, def lines: ${_lines}"
      if [[ -s "${_errf}" ]]; then
        echo "  stderr (first 200 lines):"
        head -200 "${_errf}" | sed 's/^/    /'
      fi
      if (( _lines > _winner_lines )); then
        _winner_def="${_cand}"
        _winner_lines=${_lines}
        _winner_label="${_label}"
      fi
    done

    if [[ -n "${_winner_def}" ]]; then
      echo "=== WINNER: ${_winner_label} with ${_winner_lines} lines ==="
      cp "${_winner_def}" "${_def_out}"
    else
      echo "=== ALL ATTEMPTS PRODUCED EMPTY .def ==="
    fi

    if [[ ! -s "${_def_out}" ]]; then
      echo "  ERROR: win-arm64: libLLVM.def generation failed across all attempts" >&2
      ls -la "${LLVM_BUILD}/lib/" 2>/dev/null | head -20 >&2
      exit 1
    fi
    dbg "win-arm64: libLLVM.def has $(wc -l < "${_def_out}") lines"

    # Stage 3: build the libLLVM dll (patch 0004 uses --def libLLVM.def via the
    # patched cmake conditional; the .def file now exists so the link succeeds).
    cmake --build "${LLVM_BUILD}" --config Release --target LLVM
  else
    cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
  fi

  # Phase 1.5: Remove atexit from import lib via strip_atexit_from_implib().
  # atexit from dllcrt2.obj leaks into import libs via --export-all-symbols.
  # Zig's driver rejects --exclude-symbols, so we surgically remove it here.
  _implib=$(find "${LLVM_BUILD}" \( -name 'libLLVM*.dll.a' -o -name 'LLVM*.dll.a' \) 2>/dev/null | awk 'NR==1')
  _zig_bin="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"

  # Determine dlltool machine type for cross-compilation (x64 host → arm64 target)
  _dlltool_machine=""
  if [[ "${ZIG_TRIPLET}" == aarch64-* ]]; then
    _dlltool_machine="arm64"
  elif [[ "${ZIG_TRIPLET}" == x86_64-* ]]; then
    _dlltool_machine="i386:x86-64"
  fi

  if [[ -n "${_implib}" ]]; then
    echo "  Phase 1.5: Stripping atexit from import lib: ${_implib}"
    if ! strip_atexit_from_implib "${_implib}" "${_zig_bin}" "libLLVM-20" "${_dlltool_machine}"; then
      echo "  ERROR: strip_atexit_from_implib failed — aborting build."
      exit 1
    fi
    # Quick-fail: verify libLLVM.dll.a has critical symbols after strip_atexit.
    # Without this, a broken import lib wastes the entire Phase 2 build.
    # Use direct pipe (strings | grep -q) to avoid storing ~8 MB of symbols in a
    # bash variable — MSYS2 echo truncates large variables, causing false failures.
    echo "  Phase 1.5b: Quick-fail verification of libLLVM.dll.a exports..."
    { set +x; } 2>/dev/null
    _llvm_fail=0
    for _check_sym in ErrorInfoBase LLVMInitialize; do
      if strings -a "${_implib}" 2>/dev/null | grep -q "${_check_sym}"; then
        echo "    OK: ${_check_sym} found"
      else
        echo "    FAIL: ${_check_sym} NOT found in libLLVM.dll.a"
        _llvm_fail=1
      fi
    done

    # Count total symbol-like strings (approximate, for logging)
    _llvm_nsyms=$(strings -a "${_implib}" 2>/dev/null \
      | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || echo 0)
    echo "    Total symbols in libLLVM.dll.a: ${_llvm_nsyms}"
    if [[ "${_llvm_nsyms}" -lt 5000 ]]; then
      echo "    FAIL: expected 5000+ symbols, got ${_llvm_nsyms}"
      _llvm_fail=1
    fi
    set -x

    if [[ "${_llvm_fail}" -ne 0 ]]; then
      echo "  ERROR: libLLVM.dll.a is missing critical symbols!"
      echo "  strip_atexit_from_implib may have discarded members, or --export-all-symbols is missing."
      exit 1
    fi
    echo "  OK: libLLVM.dll.a verified (${_llvm_nsyms} symbols, all critical present)"
  else
    echo "  WARNING: import lib not found — skipping Phase 1.5"
  fi

  # Phase 2: Build all remaining targets.
  # --export-all-symbols is in the CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # so all DLLs (libclang-cpp etc.) export their symbols.
  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"


  # Phase 2.5: Strip atexit from libclang-cpp import lib + verify exports.
  # --export-all-symbols is baked into CMAKE_CXX_CREATE_SHARED_LIBRARY template,
  # which also leaks atexit from dllcrt2.obj — same issue as libLLVM.
  _clang_implib=$(find "${LLVM_BUILD}" \( -name 'libclang-cpp*.dll.a' -o -name 'clang-cpp*.dll.a' \) 2>/dev/null | awk 'NR==1')
  if [[ -n "${_clang_implib}" ]]; then
    echo "  Phase 2.5: Stripping atexit from clang-cpp import lib: ${_clang_implib}"
    if ! strip_atexit_from_implib "${_clang_implib}" "${_zig_bin}" "libclang-cpp" "${_dlltool_machine}"; then
      echo "  ERROR: strip_atexit_from_implib failed for clang-cpp — aborting build."
      exit 1
    fi
    # Quick-fail: verify libclang-cpp.dll.a actually exports the symbols zig needs.
    # Without this, a broken import lib wastes 25+ min on zig-zig_impl before failing
    # with "104 undefined symbol" errors (clang::SourceManager::*, etc.).
    #
    # Critical symbols that zig's zig_clang.cpp references directly:
    #   SourceManager  — getSpellingLocSlowCase, getFilename, getSpellingLineNumber
    #   CompilerInstance — zig uses clang as a library
    #   ASTContext       — AST manipulation
    echo "  Phase 2.5b: Quick-fail verification of libclang-cpp.dll.a exports..."
    # Instant size check: a proper import lib is 100s of KiB to MiB.
    # 7.9 KiB means --export-all-symbols didn't work (only a handful of symbols).
    _clang_implib_size=$(stat -c%s "${_clang_implib}" 2>/dev/null || stat -f%z "${_clang_implib}" 2>/dev/null || echo 0)
    echo "    Import lib size: ${_clang_implib_size} bytes ($(( _clang_implib_size / 1024 )) KiB)"
    if [[ "${_clang_implib_size}" -lt 100000 ]]; then
      echo "    FAIL: libclang-cpp.dll.a is only ${_clang_implib_size} bytes!"
      echo "    Expected 100+ KiB — --export-all-symbols not effective for libclang-cpp."
      # Print DLL size for quick diagnosis (large DLL + tiny implib = --out-implib problem)
      _clang_dll_fail=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_fail}" ]]; then
        _clang_dll_fail_sz=$(stat -c%s "${_clang_dll_fail}" 2>/dev/null || stat -f%z "${_clang_dll_fail}" 2>/dev/null || echo 0)
        echo "    libclang-cpp.dll size: ${_clang_dll_fail_sz} bytes ($(( _clang_dll_fail_sz / 1048576 )) MiB)"
      else
        echo "    libclang-cpp.dll: NOT FOUND"
      fi
      exit 1
    fi
    # Use direct pipe (strings | grep -q) to avoid storing large symbol sets in bash
    # variables — MSYS2 echo truncates large variables, causing false failures.
    { set +x; } 2>/dev/null
    _clang_fail=0
    # Check critical zig-required symbols
    for _check_sym in SourceManager CompilerInstance ASTContext; do
      if strings -a "${_clang_implib}" 2>/dev/null | grep -q "${_check_sym}"; then
        echo "    OK: ${_check_sym} found"
      else
        echo "    FAIL: ${_check_sym} NOT found in libclang-cpp.dll.a"
        _clang_fail=1
      fi
    done

    # Minimum symbol count — libclang-cpp exports thousands of C++ symbols.
    # If we have < 1000, something went very wrong (visibility, ar d, etc.)
    _clang_nsyms=$(strings -a "${_clang_implib}" 2>/dev/null \
      | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || echo 0)
    echo "    Total symbols in libclang-cpp.dll.a: ${_clang_nsyms}"
    if [[ "${_clang_nsyms}" -lt 1000 ]]; then
      echo "    FAIL: expected 1000+ symbols, got ${_clang_nsyms}"
      _clang_fail=1
    fi
    set -x

    if [[ "${_clang_fail}" -ne 0 ]]; then
      echo "  ERROR: libclang-cpp.dll.a is missing critical symbols!"
      echo "  This would cause 104+ undefined symbol errors in zig-zig_impl build."
      # Show DLL size for diagnosis
      _clang_dll_sym=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      if [[ -n "${_clang_dll_sym}" ]]; then
        _clang_dll_sym_sz=$(stat -c%s "${_clang_dll_sym}" 2>/dev/null || stat -f%z "${_clang_dll_sym}" 2>/dev/null || echo 0)
        echo "  libclang-cpp.dll size: ${_clang_dll_sym_sz} bytes ($(( _clang_dll_sym_sz / 1048576 )) MiB)"
        _clang_dll_sym_nsyms=$( ("${_zig_bin}" nm "${_clang_dll_sym}" 2>/dev/null || nm "${_clang_dll_sym}" 2>/dev/null) \
          | grep -c ' [TDBCV] ' || echo 0)
        echo "  libclang-cpp.dll exported symbols (nm): ${_clang_dll_sym_nsyms}"
      fi
      echo "  libclang-cpp.dll.a size: ${_clang_implib_size} bytes, symbols: ${_clang_nsyms}"
      echo "  Likely causes:"
      echo "    - -fvisibility=default not reaching clang compilation"
      echo "    - --export-all-symbols not in libclang-cpp link command"
      echo "    - strip_atexit_from_implib discarded members (ar d removed too much)"
      exit 1
    fi
    echo "  OK: libclang-cpp.dll.a verified (${_clang_nsyms} symbols, all critical present)"
  fi
elif is_osx; then
  # Two-phase build on macOS: build libLLVM.dylib first, check symbol exports,
  # then build the rest. Without this, a visibility bug wastes the full 2-hour build
  # only to fail at the very end when libclang-cpp.dylib links against libLLVM.dylib.
  # Same rpath issue as Linux: llvm-min-tblgen needs to find libunwind from LLVM_INSTALL.
  export DYLD_LIBRARY_PATH="${LLVM_INSTALL}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  echo "  Phase 1: Building LLVM shared library..."
  set +e
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
  _phase1_rc=$?
  set -e

  if [[ ${_phase1_rc} -ne 0 ]]; then
    echo "=================================================================="
    echo "  Phase 1 FAILED (rc=${_phase1_rc}). Entering hypothesis test mode."
    echo "=================================================================="

    # Extract the failing libLLVM.dylib link command from ninja
    _link_cmd=$(ninja -C "${LLVM_BUILD}" -t commands lib/libLLVM.dylib 2>/dev/null | tail -1)
    if [[ -z "${_link_cmd}" ]]; then
      echo "  ERROR: could not extract link command via ninja -t commands"
      exit ${_phase1_rc}
    fi
    echo "  Original link command captured (length=${#_link_cmd} chars)"

    # Strip ninja's `: && ... && :` wrapper to get the bare command.
    # Pattern: leading `: && ` and trailing ` && :` with optional whitespace.
    _bare_link_cmd="${_link_cmd}"
    _bare_link_cmd="${_bare_link_cmd#: && }"
    _bare_link_cmd="${_bare_link_cmd% && :}"

    # Normalize zig -target in _bare_link_cmd: CMake emits GCC-style triplets like
    # x86_64-apple-darwin or aarch64-apple-darwin (no version) that zig rejects with
    # "UnknownOperatingSystem". Replace with the proper zig target from ZIG_TRIPLET
    # (e.g. aarch64-macos.11.0-none). This fixes all append-mode hypotheses (H1-H4,
    # H7-H10) which inherit _bare_link_cmd unmodified.
    # ZIG_TRIPLET is set by recipe.yaml and holds the canonical zig target for this build.
    # If ZIG_TRIPLET is unset at runtime, derive from HOST and MACOSX_DEPLOYMENT_TARGET.
    if [[ -n "${ZIG_TRIPLET:-}" ]]; then
      _zig_target_norm="${ZIG_TRIPLET}"
    else
      # Fallback: derive from host arch + macOS deployment target
      _zig_target_arch="${HOST%%-*}"  # x86_64 or arm64
      [[ "${_zig_target_arch}" == "arm64" ]] && _zig_target_arch="aarch64"
      _zig_target_norm="${_zig_target_arch}-macos.${MACOSX_DEPLOYMENT_TARGET:-11.0}-none"
    fi
    _bare_link_cmd=$(echo "${_bare_link_cmd}" | sed -E "s/-target (aarch64|x86_64)-apple-darwin[^ ]*/-target ${_zig_target_norm}/g")
    unset _zig_target_norm _zig_target_arch

    # SDKROOT detection
    _sdkroot="${CONDA_BUILD_SYSROOT:-${SDKROOT:-}}"
    if [[ -z "${_sdkroot}" ]]; then
      _sdkroot=$(echo "${_link_cmd}" | grep -oE -- '-isysroot [^ ]+' | head -1 | awk '{print $2}')
    fi
    echo "  SDKROOT for hypothesis tests: ${_sdkroot}"

    # Debug: capture and report empty `-l` flags to localize the cmake/ninja source
    echo "  Empty -l flag debug:"
    printf '%s\n' "${_orig_cmd:-${_bare_link_cmd}}" | tr ' ' '\n' | grep -nE '^-l$|^-l[[:space:]]' | head -20 || echo "    (none found in original cmd)"
    # Also check for empty linker args
    printf '%s\n' "${_orig_cmd:-${_bare_link_cmd}}" | tr ' ' '\n' | grep -cE '^-l$' || true
    # If build.ninja exists, search it for empty `-l` patterns to find cmake source
    if [[ -f "${LLVM_BUILD}/build.ninja" ]]; then
      echo "  build.ninja empty -l matches (first 20):"
      grep -nE '\b-l ' "${LLVM_BUILD}/build.ninja" 2>/dev/null | head -20 || echo "    (none)"
    fi

    _hypotheses=(
      "H1|append|-Wl,-syslibroot,${_sdkroot}"
      "H2|env-prefix|SDKROOT=${_sdkroot}|append|-Wl,-syslibroot,${_sdkroot}"
      "H3|append|-L${_sdkroot}/usr/lib"
      "H4|append|-Wl,-syslibroot,${_sdkroot} -L${_sdkroot}/usr/lib -Wl,-lSystem"
      "H5|target-version|append|-Wl,-syslibroot,${_sdkroot}"
      # H6 (direct-zig) bypasses the zig wrapper entirely; our wrapper-side fixes
      # (-Wl,-lSystem → -lSystem, -Wl,-syslibroot filtering) do not apply, so H6
      # never represents the real build path and produces misleading failures.
      # Disabled to reduce CI noise.
      # "H6|direct-zig|append|-Wl,-syslibroot,${_sdkroot}"
      # H7: set SDKROOT + MACOSX_DEPLOYMENT_TARGET in env so zig auto-detects SDK; no extra flags.
      # env-prefix captures one token (space-sep vars OK); trailing |append| makes _append empty.
      "H7|env-prefix|SDKROOT=${_sdkroot} MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.3}|append|"
      # H8: zig-native --sysroot flag (distinct from -isysroot and -Wl,-syslibroot).
      "H8|append|--sysroot=${_sdkroot}"
      # H9: re-inject -isysroot after the wrapper strips the first occurrence.
      # The wrapper strips the first -isysroot it sees; appending a second -isysroot ${_sdkroot}
      # means one copy survives into zig's translated args. eval splits the space into two words.
      "H9|append|-isysroot ${_sdkroot}"
      # H10: bisect test — append -nostdlib++ to see if zig's libc++ driver
      # injection produces the 3 blank -l entries. Combined with H3's working
      # baseline (-L SDK/usr/lib resolves -lSystem). If blank -l count drops
      # to 0 in this hypothesis, confirms zig's AddCXXStdlibLibArgs path is
      # the source. New "undefined libc++ symbols" errors are EXPECTED and OK
      # — success criterion is BLANK -l count, not link success.
      "H10|append|-L${_sdkroot}/usr/lib -nostdlib++"
    )

    _winner=""
    for _h in "${_hypotheses[@]}"; do
      _hid="${_h%%|*}"
      _rest="${_h#*|}"
      _modified_cmd="${_link_cmd}"
      _env_prefix=""

      case "${_rest}" in
        env-prefix\|*)
          _env_prefix="${_rest#env-prefix|}"
          _env_prefix="${_env_prefix%%|*}"
          _append="${_rest##*append|}"
          _modified_cmd="${_env_prefix} ${_bare_link_cmd} ${_append}"
          ;;
        target-version\|*)
          _ver="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
          _modified_cmd=$(echo "${_bare_link_cmd}" | sed -E "s/(aarch64|x86_64)-macos[^ ]*/\\1-macos.${_ver}-none/g")
          _append="${_rest##*append|}"
          _modified_cmd="${_modified_cmd} ${_append}"
          ;;
        direct-zig\|*)
          # Replace zig-force-load-cxx with direct zig c++ call (skip wrapper filtering).
          # Direct zig c++ does NOT accept -all_load / -Wl,-all_load (unsupported linker arg),
          # so strip those flags. The .a archives are already on the link line directly;
          # without -all_load zig links only referenced symbols (standard behaviour).
          _zig_bin="${BUILD_PREFIX}/bin/${_conda_triplet:-${HOST_PLATFORM:-arm64-apple-darwin}}-zig"
          [[ ! -x "${_zig_bin}" ]] && _zig_bin=$(ls "${BUILD_PREFIX}/bin/"*-zig 2>/dev/null | head -1)
          echo "DBG _llvm_build diag: _zig_bin=${_zig_bin} _conda_triplet=${_conda_triplet:-unset} HOST_PLATFORM=${HOST_PLATFORM:-unset}"
          _modified_cmd=$(echo "${_bare_link_cmd}" | sed -E "s|[^ ]*zig-force-load-cxx|${_zig_bin} c++ -target aarch64-macos.${MACOSX_DEPLOYMENT_TARGET:-11.0}-none -mcpu=baseline|")
          # Strip -all_load / -Wl,-all_load — not accepted by zig's Mach-O linker directly
          _modified_cmd=$(echo "${_modified_cmd}" | sed -E 's/ -Wl,-all_load\b//g; s/ -all_load\b//g')
          _append="${_rest##*append|}"
          _modified_cmd="${_modified_cmd} ${_append}"
          ;;
        append\|*)
          _append="${_rest#append|}"
          _modified_cmd="${_bare_link_cmd} ${_append}"
          ;;
      esac

      echo ""
      echo "  ----- ${_hid}: trying -----"
      echo "  Append/modify: ${_rest}"
      _hyp_log="${LLVM_BUILD}/hypothesis_${_hid}.log"
      set +e
      ( cd "${LLVM_BUILD}" && eval "${_modified_cmd}" ) >"${_hyp_log}" 2>&1
      _hyp_rc=$?
      set -e
      if [[ ${_hyp_rc} -eq 0 ]] && [[ -f "${LLVM_BUILD}/lib/libLLVM.dylib" ]]; then
        echo "  [${_hid}] PASS (rc=0, libLLVM.dylib produced)"
        _winner="${_hid}"
        # Clean up temp extractions before breaking so disk is free for Phase 2
        if [[ -n "${TMPDIR:-}" ]] && [[ -d "${TMPDIR}" ]]; then
          find "${TMPDIR}" -maxdepth 1 -type d -name 'tmp.*' -mmin -60 -exec rm -rf {} + 2>/dev/null || true
        fi
        break
      else
        # Capture meaningful linker errors (library/symbol failures) instead of aggregate summaries
        # Full stderr is preserved in ${_hyp_log}; we show up to 8000 chars inline.
        _err_tail=$(grep -E 'library not found|undefined symbol|error:' "${_hyp_log}" 2>/dev/null | head -10 | tr '\n' '|' | head -c 8000)
        if [[ -z "${_err_tail}" ]]; then
          # Fallback to original tail if no errors matched
          _err_tail=$(tail -5 "${_hyp_log}" 2>/dev/null | head -c 8000 | tr '\n' ' ')
        fi
        echo "  [${_hid}] FAIL (rc=${_hyp_rc}): ${_err_tail}"
        # Diagnostic: surface the last 200 lines of full hypothesis log so we can see
        # what each H actually emitted (Azure DevOps collapses long lines, so prefix each line).
        echo "  [${_hid}] --- last 200 lines of ${_hyp_log} ---"
        tail -200 "${_hyp_log}" 2>/dev/null | awk -v hid="${_hid}" '{print "    [" hid "] " NR ": " $0}'
        echo "  [${_hid}] --- end log ---"
        # Clean up _zig-force-load-common.sh temp extractions to prevent disk exhaustion
        # Each re-link extracts thousands of .a archives to ${TMPDIR}/tmp.XXX/ar_N/
        if [[ -n "${TMPDIR:-}" ]] && [[ -d "${TMPDIR}" ]]; then
          find "${TMPDIR}" -maxdepth 1 -type d -name 'tmp.*' -mmin -60 -exec rm -rf {} + 2>/dev/null || true
        fi
      fi
    done

    if [[ -z "${_winner}" ]]; then
      echo ""
      echo "=================================================================="
      echo "  ALL HYPOTHESES FAILED. Logs in ${LLVM_BUILD}/hypothesis_H*.log"
      echo "=================================================================="

      # === DIAGNOSTIC: capture zig+ld64.lld verbose link output ===
      # All H1-H9 failed identically with 3 blank -l flags. The blanks are NOT in
      # the original cmake/ninja command, so they originate inside zig's ld64.lld
      # argument translation. Use --verbose-link (zig compiler flag, not a linker
      # flag) via a direct zig c++ invocation (same bypass pattern as H6) to see
      # the full parsed argument list and localize where blank entries enter.
      echo ""
      echo "=== DIAGNOSTIC: verbose zig+ld64.lld link output ==="
      echo "  All H1-H9 failed; capturing --verbose-link to localize blank -l source"
      _diag_log="${LLVM_BUILD}/diagnostic_verbose_link.log"
      _zig_bin="${BUILD_PREFIX}/bin/${_conda_triplet:-${HOST_PLATFORM:-arm64-apple-darwin}}-zig"
      [[ ! -x "${_zig_bin}" ]] && _zig_bin=$(ls "${BUILD_PREFIX}/bin/"*-zig 2>/dev/null | head -1)
      echo "DBG _llvm_build diag: _zig_bin=${_zig_bin} _conda_triplet=${_conda_triplet:-unset} HOST_PLATFORM=${HOST_PLATFORM:-unset}"
      # Build the diagnostic command: replace wrapper with direct zig c++ -v,
      # strip -all_load variants (unsupported by direct zig), add SDK flags to reduce noise.
      _diag_cmd=$(echo "${_bare_link_cmd}" | sed -E "s|[^ ]*zig-force-load-cxx|${_zig_bin} c++ -v -target aarch64-macos.${MACOSX_DEPLOYMENT_TARGET:-11.0}-none -mcpu=baseline|")
      _diag_cmd=$(echo "${_diag_cmd}" | sed -E 's/ -Wl,-all_load\b//g; s/ -all_load\b//g')
      _diag_cmd="${_diag_cmd} -Wl,-syslibroot,${_sdkroot} -L${_sdkroot}/usr/lib"
      _diag_cmd="${_diag_cmd} -Wl,-t"
      echo "  --- diagnostic command (length=${#_diag_cmd} chars) ---"
      printf '%s\n' "${_diag_cmd}"
      echo "  --- end diagnostic command ---"
      set +e
      ( cd "${LLVM_BUILD}" && eval "${_diag_cmd}" ) >"${_diag_log}" 2>&1
      _diag_rc=$?
      set -e
      echo "  Verbose link output saved to: ${_diag_log} (rc=${_diag_rc}, size=$(wc -c <"${_diag_log}" 2>/dev/null || echo 0) bytes, lines=$(wc -l <"${_diag_log}" 2>/dev/null || echo 0))"
      if [[ ! -s "${_diag_log}" ]]; then
        echo "  WARNING: diagnostic log is empty — eval likely failed before producing output"
        echo "  Trying again WITHOUT redirection so output reaches CI log directly:"
        set +e
        ( cd "${LLVM_BUILD}" && eval "${_diag_cmd}" ) 2>&1 | sed 's/^/    [DIAG] /'
        set -e
      else
        echo "  --- FULL verbose output ---"
        awk '{print NR": "$0}' "${_diag_log}" 2>/dev/null | fold -s -w 240
        echo "  --- end verbose output ---"
        echo "  --- grep -n 'library not found|^-l|^ -l' ---"
        grep -nE 'library not found| -l |^-l$' "${_diag_log}" 2>/dev/null | head -30 || true
      fi
      echo "=== END DIAGNOSTIC ==="

      exit ${_phase1_rc}
    fi

    echo ""
    echo "=================================================================="
    echo "  WINNER: ${_winner} — proceeding to Phase 2"
    echo "=================================================================="
  fi

  # Quick-fail: verify key symbols are exported from libLLVM.dylib.
  # If zig cc's visibility handling is broken, we find out here (~50% through build)
  # instead of at the end when libclang-cpp.dylib tries to link.
  _llvm_dylib=$(find "${LLVM_BUILD}" -name 'libLLVM*.dylib' -not -name '*.dSYM' 2>/dev/null | awk 'NR==1')
  if [[ -n "${_llvm_dylib}" ]]; then
    # Check for a known externally-consumed symbol (LLVMInitialize* functions).
    # IMPORTANT: use "grep ... >/dev/null" NOT "grep -q" here.
    # grep -q exits on first match, closing the pipe while nm is still writing
    # 55K+ symbols. Under set -o pipefail, nm's SIGPIPE (exit 141) makes the
    # pipeline fail even though the symbol was found.
    _test_sym="LLVMInitializeAArch64AsmParser"
    if nm -g "${_llvm_dylib}" 2>/dev/null | grep "${_test_sym}" >/dev/null 2>&1; then
      echo "  OK: ${_test_sym} exported from libLLVM.dylib"
    else
      echo "  FAIL: ${_test_sym} NOT exported from libLLVM.dylib"
      if _debug && [[ -f "${RECIPE_DIR}/building/debug-macos-dylib.sh" ]]; then
        source "${RECIPE_DIR}/building/debug-macos-dylib.sh"
        debug_macos_dylib "${_llvm_dylib}" "${_test_sym}" "${LLVM_BUILD}"
      fi
      echo "  EARLY ABORT: libLLVM.dylib is missing key symbols."
      exit 1
    fi
  else
    echo "  WARNING: libLLVM.dylib not found after Phase 1 — proceeding anyway"
  fi

  echo "  Phase 2: Building remaining targets..."
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
else
  # Linux: single-phase build (no known symbol visibility issues with ELF)
  # llvm-min-tblgen links against libunwind.so.1 (from zig-llvm's shared runtimes).
  # LLVM's llvm_setup_rpath() sets BUILD_WITH_INSTALL_RPATH=ON which bypasses
  # CMAKE_BUILD_RPATH. The binary's $ORIGIN/../lib resolves to LLVM_BUILD/lib/
  # but libunwind.so.1 is in LLVM_INSTALL/lib/. LD_LIBRARY_PATH bridges the gap.
  # Cross-compile: build_env's zig-libcxx installs libc++.so.1 at
  # ${BUILD_PREFIX}/lib/zig-llvm/lib/ — needed by host llvm-tblgen.
  # Native build: same path resolves harmlessly to the build_env copy too.
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib:${LLVM_INSTALL}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  set +e
  cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"
  _linux_build_rc=$?
  set -e

  # === ppc64le ld.real invocation report ===
  if [[ "${target_platform}" == "linux-ppc64le" ]] && [[ -f "${_ld_log:-}" ]]; then
    echo "=== ld.real invocations (last 500 lines of ${_ld_log}) ==="
    tail -500 "${_ld_log}" || true
    echo "=== END ld.real invocations ==="
  fi

  if [[ ${_linux_build_rc} -ne 0 ]]; then
    exit ${_linux_build_rc}
  fi
fi

