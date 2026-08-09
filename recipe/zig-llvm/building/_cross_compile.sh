# Cross-compilation detection and setup
# CONDA_BUILD_CROSS_COMPILATION is set by conda-build when build_platform != target_platform
CMAKE_CROSS_FLAGS=()
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  # Determine target system name for cmake
  is_linux && CMAKE_SYSTEM_NAME="Linux"
  is_osx && CMAKE_SYSTEM_NAME="Darwin"
  is_not_unix && CMAKE_SYSTEM_NAME="Windows"

  CMAKE_CROSS_FLAGS=(
    -DCMAKE_CROSSCOMPILING=True
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_BINDIR=bin
    -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
    -DLLVM_HOST_TRIPLE="${LLVM_TRIPLET}"
  )

  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  # Find a build-host tool by name (with optional .exe), excluding an optional variant name.
  _find_build_tool() {
    # $1 = tool base name; $2 = optional variant to exclude
    # Use an array for the exclusion so the predicates stay as separate find
    # arguments regardless of IFS. This script runs under IFS=$'\n\t' (no space),
    # so an unquoted ${2:+...} expansion would collapse "! -name X ! -name X.exe"
    # into a single argument and make find fail (empty result -> build aborts).
    local excl=()
    # Guard with ${2:-} so the single-arg call form (e.g. clang-tblgen) does not
    # trip `set -u` (nounset) on an unbound $2. The bare $2 inside the branch is
    # safe: it only runs when $2 is non-empty, hence set.
    [[ -n "${2:-}" ]] && excl=( ! -name "$2" ! -name "$2.exe" )
    find "${BUILD_PREFIX}" \( -name "$1" -o -name "$1.exe" \) "${excl[@]}" -type f 2>/dev/null | head -1
  }
  LLVM_TBLGEN=$(_find_build_tool llvm-tblgen llvm-min-tblgen)
  CLANG_TBLGEN=$(_find_build_tool clang-tblgen)
  # Append tblgen paths if found (use += to preserve existing flags).
  # LLVM 20 uses CLANG_TABLEGEN_EXE (not CLANG_TABLEGEN).
  if [[ -n "${LLVM_TBLGEN}" ]]; then
    # LLVM 20+ TableGen variable resolution:
    #   LLVM_TABLEGEN: legacy cache variable (still honored).
    #   LLVM_TABLEGEN_EXE: internal var consulted by tablegen() macro on LLVM 20+.
    #     Without this, the macro may fall back to MIN tblgen for some generators
    #     (e.g. -gen-asm-matcher on WebAssembly), producing "Unknown command line argument" errors.
    #   LLVM_MIN_TABLEGEN_EXE: bootstrap-only minimal tblgen. Pointed at the FULL
    #     llvm-tblgen.exe since it is a strict superset (handles every generator
    #     min-tblgen handles, plus the rest). Safe and avoids the asm-matcher mismatch.
    _tblgen_dir=$(dirname "${LLVM_TBLGEN}")
    CMAKE_CROSS_FLAGS+=(
      -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
      -DLLVM_TABLEGEN_EXE="${LLVM_TBLGEN}"
      -DLLVM_MIN_TABLEGEN_EXE="${LLVM_TBLGEN}"
      -DLLVM_NATIVE_TOOL_DIR="${_tblgen_dir}"
    )
  fi
  [[ -n "${CLANG_TBLGEN}" ]] && CMAKE_CROSS_FLAGS+=(-DCLANG_TABLEGEN_EXE="${CLANG_TBLGEN}")

  # CROSS_TOOLCHAIN_FLAGS_NATIVE: tells LLVM's NATIVE sub-project which
  # compiler to use for building host tools (tablegen etc.).
  # Without this, NATIVE inherits CMAKE_C/CXX_COMPILER which target the
  # cross architecture (e.g. ppc64le), producing .o that can't link on
  # the build host (x86_64).
  if is_linux; then
    # Linux cross-builds: use BUILD_PREFIX zig-gcc wrappers for NATIVE tools.
    # The wrappers (from zig-gcc build dep) target the build host (x86_64) and
    # include sysroot detection, flag filtering, LLD auto-promotion, and
    # --no-dependent-libraries. Using raw "zig cc" bypasses all of that.
    # CONDA_ZIG_BUILD is the BUILD-arch triple (x86_64-conda-linux-gnu-zig); the
    # -cc/-cxx wrappers are created in build.sh. (${CONDA_BUILD_ZIG} was a
    # never-assigned name transposition -> empty -> ${BUILD_PREFIX}/bin/-cc, which
    # cmake rejects when configuring LLVM's NATIVE host-tblgen sub-project.)
    _native_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    _native_cxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
    # ASM uses the cc wrapper; no separate -asm wrapper is created (build.sh sets
    # ZIG_ASM to the cc wrapper too).
    _native_asm="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    # Floor the NATIVE host tools (llvm-tblgen etc.) to the conda linux-64 glibc
    # floor (2.17), same reason as the native runtimes: the build-arch zig cc
    # otherwise native-targets modern glibc where libdl/libpthread/librt are merged
    # into libc and lld cannot resolve their dependent-library records.
    _native_target="${ZIG_TARGET_BUILD}.2.17"
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_C_COMPILER_TARGET=${_native_target};-DCMAKE_CXX_COMPILER_TARGET=${_native_target};-DCMAKE_ASM_COMPILER_TARGET=${_native_target};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF"
    )
  elif is_osx; then
    # macOS cross (arm64 build host -> osx-64 target, or the reverse; runs only when
    # CONDA_BUILD_CROSS_COMPILATION=1). The LLVM NATIVE sub-project
    # ($SRC_DIR/conda-llvm-build/NATIVE, driven by LLVM own CrossCompile.cmake) builds
    # host tools that must run on the BUILD arch. With no override it inherits
    # CMAKE_C/CXX_COMPILER = the TARGET x86_64 zig-cc wrapper (locked to the x86_64
    # darwin/core2 baseline) while CMake still passes the build host -arch arm64 ->
    # "unknown target CPU core2". Point NATIVE at the build-arch zig-cc wrappers
    # (${CONDA_ZIG_BUILD}-cc, created in build.sh when BUILD!=HOST, invoked WITHOUT
    # -target so they default to the real build-host macOS target) and force the
    # matching CMAKE_OSX_ARCHITECTURES so -arch and compiler agree. No glibc floor on macOS.
    _native_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    _native_cxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
    _native_asm="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    _native_osx_arch="arm64"
    [[ "${build_platform}" == "osx-64" ]] && _native_osx_arch="x86_64"
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_OSX_ARCHITECTURES=${_native_osx_arch};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF"
    )
  elif is_not_unix; then
    # Native host tools (llvm-min-tblgen.exe etc.) must run on the x86_64 win-64
    # build host, not the aarch64 target. CONDA_BUILD_ZIG resolves to the TARGET
    # triple (aarch64-w64-mingw32-zig), so we hard-code the build-host triple here.
    _native_host_triple="x86_64-w64-mingw32"
    _native_zig_target="x86_64-windows-gnu"   # zig target query for the NATIVE build (mingw32 OS token is rejected by zig)
    _host_cc_exe="${BUILD_PREFIX}/Library/bin/${_native_host_triple}-zig-cc.exe"
    _host_cxx_exe="${BUILD_PREFIX}/Library/bin/${_native_host_triple}-zig-cxx.exe"
    _host_ar_bat="${BUILD_PREFIX}/Library/bin/${_native_host_triple}-zig-ar.exe"
    _host_ranlib_bat="${BUILD_PREFIX}/Library/bin/${_native_host_triple}-zig-ranlib.exe"

    # Write a CMake project-include file for the NATIVE sub-project.
    # This file patches the link rule templates after platform detection.
    #
    # zig lld-link rejects /version:0.0 (auto-set by CMake for versionless Windows targets).
    # CMAKE_PROJECT_INCLUDE is used here because it runs LAST in project(), after platform
    # modules set link rule vars, so it can patch them via string(REPLACE). Earlier hooks
    # (-D, -C ... CACHE FORCE, CMAKE_USER_MAKE_RULES_OVERRIDE) get overridden by platform-module
    # processing before they'd take effect.
    #
    # Use SRC_DIR (forward-slash path) directly to avoid the CMake 4.2 backslash-escape bug.
    _fwd_src_dir="${SRC_DIR}"
    # Native Windows cmake.exe needs D:/a/... (forward-slash drive form); SRC_DIR already provides this form.
    _native_project_include_fwd="${SRC_DIR}/_native_cmake_project_include.cmake"
    # Write to the same path that will be passed to cmake, so write-path == passed-path.
    cat > "${_native_project_include_fwd}" << 'NATIVE_CMINIT'
