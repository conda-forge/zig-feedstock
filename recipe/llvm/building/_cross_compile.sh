# Cross-compilation detection and setup
# CONDA_BUILD_CROSS_COMPILATION is set by conda-build when build_platform != target_platform
CMAKE_CROSS_FLAGS=()

# Re-attach the glibc symbol-version floor so zig-cc compiles the LLVM shared
# libs against it (e.g. pow@GLIBC_2.17), matching the final zig compiler link
# (zig_build.sh uses -Dtarget=${ZIG_TRIPLET}). Without this, CMAKE_*_COMPILER_TARGET
# is the bare triple (aarch64-linux-gnu), so zig defaults to its newest bundled
# glibc and libLLVM/libclang-cpp reference pow@GLIBC_2.29 / exp2@GLIBC_2.29, which
# then fail --no-allow-shlib-undefined at the final zig build-exe link. The floor
# is taken verbatim from ZIG_TRIPLET (single source of truth; per-variant: 2.17,
# or 2.39 for riscv64). Linux-gnu only — osx/win triples carry no glibc floor.
#
# Applied unconditionally (regardless of is_cross/CONDA_BUILD_CROSS_COMPILATION):
# on a NATIVE build (build_platform==target_platform) the floor is just as
# necessary as on cross builds, since zig-cc's default glibc version is
# independent of whether the build is cross or native. Without this, native
# builds would compile libLLVM/libclang-cpp against zig's newest bundled glibc
# instead of the floor — the same failure this block exists to prevent, just
# triggered on native jobs instead of cross jobs.
if is_linux; then
  ZIG_LLVM_TRIPLET="${LLVM_TRIPLET/-unknown-/-}"
  ZIG_LLVM_TRIPLET="${ZIG_LLVM_TRIPLET/-w64-/-}"

  if [[ "${ZIG_LLVM_TRIPLET}" == *-linux-gnu* && "${ZIG_TRIPLET}" =~ (\.[0-9]+\.[0-9]+)$ ]]; then
    ZIG_LLVM_TRIPLET="${ZIG_LLVM_TRIPLET}${BASH_REMATCH[1]}"
  fi

  if [[ "${ZIG_LLVM_TRIPLET}" == *-linux-gnu* ]]; then
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
      -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    )
  fi
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  echo "=== Cross-compilation detected ==="
  echo "  Build platform: ${build_platform}"
  echo "  Target platform: ${target_platform}"

  # Determine target system name for cmake
  is_linux && CMAKE_SYSTEM_NAME="Linux"
  is_osx && CMAKE_SYSTEM_NAME="Darwin"
  is_not_unix && CMAKE_SYSTEM_NAME="Windows"

  if [[ ! -x "${BUILD_PREFIX}/bin/${CONDA_ZIG_HOST}" ]]; then
    mamba install -y -p "${BUILD_PREFIX}" -c conda-forge "zig_${target_platform}"
  fi

  # NOTE: appended (+=), not reassigned, to preserve the glibc-floor
  # CMAKE_*_COMPILER_TARGET flags added unconditionally above this guard.
  CMAKE_CROSS_FLAGS+=(
    -DCMAKE_CROSSCOMPILING=True
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_BINDIR=bin
    -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
    -DLLVM_HOST_TRIPLE="${LLVM_TRIPLET}"
  )

  # ppc64le: zig's self-hosted linker looks for `cc` in PATH to use as the
  # GCC linker driver, but needs the cross-GCC for ppc64le. Create a `cc`
  # symlink so zig finds the right linker. Also skip CMake's link test since
  # zig's self-hosted linker injects -m elf64lppc then chokes on it.
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
      # the ld.bfd wrapper below (lines 114-143) intercepts and swaps these static
      # .a files for the recipe's shared libc++.so, preventing LOCAL_DEFINED merges.
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
      echo "  ppc64le: cc -> ${_ppc_gcc}"

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
        */zig-cache/*/libc++.a|*/zig-cache/*/libc++abi.a)
            if [[ -f "\${_libcxx_so}" ]]; then
                _swap_args+=("\${_libcxx_so}")
            else
                _swap_args+=("\${_a}")
            fi
            ;;
        */zig-cache/*/libunwind.a)
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
        echo "  ppc64le: ld.bfd wrapped at ${_ppc_ld_bin} -> injects --sysroot + -lpthread -ldl for shared"
      fi
    fi
  fi


  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  # Find a build-host tool by name (with optional .exe), excluding an optional
  # variant name. Mirrors package-incubator/recipes/zig-llvm/building/
  # _cross_compile.sh's _find_build_tool (~line 161), which both llvm-tblgen
  # and clang-tblgen resolution share there. Factored the same way here so
  # locating clang-tblgen is the same search style as llvm-tblgen, not a
  # one-off inline find.
  _find_build_tool() {
    # $1 = tool base name; $2 = optional variant to exclude
    # NOTE: build.sh sets IFS=$'\n\t' (no space), so the previous unquoted
    # ${2:+! -name "$2" ...} splice collapsed into a SINGLE find arg -> find
    # errored on the malformed predicate -> empty result -> set -e/pipefail
    # aborted the zig_impl build before the [[ -n "${LLVM_TBLGEN}" ]] fallback
    # (fast-fail on ppc64le/riscv64/osx-64, PR #109 @ f5db9ab2). Build the
    # exclusion as an explicit array so the words survive strict IFS.
    local _excl=()
    [[ -n "${2:-}" ]] && _excl=( ! -name "$2" ! -name "$2.exe" )
    find "${BUILD_PREFIX}" \( -name "$1" -o -name "$1.exe" \) "${_excl[@]}" -type f 2>/dev/null | head -1
  }
  LLVM_TBLGEN=$(_find_build_tool llvm-tblgen llvm-min-tblgen)
  echo "  LLVM_TBLGEN resolved to: ${LLVM_TBLGEN:-<not found>}"

  # clang-tblgen: zig_impl_${build_platform} ships this alongside llvm-tblgen
  # at lib/zig-llvm/bin/ (see recipe.yaml package_contents, ~line 406), so the
  # same BUILD_PREFIX search locates it. Exposing it (below, CLANG_TABLEGEN_EXE
  # + LLVM_NATIVE_TOOL_DIR covering both files) is what makes CMake's
  # TableGen.cmake skip building clang-tblgen in-tree in the NATIVE
  # sub-project on riscv64 -- matching llvm-tblgen's existing prebuilt-tool
  # handling and preventing the same in-tree-NATIVE-build "incompatible with
  # elf64lriscv" failure mode for clang-tblgen that llvm-tblgen already avoids.
  CLANG_TBLGEN=$(_find_build_tool clang-tblgen)
  echo "  CLANG_TBLGEN resolved to: ${CLANG_TBLGEN:-<not found>}"

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
    CMAKE_CROSS_FLAGS+=(
      -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
      -DLLVM_TABLEGEN_EXE="${LLVM_TBLGEN}"
      -DLLVM_MIN_TABLEGEN_EXE="${LLVM_TBLGEN}"
    )
  fi
  [[ -n "${CLANG_TBLGEN}" ]] && CMAKE_CROSS_FLAGS+=(-DCLANG_TABLEGEN_EXE="${CLANG_TBLGEN}")

  # Pre-built tablegen tools from zig-llvm build dep (if available).
  if [[ -n "${LLVM_TBLGEN}" ]]; then
    _tblgen_dir=$(dirname "${LLVM_TBLGEN}")
    CMAKE_CROSS_FLAGS+=(-DLLVM_NATIVE_TOOL_DIR="${_tblgen_dir}")
    # clang-tblgen sanity check: zig_impl ships llvm-tblgen and clang-tblgen
    # side-by-side (both at lib/zig-llvm/bin/), so _tblgen_dir (derived from
    # LLVM_TBLGEN) already covers clang-tblgen too -- matching the incubator's
    # LLVM_NATIVE_TOOL_DIR, which also points at a single dir containing both
    # prebuilt tools (package-incubator _cross_compile.sh ~line 187-190). Warn
    # (don't fail) if CLANG_TBLGEN resolved to a different directory or wasn't
    # found, since TableGen.cmake's EXISTS check on LLVM_NATIVE_TOOL_DIR would
    # then not skip the in-tree NATIVE clang-tblgen build.
    if [[ -z "${CLANG_TBLGEN}" ]]; then
      echo "  WARN: clang-tblgen not found under ${BUILD_PREFIX} -- CMake will build it in-tree in the NATIVE sub-project (may hit the riscv64 libzstd ELF-mismatch failure)."
    elif [[ "$(dirname "${CLANG_TBLGEN}")" != "${_tblgen_dir}" ]]; then
      echo "  WARN: clang-tblgen dir ($(dirname "${CLANG_TBLGEN}")) != LLVM_NATIVE_TOOL_DIR (${_tblgen_dir}) -- TableGen.cmake's EXISTS check may still miss it."
    fi
    # zig_impl ships llvm-tblgen but NOT llvm-min-tblgen. Upstream
    # llvm/cmake/modules/TableGen.cmake resolves native tools via a LITERAL
    # filename EXISTS check (${LLVM_NATIVE_TOOL_DIR}/llvm-min-tblgen); when that
    # file is absent LLVM builds llvm-min-tblgen in-tree with the TARGET-arch
    # compiler, which then links the build-host x86_64 libzstd.so from
    # ${BUILD_PREFIX}/lib -> "incompatible with elf64lriscv" (bundled zstd on
    # riscv64/s390x makes that .so present in the search path). The full
    # llvm-tblgen is a strict superset of min-tblgen, so expose it under the
    # llvm-min-tblgen name to satisfy the EXISTS check and skip the in-tree build.
    _tblgen_base=$(basename "${LLVM_TBLGEN}")
    _min_tblgen="${_tblgen_dir}/${_tblgen_base/llvm-tblgen/llvm-min-tblgen}"
    if [[ ! -e "${_min_tblgen}" ]]; then
      if ln -sf "${_tblgen_base}" "${_min_tblgen}" 2>/dev/null; then
        echo "  linked ${_min_tblgen} -> ${_tblgen_base} (satisfy LLVM_NATIVE_TOOL_DIR min-tblgen lookup)"
      else
        echo "  WARN: could not create ${_min_tblgen} symlink (dir not writable?) -- min-tblgen may build in-tree"
      fi
    fi
  fi

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
    _native_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    _native_cxx_real="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
    # zig 0.15.2 has no `as` subcommand -- the dedicated `-zig-asm` wrapper
    # invokes `zig as`, which zig rejects (prints usage/help instead of
    # assembling). Route through the `-cc` wrapper instead, matching the
    # same documented workaround already used for ZIG_ASM in _zig_wrappers.sh
    # (clang's integrated assembler handles .S/.s files via `zig cc`).
    _native_asm="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"

    # zig-cxx reads ZIG_SHARED_LIBCXX_DIR at RUNTIME via its own internal
    # libcxx_shared.findSharedLibCxxString probe -- independent of any
    # CMAKE_CXX_STANDARD_LIBRARIES flag. That env var is exported globally
    # for the whole build (see the ppc64le export below, pointed at the
    # TARGET-arch libc++ in $PREFIX/lib/zig-llvm/lib), so the NATIVE
    # sub-project's own compiler-check inherits it too, causing an ELF arch
    # mismatch (confirmed: CMAKE_CXX_STANDARD_LIBRARIES had zero effect on
    # this link command). Wrap native zig-cxx to override
    # ZIG_SHARED_LIBCXX_DIR to the native static libc++ install (built by
    # _runtimes_build.sh's native pass) before exec'ing the real binary, so
    # only the NATIVE sub-project's own invocations see the corrected value.
    _native_cxx="${SRC_DIR}/native-cxx-wrapper.sh"
    cat > "${_native_cxx}" << WRAPPEREOF
#!/usr/bin/env bash
export ZIG_SHARED_LIBCXX_DIR="${SRC_DIR}/native-libcxx-install/lib"
exec "${_native_cxx_real}" "\$@"
WRAPPEREOF
    chmod +x "${_native_cxx}"
    # CMAKE_CXX_STANDARD_LIBRARIES: the parent build's CMAKE_PLATFORM_FLAGS
    # (see _cmake_flags.sh) points this at the TARGET-arch libc++ in
    # $PREFIX/lib/zig-llvm/lib, which NATIVE would otherwise inherit — an ELF
    # arch mismatch for the build-host linker. Point NATIVE at the static
    # build-arch libc++/libunwind built by _runtimes_build.sh's native pass
    # instead (installed to ${SRC_DIR}/native-libcxx-install).
    #
    # TWO-LAYER, BOTH IN-RECIPE (no subpackage split -- this feedstock is
    # single-recipe and stays that way):
    #   Layer 1 (primary, engages first): the prebuilt-tool wiring above
    #     (LLVM_TBLGEN/CLANG_TBLGEN found in BUILD_PREFIX + LLVM_NATIVE_TOOL_DIR
    #     + LLVM_TABLEGEN/CLANG_TABLEGEN_EXE cache vars). zig_impl_${build_platform}
    #     ships BOTH llvm-tblgen and clang-tblgen at lib/zig-llvm/bin/ as a hard
    #     package_contents contract (recipe.yaml ~line 405-406), so the find
    #     resolves on every platform we build for today. When both prebuilt
    #     native tools are present, CMake's TableGen.cmake EXISTS-checks
    #     LLVM_NATIVE_TOOL_DIR and skips building llvm-tblgen/llvm-min-tblgen/
    #     clang-tblgen in-tree entirely -- the NATIVE sub-project's own
    #     compiler target below never gets exercised for those tools, and
    #     riscv64's "incompatible with elf64lriscv" failure never occurs
    #     (nothing new compiles native-arch objects to trigger it).
    #   Layer 2 (this override, correctness net): CMAKE_C/CXX/ASM_COMPILER_TARGET
    #     pinned to the BUILD host triple. This is the fix that makes an
    #     in-tree NATIVE build CORRECT if Layer 1 ever doesn't apply (e.g. a
    #     future arch/variant whose zig_impl build dep doesn't ship one of the
    #     two prebuilt tools) -- it ensures that fallback in-tree build
    #     compiles/links as x86_64 host (host-compatible zstd, no ELF-arch
    #     mismatch) instead of leaking the TARGET triple in (observed:
    #     --target=riscv64-linux-gnu.2.39 on riscv64 cross builds, which then
    #     failed to link against $BUILD_PREFIX's x86_64 libzstd.so). Root cause
    #     of that leak: the glibc-floor block above (is_linux, ~line 29) sets
    #     -DCMAKE_{C,CXX,ASM}_COMPILER_TARGET=${ZIG_LLVM_TRIPLET} (the TARGET
    #     triple) into CMAKE_CROSS_FLAGS, passed as top-level cache variables
    #     to the single outer cmake invocation (_llvm_build.sh).
    #     CROSS_TOOLCHAIN_FLAGS_NATIVE did not previously override these vars
    #     for the NATIVE sub-build, so they leaked in (via inherited cache /
    #     CMake's crosscompiling-emulator toolchain propagation) and the
    #     zig-wrapper honored the explicit --target= on argv (it only injects
    #     its own compile-time ZIG_TARGET default when the caller supplies
    #     none). NATIVE tools run on the BUILD host, not the target, so pin
    #     them to ZIG_TARGET_BUILD (bare LLVM-format build-host triple, e.g.
    #     x86_64-linux-gnu; exported by recipe.yaml, canonical build-host
    #     triple source -- same value used as CONDA_ZIG_BUILD's zig target).
    #     LLVM_ENABLE_ZSTD=OFF is kept here too: even though a Layer-2
    #     in-tree build's zstd would now be host x86_64 (ABI-compatible with
    #     the host tool, per coordinator guidance -- no longer the arch
    #     mismatch that caused the original riscv64 failure), disabling zstd
    #     entirely for this throwaway NATIVE build avoids depending on
    #     runtime library compatibility at all; tblgen/clang-tblgen don't
    #     need zstd to function.
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_C_COMPILER_TARGET=${ZIG_TARGET_BUILD};-DCMAKE_CXX_COMPILER_TARGET=${ZIG_TARGET_BUILD};-DCMAKE_ASM_COMPILER_TARGET=${ZIG_TARGET_BUILD};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_CXX_STANDARD_LIBRARIES=-L${SRC_DIR}/native-libcxx-install/lib -lc++ -lunwind"
    )
  elif is_osx; then
    # macOS cross-builds: no is_osx branch existed here previously, so the
    # NATIVE sub-project (host-tblgen etc.) silently inherited the parent
    # CMAKE_C/CXX_COMPILER, which target the cross/TARGET arch (e.g. osx-64
    # from an osx-arm64 build host) instead of the BUILD arch tblgen must
    # actually run as. Mirror the Linux branch above.
    #
    # Unlike Linux, no global ZIG_SHARED_LIBCXX_DIR export exists for osx
    # during the LLVM-build phase (that export is scoped to the
    # powerpc64le-* block above, and zig_build.sh's own export runs in a
    # later, separate phase) — so the native-cxx-wrapper.sh indirection used
    # on Linux to override ZIG_SHARED_LIBCXX_DIR isn't needed here. Point
    # CMAKE_CXX_COMPILER directly at the real BUILD_PREFIX zig-cxx wrapper
    # and rely on CMAKE_CXX_STANDARD_LIBRARIES alone.
    _native_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
    _native_cxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
    _native_asm="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"

    # CMAKE_OSX_ARCHITECTURES for the NATIVE sub-project must be the BUILD
    # arch, not the TARGET arch. _cmake_flags.sh derives _osx_arch from
    # ${target_platform} for the main/target CMAKE_OSX_ARCHITECTURES flag
    # (default "arm64", "x86_64" when target_platform == "osx-64"). Mirror
    # that same derivation here but keyed off ${build_platform}, since
    # host-tblgen must run as the BUILD arch, not link/target as it.
    _native_osx_arch="arm64"
    [[ "${build_platform}" == "osx-64" ]] && _native_osx_arch="x86_64"

    # LIBCXXABI_USE_LLVM_UNWINDER=ON is set unconditionally for all platforms
    # in _runtimes_build.sh (not gated by is_linux), so LLVM's own libunwind
    # is built and used on macOS too. Include -lunwind here same as Linux.
    #
    # host-tblgen for the osx cross NATIVE sub-project is built with zig's
    # BUNDLED libc++ — exactly like the native/non-cross build (_llvm_build.sh
    # _CMAKE) and the linux cross NATIVE branch above — NOT the external
    # native-libcxx-install pulled in via -nostdinc++ -I.
    #
    # The earlier -nostdinc++ -I native-libcxx-install approach (2be9a012-style)
    # was the CAUSE of the failure, not a fix: it forced libc++'s <string.h>
    # wrapper mechanism, which then lost to the Xcode SDK usr/include that
    # FindBacktrace injects as a plain -I in <INCLUDES> — libc++'s <cstring>
    # found the SDK's raw <string.h> first and #error'd across ~190 TableGen
    # objects (builds 1551144/1551177/1551184; neither include_directories(BEFORE)
    # nor CMAKE_DISABLE_FIND_PACKAGE_Backtrace fixed it). host-tblgen is a
    # throwaway build-host tool with no target-ABI constraint, so match the
    # proven pattern: zig's bundled libc++ + only the static libc++ link libs.
    # Native osx-arm64 zig_impl builds ALL of LLVM (incl. tblgen) this way and
    # succeeds; linux-ppc64le builds native x86_64 tblgen this way and succeeds.
    # Null FindBacktrace's result for the NATIVE sub-build. LLVM's config-ix.cmake
    # calls find_package(Backtrace) UNCONDITIONALLY (NOT gated by
    # LLVM_ENABLE_BACKTRACES, which is already OFF yet Backtrace still resolves to
    # <Xcode>/MacOSX.sdk/usr/include and is emitted as a plain -I in <INCLUDES> —
    # confirmed in build 1551213 log lines 11240 / 12185). That raw -I beats zig's
    # bundled libc++ #include_next, so libc++ #error's "didn't find libc++'s
    # <stddef.h>". Pre-pinning Backtrace_INCLUDE_DIR empty in the cache makes
    # find_path skip and include_directories() add nothing; execinfo.h stays
    # reachable via -isysroot and host-tblgen never uses backtraces (ENABLE_BACKTRACES=OFF).
    # Different lever than the reverted CMAKE_DISABLE_FIND_PACKAGE_Backtrace / -nostdinc++ attempts.
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_cc};-DCMAKE_CXX_COMPILER=${_native_cxx};-DCMAKE_ASM_COMPILER=${_native_asm};-DCMAKE_OSX_ARCHITECTURES=${_native_osx_arch};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF;-DLLVM_ENABLE_ZLIB=OFF;-DBacktrace_INCLUDE_DIR=;-DBacktrace_INCLUDE_DIRS=;-DCMAKE_BUILD_RPATH=;-DCMAKE_INSTALL_RPATH=;-DCMAKE_CXX_STANDARD_LIBRARIES=-L${SRC_DIR}/native-libcxx-install/lib -lc++ -lunwind"
    )
  elif is_not_unix; then
    # Native host tools (llvm-min-tblgen.exe etc.) must run on the x86_64 win-64
    # build host, not the aarch64 target. CONDA_ZIG_BUILD resolves to the TARGET
    # triple (aarch64-w64-mingw32-zig), so we hard-code the build-host triple here.
    _native_host_triple="x86_64-w64-mingw32"
    _native_zig_target="x86_64-windows-gnu"   # zig target query for the NATIVE build (mingw32 OS token is rejected by zig)
    # BUILD_PREFIX can carry native Windows backslashes on conda-forge/rattler-build
    # CI (e.g. D:\bld\...\Library\bin). These host-tool paths feed the
    # -DCROSS_TOOLCHAIN_FLAGS_NATIVE string (line ~381), consumed by the NATIVE
    # sub-project's cmake. Normalize backslashes -> forward slashes for escape
    # safety, matching the _SRC_DIR normalization just below and the
    # CMAKE_RC_COMPILER fix in _llvm_build.sh (forward slashes are valid on Windows).
    _host_cc_exe="${BUILD_PREFIX//\\//}/Library/bin/${_native_host_triple}-zig-cc.exe"
    _host_cxx_exe="${BUILD_PREFIX//\\//}/Library/bin/${_native_host_triple}-zig-cxx.exe"
    _host_ar_bat="${BUILD_PREFIX//\\//}/Library/bin/${_native_host_triple}-zig-ar.exe"
    _host_ranlib_bat="${BUILD_PREFIX//\\//}/Library/bin/${_native_host_triple}-zig-ranlib.exe"

    # Write a CMake project-include file for the NATIVE sub-project.
    # This file patches the link rule templates after platform detection.
    #
    # Root cause: CMake's Windows-GNU.cmake sets CMAKE_GNULD_IMAGE_VERSION to
    #   "-Wl,--major-image-version,<TARGET_VERSION_MAJOR>,--minor-image-version,<TARGET_VERSION_MINOR>"
    # For executables without an explicit VERSION property, <TARGET_VERSION_MAJOR>
    # and <TARGET_VERSION_MINOR> evaluate to 0 (the CMake default). Zig cc converts
    # --major-image-version,0,--minor-image-version,0 to lld-link /version:0.0,
    # which zig's lld-link rejects with InvalidVersion.
    #
    # CMAKE_EXE_LINKER_FLAGS_INIT (tried in rounds 3-8) is appended to the link
    # command, but CMake's link rule template ALSO appends ${CMAKE_GNULD_IMAGE_VERSION}
    # AFTER <LINK_FLAGS>. Zig's lld-link uses the last --major-image-version, so the
    # 0,0 from the template wins over our 1,0 from LINKER_FLAGS_INIT.
    #
    # CMAKE_PROJECT_INCLUDE runs at the END of project() (after platform module sets
    # the link rule vars). We use string(REPLACE) to patch the 0-version generator
    # expressions with hardcoded 1,0 before CMake generates build.ninja.
    #
    # Use _SRC_DIR (forward-slash path from build.bat) to avoid CMake 4.2
    # backslash escape bug; fall back to bash-normalised SRC_DIR.
    _fwd_src_dir="${_SRC_DIR:-${SRC_DIR//\\//}}"
    # Native Windows cmake.exe needs D:/a/... (forward-slash drive form), not the /d/a/... MSYS form from _SRC_DIR.
    _native_project_include_fwd="${SRC_DIR//\\//}/_native_cmake_project_include.cmake"
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
    echo "  NATIVE cmake project include: ${_native_project_include_fwd}"

    # CMake compiler probe builds an exe by default, which on Windows injects
    # -Xlinker /version:0.0 — zig lld-link rejects bare 0.0 as InvalidVersion.
    # Build a static lib for the probe instead (no link, no /version: flag).
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_exe};-DCMAKE_CXX_COMPILER=${_host_cxx_exe};-DCMAKE_ASM_COMPILER=${_host_cc_exe};-DCMAKE_AR=${_host_ar_bat};-DCMAKE_RANLIB=${_host_ranlib_bat};-DCMAKE_C_COMPILER_TARGET=${_native_zig_target};-DCMAKE_CXX_COMPILER_TARGET=${_native_zig_target};-DCMAKE_ASM_COMPILER_TARGET=${_native_zig_target};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024;-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY;-DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_SHARED_LINKER_FLAGS_INIT=-Wl,--major-image-version,1,--minor-image-version,0;-DCMAKE_PROJECT_INCLUDE=${_native_project_include_fwd}"
    )
    echo "  HOST_CC: ${_host_cc_exe}"
    echo "  HOST_CXX: ${_host_cxx_exe}"
    unset _fwd_src_dir _native_project_include_fwd
  fi

  # NOTE: ZIG_LLVM_TRIPLET (3-component, "-unknown-"/"-w64-" stripped, glibc-floor
  # suffixed) is computed unconditionally above (outside this cross guard) and is
  # also used in the runtimes is_cross block in _runtimes_build.sh.

  # Cross-compilation only: tell cmake's ABI detection to trust the target
  # triple above instead of probing the wrapper by filename, which may infer
  # the build-host triple (x86_64) instead of the target triple (e.g.
  # aarch64), causing it to link test binaries as x86_64 against the
  # freshly-installed target-arch libc++ — producing an elf incompatibility
  # error ("libc++.so.1 is incompatible with elf_x86_64"). Native builds don't
  # need this override since build-host and target triple already match.
  if is_cross; then
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_C_ABI_COMPILED=TRUE
      -DCMAKE_CXX_ABI_COMPILED=TRUE
    )
  fi

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
  echo "  LLVM_NATIVE_TOOL_DIR: ${_tblgen_dir:-<not set>}"
fi

