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
  -DCLANG_TOOL_CLANG_FUZZER_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

# LLVM_TARGETS_TO_BUILD: 10-target curated list. On aarch64-windows-gnu the
# resulting libLLVM-20.dll exceeds the PE/COFF 65535 export-ordinal limit
# because GPU backends (AMDGPU + NVPTX) have very large TableGen-generated
# instruction-selection tables. Drop them on aarch64-windows-gnu only —
# zig doesn't target GPU code generation on win-arm64.
_llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX"
if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    # zig requires AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly;X86 to be built
    # (see recipes/zig-zig/patches/relax-llvm-required-targets.patch's
    # ZIG_LLVM_REQUIRED_TARGETS). Only the GPU backends (AMDGPU, NVPTX) and AVR
    # are dropped -- their huge TableGen instruction-selection tables were the
    # actual cause of exceeding the PE/COFF 65535 export-ordinal limit, not
    # ARM/PowerPC/RISCV/SystemZ.
    _llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly"
    echo "  win-arm64: pruned LLVM_TARGETS_TO_BUILD (dropped AVR, AMDGPU, NVPTX) to fit PE/COFF 65535 export limit"
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


echo "=== Configuring LLVM ==="
echo "  Install prefix: ${LLVM_INSTALL} (separate from conda-forge llvmdev)"
_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  -DCMAKE_PREFIX_PATH="${LLVM_INSTALL};${PREFIX};${BUILD_PREFIX}"
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
  -DCMAKE_CXX_FLAGS="-fvisibility=default"
)

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
# Fix: use BUILD_PREFIX (forward-slash unix path) in the -C initial-cache
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
  # BUILD_PREFIX can arrive either as a forward-slash unix path (package-incubator
  # build.bat, e.g. /d/a/package-incubator/.../build_env) OR as a native Windows
  # path with backslashes (conda-forge / rattler-build CI, e.g. D:\bld\...\build_env).
  # In the backslash case the raw path interpolated into the set() below trips
  # CMake's "Invalid character escape '\b'" (from \bin / \bld / \build_env) and
  # aborts the initial-cache parse before project() (confirmed: build 1551110
  # log 55, win-64 zig_impl). Normalize backslashes -> forward slashes so the
  # written CMAKE_RC_COMPILER path is escape-safe regardless of how BUILD_PREFIX
  # arrives (forward slashes are valid path separators for CMake on Windows).
  _rc_path="${BUILD_PREFIX}/Library/bin/${CONDA_ZIG_BUILD%.exe}-rc.exe"
  _rc_path="${_rc_path//\\//}"
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

# CMake's compiler check runs the zig wrapper -> build-arch host zig, which is
# dynamically linked to libc++.so.1 from the zig-libcxx build dep. Put that dir
# on the loader path BEFORE configure (the existing export later only covers build).
if is_linux; then
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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

  # TEMP DIAG (win-64 --export-all-symbols investigation)
  # Capture CMAKE_SHARED_LINKER_FLAGS and generated Ninja linker rules immediately
  # after cmake configure, before the quick-fail guard. This helps determine whether
  # --export-all-symbols is lost at configure time or at Ninja-generation time.
  if is_not_unix; then
    echo "=== DIAG: live shared-linker flags after configure ==="
    grep -E "CMAKE_SHARED_LINKER_FLAGS" "${LLVM_BUILD}/CMakeCache.txt" || true
    echo "--- Ninja rules for CXX_SHARED_LIBRARY_LINKER ---"
    grep -nE "rule CXX_SHARED_LIBRARY_LINKER__(LLVM|clang-cpp)_Release" -A2 "${LLVM_BUILD}/CMakeFiles/rules.ninja" 2>/dev/null || \
      find "${LLVM_BUILD}" -maxdepth 3 -name 'rules.ninja' -exec grep -nE "rule CXX_SHARED_LIBRARY_LINKER__(LLVM|clang-cpp)_Release" -A2 {} \; 2>/dev/null || true
    echo "=== END DIAG ==="
  fi

  # TEMP DIAG (win-64 build.ninja LINK_FLAGS)
  # rules.ninja only holds the unexpanded `$LINK_FLAGS` template; the actual
  # per-target flags (from CMAKE_SHARED_LINKER_FLAGS/_INIT) are written by CMake's
  # Ninja generator into the per-target BUILD EDGE in build.ninja as a
  # `LINK_FLAGS = ...` variable. Dump those edges here so the next CI run proves
  # whether --export-all-symbols actually reaches the expanded link command.
  if is_not_unix; then
    echo "=== DIAG: build.ninja LINK_FLAGS for LLVM/clang-cpp build edges ==="
    _build_ninja_diag="${LLVM_BUILD}/build.ninja"
    [[ -f "${_build_ninja_diag}" ]] || _build_ninja_diag=$(find "${LLVM_BUILD}" -maxdepth 3 -name 'build.ninja' 2>/dev/null | head -1)
    if [[ -n "${_build_ninja_diag}" && -f "${_build_ninja_diag}" ]]; then
      for _diag_rule in "CXX_SHARED_LIBRARY_LINKER__LLVM_Release" "CXX_SHARED_LIBRARY_LINKER__clang-cpp_Release"; do
        echo "--- build edge for rule: ${_diag_rule} ---"
        awk -v rule=": ${_diag_rule}" '
          /^build / { in_edge = index($0, rule) > 0; if (in_edge) print; next }
          in_edge && NF == 0 { in_edge = 0 }
          in_edge { print }
        ' "${_build_ninja_diag}" | grep -E '^build |LINK_FLAGS' || echo "  (no matching build edge found)"
      done
    else
      echo "  (build.ninja not found under ${LLVM_BUILD})"
    fi
    echo "=== END DIAG ==="
  fi

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
                "${BUILD_PREFIX}/lib"; do
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