# Fix: zig lld-link rejects /version:0.0 for Windows executables built in the
# NATIVE cross-build sub-project (llvm-min-tblgen.exe etc.).
#
# CMake's Windows-GNU.cmake defines:
#   CMAKE_GNULD_IMAGE_VERSION =
#     "-Wl,--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
# and bakes it into CMAKE_${lang}_LINK_EXECUTABLE via ${CMAKE_GNULD_IMAGE_VERSION}.
# Executables without explicit VERSION property get <TARGET_VERSION_MAJOR>=0,
# <TARGET_VERSION_MINOR>=0. Zig translates --major-image-version,0,... to
# lld-link /version:0.0, which zig lld-link rejects as InvalidVersion.
#
# This file runs via CMAKE_PROJECT_INCLUDE (last step of project(), after all
# platform modules have set the link rule variables). string(REPLACE) patches the
# zero-version generator expressions with hardcoded 1,0 before CMake generates
# build.ninja. Handles both Windows-GNU format (--major-image-version) and
# Windows-Clang format (/version:) for robustness.
message(STATUS ">>> NATIVE CMAKE_PROJECT_INCLUDE: patching link rules for zig lld-link /version:0.0 fix")
if(WIN32)
  foreach(_native_lang IN ITEMS C CXX ASM)
    foreach(_native_rule IN ITEMS
        CMAKE_${_native_lang}_LINK_EXECUTABLE
        CMAKE_${_native_lang}_CREATE_SHARED_LIBRARY
        CMAKE_${_native_lang}_CREATE_SHARED_MODULE)
      if(DEFINED ${_native_rule})
        string(REPLACE
          "--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
          "--major-image-version,1,--minor-image-version,0"
          ${_native_rule} "${${_native_rule}}")
        # MSVC /version: form — zig lld-link rejects /version:X.Y as InvalidVersion.
        # The image version is already set via the GNU --major-image-version path
        # above (and CMAKE_EXE_LINKER_FLAGS_INIT), so STRIP the redundant /version:
        # token entirely. Strip with the -Xlinker prefix first (clang driver form),
        # then any bare occurrence, to avoid leaving a dangling -Xlinker.
        string(REPLACE
          "-Xlinker /version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR>"
          ""
          ${_native_rule} "${${_native_rule}}")
        string(REPLACE
          "/version:<TARGET_VERSION_MAJOR>.<TARGET_VERSION_MINOR>"
          ""
          ${_native_rule} "${${_native_rule}}")
      endif()
    endforeach()
  endforeach()
  message(STATUS ">>> NATIVE CMAKE_PROJECT_INCLUDE: link rules patched (version stripped; GNU image-version retained)")
endif()
NATIVE_CMINIT

    # CMake compiler probe builds an exe by default, which on Windows injects
    # -Xlinker /version:0.0 — zig lld-link rejects bare 0.0 as InvalidVersion.
    # Build a static lib for the probe instead (no link, no /version: flag).
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_exe};-DCMAKE_CXX_COMPILER=${_host_cxx_exe};-DCMAKE_ASM_COMPILER=${_host_cc_exe};-DCMAKE_AR=${_host_ar_bat};-DCMAKE_RANLIB=${_host_ranlib_bat};-DCMAKE_C_COMPILER_TARGET=${_native_zig_target};-DCMAKE_CXX_COMPILER_TARGET=${_native_zig_target};-DCMAKE_ASM_COMPILER_TARGET=${_native_zig_target};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024;-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY;-DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_SHARED_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_PROJECT_INCLUDE=${_native_project_include_fwd}"
    )
    unset _fwd_src_dir _native_project_include_fwd
  fi

  # Zig parses compiler target queries in 3-component format (<arch>-<os>-<abi>);
  # clang's 4-component LLVM triple (e.g. aarch64-unknown-linux-gnu) makes zig
  # treat "unknown" as the OS and fail with UnknownOperatingSystem.
  # Strip the "-unknown-" middle component to get the zig-compatible triple.
  # NOTE: ZIG_LLVM_TRIPLET is also used in the runtimes is_cross block below.
  ZIG_LLVM_TRIPLET="$(zig_triplet_from_llvm "${LLVM_TRIPLET}")"

  # Cross-compilation: tell cmake the main LLVM configure the compiler's target
  # triple explicitly. Without this, cmake's ABI detection probes the wrapper by
  # filename and may infer the build-host triple (x86_64) instead of the target
  # triple (e.g. aarch64), causing it to link test binaries as x86_64 against
  # the freshly-installed target-arch libc++ — producing an elf incompatibility
  # error ("libc++.so.1 is incompatible with elf_x86_64").
  if is_cross; then
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_C_ABI_COMPILED=TRUE
      -DCMAKE_CXX_ABI_COMPILED=TRUE
    )
  fi