# === Quick-fail: verify --export-all-symbols in ALL shared library link edges ===
# libLLVM and libclang-cpp each get their own CXX_SHARED_LIBRARY_LINKER rule, but
# the per-target linker flags (from CMAKE_SHARED_LINKER_FLAGS/_INIT) are NOT baked
# into that rule's `command =` template in rules.ninja — CMake's Ninja generator
# only ever writes the unexpanded `$LINK_FLAGS` placeholder there. The expanded
# flags live per-target in build.ninja, as a `LINK_FLAGS = ...` variable inside
# each target's BUILD EDGE. If --export-all-symbols is missing from either
# target's LINK_FLAGS, the import lib will be 8 KiB instead of 100+ KiB — but
# we'd only discover that AFTER 2+ hours.
#
# win-arm64: skip this assertion — patch 0004 routes to --def (not --export-all-symbols)
# for aarch64 to avoid the PE/COFF 65535 export-ordinal cap. The .def file is generated
# in Phase 0 below; its presence (not --export-all-symbols) is what matters there.
if is_not_unix && ! { [[ "${ZIG_TRIPLET}" == aarch64-* ]]; }; then
  { set +x; } 2>/dev/null
  # Locate build.ninja, which holds the per-target BUILD EDGES (`build <out> :
  # CXX_SHARED_LIBRARY_LINKER__<target>_Release ...` followed by an indented
  # `LINK_FLAGS = ...` variable) with the fully expanded linker flags. Keying off
  # the rule name (rather than the output filename, e.g. libLLVM-20.dll) is
  # stable regardless of versioned .dll naming.
  _build_ninja="${LLVM_BUILD}/build.ninja"
  [[ -f "${_build_ninja}" ]] || _build_ninja=$(find "${LLVM_BUILD}" -maxdepth 3 -name 'build.ninja' 2>/dev/null | head -1)
  echo "=== Quick-fail: verifying --export-all-symbols in ALL shared library LINK_FLAGS ==="
  _export_fail=0
  for _rule_name in CXX_SHARED_LIBRARY_LINKER__LLVM_Release CXX_SHARED_LIBRARY_LINKER__clang-cpp_Release; do
    echo "  ${_rule_name}:"
    if [[ -z "${_build_ninja}" || ! -f "${_build_ninja}" ]]; then
      echo "    FAIL: build.ninja not found under ${LLVM_BUILD}"
      _export_fail=1
      continue
    fi
    # Extract this target's build edge: the `build ... : <rule> ...` line and
    # its following indented variable lines, up to the next blank line.
    _link_flags=$(awk -v rule=": ${_rule_name}" '
      /^build / { in_edge = index($0, rule) > 0; next }
      in_edge && NF == 0 { in_edge = 0 }
      in_edge { print }
    ' "${_build_ninja}" | grep 'LINK_FLAGS =' || true)
    if echo "${_link_flags}" | grep -q -- '--export-all-symbols'; then
      echo "    OK: --export-all-symbols present"
    else
      echo "    FAIL: --export-all-symbols NOT in LINK_FLAGS!"
      echo "    LINK_FLAGS = ${_link_flags}"
      _export_fail=1
    fi
  done
  if [[ ${_export_fail} -ne 0 ]]; then
    echo "  FATAL: --export-all-symbols missing from one or more shared library LINK_FLAGS."
    echo "  libclang-cpp.dll.a will be ~8 KiB instead of 100+ KiB."
    echo "  Aborting to avoid wasting 2+ hours on a build that will fail."
    set -x
    exit 1
  fi
  echo "  All shared library LINK_FLAGS have --export-all-symbols"
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
  #
  # win-arm64 cross-build: the runtimes build (Phase 0) installs an ARM64 libc++.dll
  # to ${LLVM_INSTALL}/bin/ = ${PREFIX}/Library/lib/zig-llvm/bin/. Adding that path
  # first causes NATIVE x86_64 tools (llvm-min-tblgen.exe, llvm-config.exe) to find
  # the ARM64 DLL and fail with STATUS_INVALID_IMAGE_FORMAT (0xc000007b) at launch.
  # Fix: for cross-builds, prepend the BUILD-arch (x86_64) libc++ path first so
  # NATIVE tools load the correct x86_64 libc++.dll from the zig-libcxx build dep.
  if is_cross; then
    _build_libcxx_dir="${BUILD_PREFIX}/Library/lib/zig-llvm"
    export PATH="${_build_libcxx_dir}/lib:${_build_libcxx_dir}/bin:${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
    echo "  Cross: build-arch libc++ (${_build_libcxx_dir}/lib) prepended before target-arch libc++ (${LLVM_INSTALL}/bin)"
    unset _build_libcxx_dir
  else
    export PATH="${LLVM_INSTALL}/bin:${LLVM_INSTALL}/lib:${PATH}"
    echo "  Added ${LLVM_INSTALL}/bin and lib to PATH for runtime DLL discovery"
  fi

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
    # Backends are included because our pruned target list is exactly
    # X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly for win-arm64 (see
    # _llvm_targets above). Only each backend's top-level CodeGen target is
    # listed explicitly -- ninja transitively builds its AsmParser/Desc/Info/
    # Disassembler/Utils dependencies as real .a files regardless of whether
    # they're separately named here.
    cmake --build "${LLVM_BUILD}" --config Release -- \
      LLVMSupport LLVMCore LLVMMC LLVMAnalysis LLVMTransformUtils LLVMCodeGen \
      LLVMTarget LLVMMCParser LLVMBinaryFormat LLVMBitWriter LLVMBitReader \
      LLVMAArch64CodeGen LLVMAArch64AsmParser LLVMAArch64Desc LLVMAArch64Info LLVMAArch64Utils \
      LLVMX86CodeGen LLVMX86AsmParser LLVMX86Desc LLVMX86Info \
      LLVMWebAssemblyCodeGen LLVMWebAssemblyAsmParser LLVMWebAssemblyDesc LLVMWebAssemblyInfo \
      LLVMARMCodeGen LLVMPowerPCCodeGen LLVMRISCVCodeGen LLVMSystemZCodeGen
    # ninja resolves transitive deps; this populates ${LLVM_BUILD}/lib/*.lib with all
    # LLVM core + 7-target backend statics.

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

    # Restrict archive set to libLLVM's actual link inputs (match win-64's
    # --export-all-symbols linker pruning behavior). Falls back to a wide glob
    # if ninja-inputs fails (e.g., target name differs across LLVM versions).
    _real_archives=()
    if command -v ninja >/dev/null 2>&1; then
      while IFS= read -r _arch; do
        [[ -n "${_arch}" && -f "${_arch}" ]] && _real_archives+=( "${_arch}" )
      done < <(ninja -C "${LLVM_BUILD}" -t inputs LLVM 2>/dev/null \
        | grep -E '/(lib)?LLVM[^/]*\.(lib|a)$' \
        | sort -u)
    fi
    if (( ${#_real_archives[@]} == 0 )); then
      echo "[Stage 2] ninja-inputs returned no LLVM archives; falling back to glob" >&2
      shopt -s nullglob
      _real_archives=( "${LLVM_BUILD}"/lib/LLVM*.lib "${LLVM_BUILD}"/lib/libLLVM*.a )
      shopt -u nullglob
    fi
    echo "[Stage 2] Archive count fed to extract_symbols.py: ${#_real_archives[@]}"

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
      echo "[Stage 2] Attempt '${_label}': .def line count = ${_lines}"
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
      echo "[Stage 2] === .def file head (first 20 lines) ==="
      head -20 "${LLVM_BUILD}/libLLVM.def" 2>/dev/null | sed 's/^/[Stage 2] DEF: /' || echo "[Stage 2] DEF: <empty or unreadable>"
      echo "[Stage 2] === .def file md5 / size ==="
      wc -l "${LLVM_BUILD}/libLLVM.def" 2>/dev/null
      md5sum "${LLVM_BUILD}/libLLVM.def" 2>/dev/null || true
    else
      echo "=== ALL ATTEMPTS PRODUCED EMPTY .def ==="
    fi

    if [[ ! -s "${_def_out}" ]]; then
      echo "  ERROR: win-arm64: libLLVM.def generation failed across all attempts" >&2
      ls -la "${LLVM_BUILD}/lib/" 2>/dev/null | head -20 >&2
      exit 1
    fi
    dbg "win-arm64: libLLVM.def has $(wc -l < "${_def_out}") lines"

    # Stage 2 post-filter: strip libc++ symbols (Itanium-mangled std::__1).
    # libc++ symbols should not be exported from libLLVM — they are an internal
    # implementation detail. Removing them reduces the export count by ~10-15k
    # symbols to fit the PE/COFF 65535-symbol limit on win-arm64.
    if [[ -s "${_def_out}" ]]; then
      _pre_count=$(wc -l < "${_def_out}")
      sed -i \
        -e '/_ZNSt3__1/d' \
        -e '/_ZNKSt3__1/d' \
        -e '/_ZTVNSt3__1/d' \
        -e '/_ZTINSt3__1/d' \
        -e '/_ZTSNSt3__1/d' \
        "${_def_out}"
      _post_count=$(wc -l < "${_def_out}")
      _delta=$(( _pre_count - _post_count ))
      echo "[Stage 2 filter] libc++ stripped: ${_pre_count} → ${_post_count} (-${_delta})"
      if [[ ${_post_count} -gt 65000 ]]; then
        echo "ERROR: .def still has ${_post_count} symbols (limit ~65535). Need more aggressive filtering." >&2
        echo "  Next options: --exclude '_ZN.*templates' or whitelist only _ZN4llvm/_ZN5clang/_ZN3lld namespaces" >&2
        exit 1
      fi
    else
      echo "WARNING: ${_def_out} empty or missing — Stage 2 extract_symbols.py may have failed" >&2
    fi

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
      | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || true)
    echo "    Total symbols in libLLVM.dll.a: ${_llvm_nsyms}"

    # Phase 1.5c: native win-64 LLD-MinGW empty-implib workaround.
    # LLD's MinGW driver can write an EMPTY import library (0 symbols) on
    # native win-64 even though the DLL itself links fine with correct
    # exports (--export-all-symbols + --out-implib). Cross win-32/win-arm64
    # implibs are already valid (nsyms >= threshold below), so this block is
    # a no-op for them -- only fires when the implib is actually broken.
    echo "WIN_IMPLIB_DIAG: primary implib symbol count = ${_llvm_nsyms} (threshold 5000) for implib ${_implib}"
    if is_not_unix && [[ "${_llvm_nsyms}" -lt 5000 ]]; then
      _llvm_dll="$(dirname "${_implib}")/libLLVM-20.dll"
      [[ -f "${_llvm_dll}" ]] || _llvm_dll=$(find "${LLVM_BUILD}" -name 'libLLVM-20.dll' 2>/dev/null | awk 'NR==1')
      if [[ -n "${_llvm_dll}" ]] && [[ -f "${_llvm_dll}" ]]; then
        echo "WIN_IMPLIB_REGEN: implib had ${_llvm_nsyms} syms (<5000 threshold); regenerating from DLL via gendef+dlltool" >&2

        # Resolve host llvm-readobj: reads the target PE export table directly
        # from the built DLL (format-agnostic COFF/PE parser). No gendef-like
        # tool (gendef, pexports, mingw-w64-tools) is available anywhere in
        # this recipe's build dependencies -- llvm-readobj --coff-exports is
        # the available substitute for extracting exports from a built DLL.
        _regen_readobj=""
        for _cand in \
            "${BUILD_PREFIX}/Library/bin/llvm-readobj.exe" \
            "${BUILD_PREFIX}/Library/bin/llvm-readobj" \
            "${BUILD_PREFIX}/bin/llvm-readobj" \
            "$(command -v llvm-readobj 2>/dev/null || true)"; do
          [[ -x "${_cand}" ]] && { _regen_readobj="${_cand}"; break; }
        done

        # Resolve llvm-dlltool (same candidate search as _mingw.sh's _dlltool).
        _regen_dlltool=""
        for _cand in \
            "${BUILD_PREFIX}/bin/llvm-dlltool" \
            "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
            "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
            "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
            "$(command -v llvm-dlltool 2>/dev/null || true)"; do
          [[ -x "${_cand}" ]] && { _regen_dlltool="${_cand}"; break; }
        done

        if [[ -n "${_regen_readobj}" ]] && [[ -n "${_regen_dlltool}" ]]; then
          _llvm_dll_name="$(basename "${_llvm_dll}")"
          _regen_exports="$("${_regen_readobj}" --coff-exports "${_llvm_dll}" 2>/dev/null | awk '$1=="Name:"{print $2}')"
          _regen_def_nsyms=$(printf '%s\n' "${_regen_exports}" | grep -c . || echo 0)
          echo "WIN_IMPLIB_REGEN: extracted ${_regen_def_nsyms} export names from ${_llvm_dll}" >&2

          if [[ "${_regen_def_nsyms}" -gt 2 ]]; then
            _regen_def="${LLVM_BUILD}/libLLVM-20.regen.def"
            {
              echo "LIBRARY ${_llvm_dll_name}"
              echo "EXPORTS"
              printf '%s\n' "${_regen_exports}"
            } > "${_regen_def}"

            # NOTE: intentionally NOT calling _mingw.sh's _gen_implib() helper
            # here -- it short-circuits with `[[ -f "${lib}" ]] && return 0`,
            # and ${_implib} already exists on disk (broken/empty), so it
            # would silently no-op instead of regenerating. It is also a
            # function nested inside generate_mingw_import_libs(), only
            # registered once that unrelated outer workflow actually runs.
            # Replicate its underlying dlltool invocation directly instead.
            #
            # Regenerate to a FRESH sidecar path rather than in place: LLD
            # just wrote ${_implib} moments ago, and overwriting a file the
            # linker just produced (in place) was observed to still yield 0
            # symbols on native win-64. Writing to a fresh path and only
            # swapping it in on success avoids any such in-place-overwrite
            # hazard and lets diagnostics show exactly what dlltool produced.
            _implib_pre_size="unknown"
            _implib_pre_mtime="unknown"
            if [[ -f "${_implib}" ]]; then
              _implib_pre_size=$(stat -c '%s' "${_implib}" 2>/dev/null || stat -f '%z' "${_implib}" 2>/dev/null || echo "unknown")
              _implib_pre_mtime=$(stat -c '%y' "${_implib}" 2>/dev/null || stat -f '%m' "${_implib}" 2>/dev/null || echo "unknown")
            fi
            echo "WIN_IMPLIB_DIAG: pre-regen ${_implib} size=${_implib_pre_size} mtime=${_implib_pre_mtime}" >&2

            _implib_fresh="${_implib}.regen"
            rm -f "${_implib_fresh}"

            _dlltool_rc=0
            "${_regen_dlltool}" -m "${_dlltool_machine}" -D "${_llvm_dll_name}" \
              -d "${_regen_def}" -l "${_implib_fresh}" 2>"${LLVM_BUILD}/dlltool_regen.err" || _dlltool_rc=$?
            echo "WIN_IMPLIB_DIAG: dlltool exit code=${_dlltool_rc}" >&2
            if [[ "${_dlltool_rc}" -ne 0 ]]; then
              echo "WIN_IMPLIB_REGEN: dlltool regeneration command failed" >&2
              cat "${LLVM_BUILD}/dlltool_regen.err" >&2
            fi

            if [[ -f "${_implib_fresh}" ]]; then
              _implib_fresh_size=$(stat -c '%s' "${_implib_fresh}" 2>/dev/null || stat -f '%z' "${_implib_fresh}" 2>/dev/null || echo "unknown")
              echo "WIN_IMPLIB_DIAG: fresh implib ${_implib_fresh} size=${_implib_fresh_size}" >&2
            else
              echo "WIN_IMPLIB_DIAG: fresh implib ${_implib_fresh} NOT created" >&2
            fi

            _llvm_nsyms_fresh=$(strings -a "${_implib_fresh}" 2>/dev/null \
              | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || true)
            echo "WIN_IMPLIB_REGEN: fresh-path recount: ${_llvm_nsyms_fresh} symbols" >&2

            # Accept the freshly regenerated implib on dlltool success + real
            # file size, NOT the strings recount: `strings` under-counts on
            # native win-64 (the very bug this block works around), so a valid
            # multi-MB regenerated implib would be wrongly rejected. A real
            # libLLVM import lib is tens of MB; require >= 1MB as a sanity floor.
            _implib_fresh_bytes=$(stat -c '%s' "${_implib_fresh}" 2>/dev/null || stat -f '%z' "${_implib_fresh}" 2>/dev/null || echo 0)
            if [[ "${_dlltool_rc}" -eq 0 ]] && [[ "${_implib_fresh_bytes}" -ge 1048576 ]]; then
              mv -f "${_implib_fresh}" "${_implib}"
              echo "WIN_IMPLIB_REGEN: fresh implib accepted (dlltool rc=0, size=${_implib_fresh_bytes} >= 1MB; strings recount ${_llvm_nsyms_fresh}) -- replaced ${_implib}" >&2
            else
              echo "WIN_IMPLIB_REGEN: fresh implib rejected (dlltool rc=${_dlltool_rc}, size=${_implib_fresh_bytes}) -- leaving original ${_implib} in place" >&2
            fi

            _llvm_nsyms=$(strings -a "${_implib}" 2>/dev/null \
              | grep -cxE '[_A-Za-z?@][_A-Za-z0-9?@$]*' || true)
            echo "WIN_IMPLIB_REGEN: recount after regen: ${_llvm_nsyms} symbols" >&2
            echo "WIN_IMPLIB_DIAG: ===== dlltool_regen.err begin ====="
            cat "${LLVM_BUILD}/dlltool_regen.err" 2>/dev/null || echo "WIN_IMPLIB_DIAG: (err file absent: ${LLVM_BUILD}/dlltool_regen.err)"
            echo "WIN_IMPLIB_DIAG: ===== dlltool_regen.err end ====="
          else
            echo "WIN_IMPLIB_REGEN: extracted export list too small (${_regen_def_nsyms}) -- skipping regen attempt" >&2
          fi
        else
          echo "WIN_IMPLIB_REGEN: llvm-readobj or llvm-dlltool not resolvable -- cannot regenerate" >&2
        fi
      else
        echo "WIN_IMPLIB_REGEN: could not locate built DLL next to ${_implib} -- cannot regenerate" >&2
      fi
    fi

    # Authoritative override for native win-64: `strings`-based counting
    # under-reports on this platform, so both the Phase 1.5b critical-symbol
    # check and the nsyms gate below can false-fail on an implib that is
    # actually valid. If the DLL's real export table (llvm-readobj
    # --coff-exports, ${_regen_def_nsyms} names) is full AND the in-place implib
    # is a real multi-MB file, trust the export table: re-verify the critical
    # symbols against the actual export names and clear the strings-derived
    # failure. For win-32/win-arm64 the regen block never ran (_regen_def_nsyms
    # unset -> :-0 < 5000) and _llvm_nsyms >= 5000, so this never fires.
    if [[ "${_llvm_nsyms}" -lt 5000 ]] && [[ "${_regen_def_nsyms:-0}" -ge 5000 ]]; then
      _implib_bytes=$(stat -c '%s' "${_implib}" 2>/dev/null || stat -f '%z' "${_implib}" 2>/dev/null || echo 0)
      if [[ "${_implib_bytes}" -ge 1048576 ]]; then
        _crit_ok=1
        echo "WIN_IMPLIB_PROBE: _regen_exports var byte-size=$(printf %s "${_regen_exports}" | wc -c) line-count=$(printf %s "${_regen_exports}" | grep -c . 2>/dev/null || echo NA)" >&2
        echo "WIN_IMPLIB_PROBE: .def file ${_regen_def} size/lines:" >&2; wc -c -l "${_regen_def}" >&2 2>&1 || echo "WIN_IMPLIB_PROBE: no .def file" >&2
        echo "WIN_IMPLIB_PROBE: grep ErrorInfoBase in .def FILE:" >&2; grep -c "ErrorInfoBase" "${_regen_def}" >&2 2>&1 || echo "WIN_IMPLIB_PROBE: ErrorInfoBase absent in .def file" >&2
        echo "WIN_IMPLIB_PROBE: grep LLVMInitialize in .def FILE:" >&2; grep -c "LLVMInitialize" "${_regen_def}" >&2 2>&1 || echo "WIN_IMPLIB_PROBE: LLVMInitialize absent in .def file" >&2
        echo "WIN_IMPLIB_PROBE: llvm-nm armap count on implib:" >&2; "${_host_nm:-}" --print-armap "${_implib}" 2>/dev/null | grep -c "ErrorInfoBase\|LLVMInitialize" >&2 || echo "WIN_IMPLIB_PROBE: llvm-nm found neither / failed / _host_nm unset" >&2
        for _check_sym in ErrorInfoBase LLVMInitialize; do
          # Grep the on-disk .def FILE (proven reliable at line 884), NOT the
          # ~3.9MB in-memory _regen_exports bash var: a pipe-grep over a large
          # MSYS2 bash variable false-negatives on native win-64 even when the
          # export is genuinely present (WIN_IMPLIB_PROBE confirmed .def has both
          # symbols while the var-grep reported them missing). Same var-vs-file
          # anti-pattern the Phase-1.5b comment at 723-724 warned about.
          if grep -q "${_check_sym}" "${_regen_def}"; then
            echo "    OK (via export table): ${_check_sym} found"
          else
            echo "    FAIL (via export table): ${_check_sym} NOT found"
            _crit_ok=0
          fi
        done
        if [[ "${_crit_ok}" -eq 1 ]]; then
          echo "WIN_IMPLIB_REGEN: authoritative override -- export table has ${_regen_def_nsyms} syms, implib size=${_implib_bytes} >= 1MB; trusting export table over strings recount (${_llvm_nsyms})" >&2
          _llvm_nsyms="${_regen_def_nsyms}"
          _llvm_fail=0
        fi
      fi
    fi

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

    # Authoritative override for native win-64 (mirrors Phase 1.5c for libLLVM):
    # `strings`/zig-nm-based symbol counting can under-report on this platform
    # even though the DLL's actual PE export table is intact -- this is the
    # same LLD-MinGW empty-implib / string-scan blind spot already worked
    # around for libLLVM above. Before trusting the strings-derived failure,
    # check the DLL's real export table via llvm-readobj --coff-exports,
    # which parses the export directory directly instead of scanning for
    # symbol-like strings.
    if is_not_unix && [[ "${_clang_nsyms}" -lt 1000 ]]; then
      _clang_dll_probe=$(find "${LLVM_BUILD}" -name 'libclang-cpp*.dll' -o -name 'clang-cpp*.dll' 2>/dev/null | head -1)
      _clang_readobj=""
      for _cand in \
          "${BUILD_PREFIX}/Library/bin/llvm-readobj.exe" \
          "${BUILD_PREFIX}/Library/bin/llvm-readobj" \
          "${BUILD_PREFIX}/bin/llvm-readobj" \
          "$(command -v llvm-readobj 2>/dev/null || true)"; do
        [[ -x "${_cand}" ]] && { _clang_readobj="${_cand}"; break; }
      done
      if [[ -n "${_clang_dll_probe}" ]] && [[ -n "${_clang_readobj}" ]]; then
        _clang_export_names="$("${_clang_readobj}" --coff-exports "${_clang_dll_probe}" 2>/dev/null | awk '$1=="Name:"{print $2}')"
        _clang_export_nsyms=$(printf '%s\n' "${_clang_export_names}" | grep -c . || echo 0)
        echo "WIN_CLANG_EXPORT_PROBE: llvm-readobj --coff-exports found ${_clang_export_nsyms} export names in ${_clang_dll_probe}" >&2
        if [[ "${_clang_export_nsyms}" -ge 1000 ]]; then
          _crit_ok=1
          for _check_sym in SourceManager CompilerInstance ASTContext; do
            if printf '%s\n' "${_clang_export_names}" | grep -q "${_check_sym}"; then
              echo "    OK (via export table): ${_check_sym} found"
            else
              echo "    FAIL (via export table): ${_check_sym} NOT found"
              _crit_ok=0
            fi
          done
          if [[ "${_crit_ok}" -eq 1 ]]; then
            echo "WIN_CLANG_EXPORT_PROBE: authoritative override -- export table has ${_clang_export_nsyms} syms; trusting export table over strings recount (same native win-64 tooling gap as Phase 1.5c)" >&2
            _clang_nsyms="${_clang_export_nsyms}"
            _clang_fail=0
          fi
        fi
      fi
    fi
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
  # The NATIVE (build-arch, e.g. arm64) llvm-min-tblgen links libc++ dynamically
  # (zig-cxx does so regardless of the static -lc++), so it needs the build-arch
  # native-libcxx-install libc++.1.dylib, NOT the x86_64 TARGET libc++ in
  # LLVM_INSTALL/lib. Put native-libcxx-install/lib FIRST so dyld resolves the
  # libc++.1.dylib / libunwind leaf to the arch-correct one (DYLD_LIBRARY_PATH
  # matches by leaf name and takes precedence over @rpath). native-libcxx-install
  # exists only on cross builds; a missing dir is harmless (dyld skips it).
  export DYLD_LIBRARY_PATH="${SRC_DIR}/native-libcxx-install/lib:${LLVM_INSTALL}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  echo "  Phase 1: Building LLVM shared library..."
  set +e
  cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
  _phase1_rc=$?
  set -e

  if [[ ${_phase1_rc} -eq 0 ]]; then
    # OSX_DYLIB_LINK_DIAG (non-fatal): Phase 1 succeeded, but libLLVM.dylib on
    # native osx can still end up missing LLVMInitialize{AArch64,X86}Target
    # symbols. Dump the actual ninja link command for the dylib plus the key
    # levers (-all_load / -force_load / dead_strip) and probe the resulting
    # dylib for the target-init symbols, so we can see why without failing
    # the build.
    echo "=== OSX_DYLIB_LINK_DIAG: dylib link command (tail -5) ==="
    ( cd "${LLVM_BUILD}" && ninja -t commands lib/libLLVM.dylib 2>/dev/null | tail -5 ) || true
    echo "=== OSX_DYLIB_LINK_DIAG: all_load/force_load/dead_strip flags ==="
    ( cd "${LLVM_BUILD}" && ninja -t commands lib/libLLVM.dylib 2>/dev/null | tail -5 ) \
      | grep -oE -- '-Wl,-all_load|-Wl,-force_load[^ ]*|-dead_strip|-no_dead_strip' \
      || echo "OSX_DYLIB_LINK_DIAG: none of all_load/force_load/dead_strip flags present"
    echo "=== OSX_DYLIB_LINK_DIAG: target-init symbols in freshly-linked dylib ==="
    nm -gU "${LLVM_BUILD}/lib/libLLVM.dylib" 2>/dev/null \
      | grep -E 'LLVMInitialize(AArch64|X86)Target$' | head \
      || echo "OSX_DYLIB_LINK_DIAG: LLVMInitialize{AArch64,X86}Target ABSENT in freshly-linked dylib"
  fi

  if [[ ${_phase1_rc} -ne 0 ]]; then
    echo "=================================================================="
    echo "  Phase 1 FAILED (rc=${_phase1_rc}). Entering hypothesis test mode."
    echo "=================================================================="

    # DBG (osx native-tblgen libc++ arch-mismatch): the NATIVE host-arch
    # llvm-min-tblgen dyld-aborts loading @rpath/libc++.1.dylib (resolves only to
    # the x86_64 TARGET libc++). Dump its actual dylib deps + LC_RPATHs so we can
    # see whether the static-libc++ link held (no libc++.1.dylib load command) or
    # a dynamic dep leaked, and which rpath resolves it. Guides the rpath/DYLD fix.
    _native_tblgen="${LLVM_BUILD}/NATIVE/bin/llvm-min-tblgen"
    if [[ -x "${_native_tblgen}" ]]; then
      echo "=== DBG native tblgen: file ==="
      file "${_native_tblgen}" || true
      echo "=== DBG native tblgen: otool -L (dynamic deps) ==="
      otool -L "${_native_tblgen}" || true
      echo "=== DBG native tblgen: otool -l LC_RPATH ==="
      otool -l "${_native_tblgen}" | grep -A2 LC_RPATH || true
    else
      echo "  DBG: native tblgen not found at ${_native_tblgen}"
    fi

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
      "H6|direct-zig|append|-Wl,-syslibroot,${_sdkroot}"
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
          _modified_cmd=$(echo "${_bare_link_cmd}" | sed -E "s/(aarch64|x86_64)-macos-none/\\1-macos.${_ver}-none/g")
          _append="${_rest##*append|}"
          _modified_cmd="${_modified_cmd} ${_append}"
          ;;
        direct-zig\|*)
          # Replace zig-force-load-cxx with direct zig c++ call (skip wrapper filtering).
          # Direct zig c++ does NOT accept -all_load / -Wl,-all_load (unsupported linker arg),
          # so strip those flags. The .a archives are already on the link line directly;
          # without -all_load zig links only referenced symbols (standard behaviour).
          _zig_bin="${BUILD_PREFIX}/bin/${HOST_PLATFORM:-arm64-apple-darwin}-zig"
          [[ ! -x "${_zig_bin}" ]] && _zig_bin=$(find "${BUILD_PREFIX}/bin" -name '*-zig' -not -name '*.cmd' 2>/dev/null | head -1)
          _modified_cmd=$(echo "${_bare_link_cmd}" | sed -E "s|[^ ]*zig-force-load-cxx|${_zig_bin} c++ -target aarch64-macos.${MACOSX_DEPLOYMENT_TARGET:-11.0}-none -mcpu=baseline|")
          # Strip -all_load / -Wl,-all_load — not accepted by zig's Mach-O linker directly
          _modified_cmd=$(echo "${_modified_cmd}" | sed -E 's/ -Wl,-all_load / /g; s/ -Wl,-all_load$//; s/ -all_load / /g; s/ -all_load$//')
          _append="${_rest##*append|}"
          _modified_cmd="${_modified_cmd} ${_append}"
          ;;
        append\|*)
          _append="${_rest#append|}"
          _modified_cmd="${_bare_link_cmd} ${_append}"
          ;;
      esac

      # Zig 0.15.2 build 27 rejects two flags that the original CMake/ninja link
      # command (and several of the hypotheses) still inject:
      #   -Wl,-all_load / -all_load    (Apple ld; use -Wl,-force_load per-archive
      #                                  or rely on lld linking referenced syms only)
      #   -Wl,-syslibroot,<path>       (Apple ld; use -isysroot or --sysroot=)
      # Strip them from every hypothesis baseline so the hypothesis-specific
      # append actually gets a chance to drive the link strategy. H1-H6 will
      # effectively collapse onto the bare baseline (their appended -syslibroot
      # gets re-stripped), but H7-H10 (env-prefix / --sysroot= / -isysroot /
      # -nostdlib++) get a clean shot at producing libLLVM.dylib.
      #
      # NOTE: BSD sed on macOS does not support \b as a word boundary (it would
      # be interpreted as literal `b`), so we use explicit space/end-of-line
      # anchors instead of \b. The pattern matches ` flag ` (token surrounded
      # by spaces) OR ` flag$` (token at end of line) and replaces with a
      # single space (preserving spacing for the surrounding tokens).
      _modified_cmd=$(echo "${_modified_cmd}" | sed -E '
        s/ -Wl,-all_load / /g
        s/ -Wl,-all_load$//
        s/ -all_load / /g
        s/ -all_load$//
        s/ -Wl,-syslibroot,[^ ]+ / /g
        s/ -Wl,-syslibroot,[^ ]+$//
      ')

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
      _zig_bin="${BUILD_PREFIX}/bin/${HOST_PLATFORM:-arm64-apple-darwin}-zig"
      [[ ! -x "${_zig_bin}" ]] && _zig_bin=$(find "${BUILD_PREFIX}/bin" -name '*-zig' -not -name '*.cmd' 2>/dev/null | head -1)
      # Build the diagnostic command: replace wrapper with direct zig c++ -v,
      # strip -all_load variants (unsupported by direct zig), add SDK flags to reduce noise.
      _diag_cmd=$(echo "${_bare_link_cmd}" | sed -E "s|[^ ]*zig-force-load-cxx|${_zig_bin} c++ -v -target aarch64-macos.${MACOSX_DEPLOYMENT_TARGET:-11.0}-none -mcpu=baseline|")
      _diag_cmd=$(echo "${_diag_cmd}" | sed -E 's/ -Wl,-all_load / /g; s/ -Wl,-all_load$//; s/ -all_load / /g; s/ -all_load$//')
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