fi

# ppc64le: zig's self-hosted linker looks for `cc` in PATH to use as the
# GCC linker driver, but needs the ppc64le GCC (native or cross) to spawn
# correctly. Create a `cc` symlink so zig finds the right linker. Also skip
# CMake's link test since zig's self-hosted linker injects -m elf64lppc then
# chokes on it.
# Applied unconditionally (regardless of is_cross/CONDA_BUILD_CROSS_COMPILATION),
# appended with += AFTER the guard above (same pattern as the glibc floor block
# below): the NATIVE ppc64le lane needs this workaround just as much as cross
# builds do, since zig's self-hosted linker spawns a literal bare `gcc` on
# ppc64le regardless of whether the build is cross or native. Placed here
# (was previously nested inside the CONDA_BUILD_CROSS_COMPILATION guard above,
# so it never ran for native ppc64le) to match recipe.yaml's unconditional-on-
# ppc64le `gcc_impl_${{ build_platform }}`/`binutils_impl_${{ build_platform }}`
# build deps, which install the same triplet-prefixed compiler for both native
# and cross ppc64le lanes (PR #123:
# linux_ppc64le_cross_target_platform_linux-ppc64le NATIVE lane failed with
# "Failed to spawn GCC: FileNotFound" while compiling libc++ runtimes, because
# this block was unreachable there).
# TODO: Remove once zig fixes self-hosted linker for ppc64le.
if [[ "${LLVM_TRIPLET}" == powerpc64le-* ]]; then
  # Force zig-cc to select shared libc++ instead of zig-cache static .a.
  # libcxx_shared.findSharedLibCxxString skips its logic when target_arch !=
  # build_arch UNLESS this env var is set (cross-arch ppc64le from x86_64).
  export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib/zig-llvm/lib"

  # Force CMake to skip compiler linking tests. zig's self-hosted linker
  # injects -m elf64lppc then chokes on it, and CMAKE_TRY_COMPILE_TARGET_TYPE
  # doesn't prevent CMakeTestCCompiler from linking. Compilation is verified
  # by the pre-flight test above; linking isn't needed (libraries only).
  CMAKE_CROSS_FLAGS+=(
    -DCMAKE_C_COMPILER_WORKS=TRUE
    -DCMAKE_CXX_COMPILER_WORKS=TRUE
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  )
  # ppc64le GCC redirect doesn't propagate sysroot/-L paths from the wrapper.
  # libLLVM.so has DT_NEEDED for libz.so.1, libzstd.so.1, libxml2.so.16.
  # Consumers (llvm-ar etc.) need -rpath-link at link time (not just runtime rpath).
  # Cover both flat ($PREFIX/lib) and zig-* isolated layouts; non-existent dirs are no-ops.
  _rpath_link="-Wl,-rpath-link,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zlib/lib -Wl,-rpath-link,${PREFIX}/lib/zig-zstd/lib -Wl,-rpath-link,${PREFIX}/lib/zig-libxml2/lib -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/usr/lib64 -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/lib64"
  CMAKE_CROSS_FLAGS+=(
    -DCMAKE_EXE_LINKER_FLAGS_INIT="${_rpath_link}"
    # Allow zig-cc to inject bundled libc++/libc++abi into the link command;
    # the ld.bfd wrapper below intercepts and swaps these static .a files for
    # the recipe's shared libc++.so, preventing LOCAL_DEFINED merges.
    -DCMAKE_SHARED_LINKER_FLAGS_INIT="${_rpath_link}"
  )
  unset _rpath_link
  # zig's self-hosted linker looks for `cc` in PATH as GCC linker driver for
  # compilation, but invokes ld.bfd directly from GCC's libexec path for linking.
  # The sysroot's libpthread.so is a GNU ld script with absolute paths:
  #   GROUP ( /lib64/libpthread.so.0 /usr/lib64/libpthread_nonshared.a )
  # ld.bfd resolves these from the build host's /lib64 (x86_64) rather than the
  # ppc64le sysroot, because zig's self-hosted linker doesn't pass --sysroot.
  # Fix: wrap the ld.bfd binary in GCC's libexec path with a script that injects
  # --sysroot before any other args. This ensures all ld.bfd invocations (whether
  # from GCC or zig's self-hosted linker) get the correct sysroot.
  _ppc_gcc="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-gcc"
  _ppc_sysroot_early="${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot"
  if [[ -x "${_ppc_gcc}" ]]; then
    _ppc_bin="${SRC_DIR}/_ppc64le_bin"
    mkdir -p "${_ppc_bin}"
    ln -sf "${_ppc_gcc}" "${_ppc_bin}/cc"
    export PATH="${_ppc_bin}:${PATH}"

    # Wrap ld.bfd to inject --sysroot automatically.
    # zig's self-hosted linker calls ld.bfd directly from GCC's libexec path
    # (as a symlink -> $BUILD_PREFIX/bin/powerpc64le-conda-linux-gnu-ld),
    # bypassing GCC's spec-file sysroot injection. We intercept by replacing
    # the real ld binary with a wrapper that adds --sysroot, then renaming
    # the original to ld.real. The libexec symlink keeps pointing to bin/ld
    # which is now the wrapper.
    _ppc_ld_bin="${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
    if [[ -x "${_ppc_ld_bin}" ]] && [[ ! -f "${_ppc_ld_bin}.real" ]]; then
      mv "${_ppc_ld_bin}" "${_ppc_ld_bin}.real"
      # zig's self-hosted linker drops -lpthread/-ldl when building its ld.bfd
      # invocation for ppc64le — it only passes -lgcc/-lgcc_s/-lc as implicit
      # libs. This causes -z defs to fail on libunwind.so (pthread_rwlock_*
      # and dladdr/dlsym undefined). We inject -lpthread -ldl after the
      # object files for any -shared build. The --sysroot ensures ld.bfd finds
      # libpthread.so.0 in the sysroot rather than the build host's /lib64.
      cat > "${_ppc_ld_bin}" << PPCLD
#!/usr/bin/env bash
_args=("--sysroot=${_ppc_sysroot_early}")
# Sysroot library search path + rpath-link is needed for EVERY link, not just
# -shared. Executables that link libLLVM.so as a DSO trigger rpath-link
# resolution of libLLVM's DT_NEEDED (libstdc++.so.6), which lives in the
# sysroot. Without this, bin/clang-fuzzer-dictionary etc. fail with
# 'libstdc++.so.6 not found' + undefined references to @GLIBCXX_3.4 symbols.
_args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib")
_args+=(-L"${PREFIX}/lib/zig-llvm/lib")
_args+=(-L"${PREFIX}/lib")                          # libz/libzstd/libxml2 from $PREFIX/lib
_args+=(-rpath-link "${PREFIX}/lib")                # transitive DT_NEEDED resolution for libLLVM.so
_args+=(-rpath-link "${_ppc_sysroot_early}/usr/lib64" -rpath-link "${_ppc_sysroot_early}/usr/lib")
_is_shared=0
for _a in "\$@"; do
    [[ "\$_a" == "-shared" ]]    && _is_shared=1
    _args+=("\$_a")
done
if (( _is_shared )); then
    _args+=(-lpthread -ldl -lrt -lm)
fi
# NOTE: Do NOT inject -lstdc++ here. libc++abi.a is already in the link
# command (from zig-cc's libc++/libc++abi/libunwind bundle), which provides
# the std::* typeinfo symbols (runtime_error, logic_error, length_error,
# etc.) statically. Injecting -lstdc++ would cause dynamic libstdc++.so.6
# to win over libc++abi.a, baking DT_NEEDED libstdc++.so.6 into the output
# DSO and breaking downstream links (clang-fuzzer-dictionary @GLIBCXX_3.4
# undefined refs).
# Swap zig's bundled static libc++/libc++abi/libunwind (which reference symbols
# only in libstdc++.so on ppc64le, re-introducing the libstdc++ dependency) for
# the recipe's zig-libcxx shared libs (built libstdc++-free). Replacement path
# from ZIG_LIBCXX_DIR (default \${PREFIX}/lib/zig-llvm/lib). Falls back to
# original path if replacement .so is missing.
_libcxx_dir="\${ZIG_LIBCXX_DIR:-${PREFIX}/lib/zig-llvm/lib}"
_libcxx_so="\${_libcxx_dir}/libc++.so"
_libunwind_so="\${_libcxx_dir}/libunwind.so"
_swap_args=()
for _a in "\${_args[@]}"; do
    case "\${_a}" in
        */zig-cache/*/libc++.a|*/zig-cache/*/libc++abi.a|*/.cache/zig/*/libc++.a|*/.cache/zig/*/libc++abi.a)
            if [[ -f "\${_libcxx_so}" ]]; then
                _swap_args+=("\${_libcxx_so}")
            else
                _swap_args+=("\${_a}")
            fi
            ;;
        */zig-cache/*/libunwind.a|*/.cache/zig/*/libunwind.a)
            if [[ -f "\${_libunwind_so}" ]]; then
                _swap_args+=("\${_libunwind_so}")
            else
                _swap_args+=("\${_a}")
            fi
            ;;
        *)
            _swap_args+=("\${_a}")
            ;;
    esac
done
_args=("\${_swap_args[@]}")
exec "${_ppc_ld_bin}.real" "\${_args[@]}"
PPCLD
      chmod +x "${_ppc_ld_bin}"
    fi
  fi
fi

# Re-attach the glibc symbol-version floor so zig-cc compiles the LLVM/clang
# shared libs against it (e.g. exp2@GLIBC_2.17), matching the final zig
# compiler self-build link (build-zig.sh's build-exe uses -Dtarget=${ZIG_TRIPLET}).
# Without a floor, CMAKE_*_COMPILER_TARGET above is either unset (native builds)
# or the bare 3-component triple with no glibc suffix (cross builds, see the
# is_cross block above), so zig-cc compiles against its newest bundled glibc
# and libclang-cpp.so ends up referencing symbols like exp2@GLIBC_2.29 -- which
# then fails zig's --no-allow-shlib-undefined at the final zig build-exe
# self-build link ("undefined reference: exp2@GLIBC_2.29, referenced by
# libclang-cpp.so.21.1"; PR #123 linux-64 NATIVE lane CI, 2026-07-23). The
# floor is taken verbatim from ZIG_TRIPLET (single source of truth for the
# glibc version this recipe targets; recipe.yaml's zig_triplet). Linux-gnu
# only -- osx/win triples carry no glibc floor. Prior art: this exact
# mechanism exists in the 0.15.2-era zig-feedstock's
# recipe/llvm/building/_cross_compile.sh (glibc symbol-version floor block).
#
# Applied unconditionally (regardless of is_cross/CONDA_BUILD_CROSS_COMPILATION),
# appended with += AFTER the guard above so it overrides any non-floored
# CMAKE_*_COMPILER_TARGET the is_cross block set for linux-gnu targets: on a
# NATIVE build (build_platform == target_platform, e.g. linux-64 native) the
# floor is just as necessary as on cross builds, since zig-cc's default glibc
# version is independent of whether the build is cross or native -- the
# exp2@GLIBC_2.29 failure above was observed on the NATIVE linux-64 lane.
if is_linux; then
  _glibc_floor_triplet="$(zig_triplet_from_llvm "${LLVM_TRIPLET}")"

  if [[ "${_glibc_floor_triplet}" == *-linux-gnu* && "${ZIG_TRIPLET}" =~ (\.[0-9]+\.[0-9]+)$ ]]; then
    _glibc_floor_triplet="${_glibc_floor_triplet}${BASH_REMATCH[1]}"
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_TARGET="${_glibc_floor_triplet}"
      -DCMAKE_CXX_COMPILER_TARGET="${_glibc_floor_triplet}"
      -DCMAKE_ASM_COMPILER_TARGET="${_glibc_floor_triplet}"
    )
    echo "  glibc symbol-version floor: CMAKE_{C,CXX,ASM}_COMPILER_TARGET=${_glibc_floor_triplet}"
  fi
  unset _glibc_floor_triplet
fi
