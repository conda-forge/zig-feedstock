# Cross-compilation detection and setup
# CONDA_BUILD_CROSS_COMPILATION is set by conda-build when build_platform != target_platform
CMAKE_CROSS_FLAGS=()

# macOS NATIVE sub-project needs CMAKE_OSX_SYSROOT explicitly. Even on native
# builds (CONDA_BUILD_CROSS_COMPILATION=0), LLVM creates a NATIVE sub-project
# whose own CMake configure does NOT inherit CMAKE_OSX_SYSROOT from the outer
# build. Without this, NATIVE discovers Xcode's system SDK (e.g. MacOSX15.5)
# and injects -I<XCODE_SDK>/usr/include ahead of zig's libc++ headers, which
# breaks the libc++ header-ordering sentinel (cstddef/cstring/cmath errors).
# Inject CROSS_TOOLCHAIN_FLAGS_NATIVE early so it applies in BOTH native and
# cross macOS builds.
if is_osx && [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
  _native_macos_dt="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
  CMAKE_CROSS_FLAGS+=(
    -DCROSS_TOOLCHAIN_FLAGS_NATIVE="-DCMAKE_OSX_SYSROOT=${CONDA_BUILD_SYSROOT};-DCMAKE_OSX_DEPLOYMENT_TARGET=${_native_macos_dt}"
  )
  unset _native_macos_dt
  echo "  NATIVE macOS sub-project: CMAKE_OSX_SYSROOT=${CONDA_BUILD_SYSROOT}, DT=${MACOSX_DEPLOYMENT_TARGET:-11.0}"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  echo "=== Cross-compilation detected ==="
  echo "  Build platform: ${build_platform}"
  echo "  Target platform: ${target_platform}"

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

  # ppc64le: zig's self-hosted linker looks for `cc` in PATH to use as the
  # GCC linker driver, but needs the cross-GCC for ppc64le. Create a `cc`
  # symlink so zig finds the right linker. Also skip CMake's link test since
  # zig's self-hosted linker injects -m elf64lppc then chokes on it.
  # TODO: Remove once zig fixes self-hosted linker for ppc64le.
  if [[ "${LLVM_TRIPLET}" == powerpc64le-* ]]; then
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
    # ppc64le uses conda-forge target-arch libs from $PREFIX/lib plus the cross sysroot.
    # (The zig-zlib/zig-zstd/zig-libxml2 isolated layouts are riscv64-only and not
    # referenced for other cross targets.)
    _rpath_link="-Wl,-rpath-link,${PREFIX}/lib -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/usr/lib64 -Wl,-rpath-link,${BUILD_PREFIX}/powerpc64le-conda-linux-gnu/sysroot/lib64"
    CMAKE_CROSS_FLAGS+=(
      -DCMAKE_EXE_LINKER_FLAGS_INIT="${_rpath_link}"
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
_args+=(-rpath-link "${_ppc_sysroot_early}/usr/lib64" -rpath-link "${_ppc_sysroot_early}/usr/lib")
_is_shared=0
_has_libcxx=0
for _a in "\$@"; do
    [[ "\$_a" == "-shared" ]]    && _is_shared=1
    [[ "\$_a" == */libc++.a ]]   && _has_libcxx=1
    _args+=("\$_a")
done
if (( _is_shared )); then
    _args+=(-lpthread -ldl -lrt -lm)
fi
# Whenever zig's libc++.a is in the link (executable OR shared), it references
# typeinfo for std::length_error / std::runtime_error / std::logic_error which
# live in libstdc++.so on ppc64le Linux. Inject -lstdc++ from the sysroot.
if (( _has_libcxx )); then
    _args+=(-L"${_ppc_sysroot_early}/usr/lib64" -L"${_ppc_sysroot_early}/usr/lib" -lstdc++)
fi
exec "${_ppc_ld_bin}.real" "\${_args[@]}"
PPCLD
        chmod +x "${_ppc_ld_bin}"
        echo "  ppc64le: ld.bfd wrapped at ${_ppc_ld_bin} -> injects --sysroot + -lpthread -ldl for shared"
      fi
    fi
  fi


  # CROSS_TOOLCHAIN_FLAGS_NATIVE: tells LLVM's NATIVE sub-project which
  # compiler to use for building host tools (tablegen etc.).
  # Without this, NATIVE inherits CMAKE_C/CXX_COMPILER which target the
  # cross architecture (e.g. ppc64le), producing .o that can't link on
  # the build host (x86_64).
  if is_linux; then
    # Linux cross-builds: NATIVE sub-project needs the BUILD-host zig wrapper, not
    # the cross-target wrapper. ZIG_TARGET_BUILD uses zig-style triplets
    # (e.g. x86_64-linux-gnu) which do NOT match the conda-style wrapper names
    # (x86_64-conda-linux-gnu), so the old bare-form path always failed and fell
    # back to ZIG_CC — the cross-target (ppc64le) wrapper — breaking NATIVE builds.
    #
    # Build-host zig wrapper triplet. CONDA_ZIG_BUILD is defined by recipe.yaml's env:
    # block (build_triplet ~ "-zig" for native LLVM stage, xc_build_triplet ~ "-zig" for
    # cross-target LLVM stage outputs). Using it directly avoids the prior glob+head-1
    # fallback which could silently pick the wrong wrapper when only the cross-target
    # *-zig binary was present in $BUILD_PREFIX/bin/ (alphabetical 'r' < 'x' on riscv64
    # linked NATIVE host tools with the riscv64 wrapper, causing ELF ABI mismatches).
    if [[ -z "${CONDA_ZIG_BUILD:-}" ]]; then
      echo "ERROR: CONDA_ZIG_BUILD is undefined; recipe.yaml env: block must export it." >&2
      exit 1
    fi
    _native_zig_bin="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"
    _native_zig_triplet="${CONDA_ZIG_BUILD%-zig}"
    _native_zig_cc="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-cc"
    _native_zig_cxx="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-cxx"
    _native_zig_asm="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-asm"
    echo "DBG cross_compile linux: _native_zig_triplet=${_native_zig_triplet} (CONDA_TOOLCHAIN_HOST=${CONDA_TOOLCHAIN_HOST})"
    echo "  HOST_CC (linux): ${_native_zig_cc}"
    echo "  HOST_CXX (linux): ${_native_zig_cxx}"

    # NOTE: The host llvm-tblgen / clang-tblgen pre-build has been moved to
    # _llvm_build.sh (top, before the main cmake invocation).  It must run
    # AFTER _zig_wrappers.sh has installed the wrapper files — which happens
    # between _cross_compile.sh and _llvm_build.sh in the build.sh source order.
    # _host_tblgen_build / LLVM_TBLGEN / CLANG_TBLGEN are set there and
    # appended to CMAKE_CROSS_FLAGS before the main cmake call.

    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_native_zig_cc};-DCMAKE_CXX_COMPILER=${_native_zig_cxx};-DCMAKE_ASM_COMPILER=${_native_zig_asm};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF"
    )
  elif is_osx; then
    # osx cross-builds (osx-64 <-> osx-arm64): the bare-form ${ZIG_TARGET_BUILD}-zig-*
    # path does not exist because ZIG_TARGET_BUILD uses macos-style triplet
    # (x86_64-macos.<ver>) while the wrappers are installed under the darwin
    # conda triplet (x86_64-apple-darwin13.4.0).
    # _zig_wrappers.sh runs AFTER this block, so ${ZIG_CC} still points to the
    # TARGET wrapper from BUILD_PREFIX zig_impl's activate.d. Derive the BUILD-host
    # wrapper paths locally (same logic as _zig_wrappers.sh) to avoid the ordering
    # dependency. Cannot reorder sourcing — _cmake_flags.sh consumes CROSS_TOOLCHAIN_FLAGS_NATIVE.
    if [[ -z "${CONDA_ZIG_BUILD:-}" ]]; then
      echo "ERROR: CONDA_ZIG_BUILD is undefined; recipe.yaml env: block must export it." >&2
      exit 1
    fi
    _native_zig_triplet="${CONDA_ZIG_BUILD%-zig}"
    _native_zig_cc="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-cc"
    _native_zig_cxx="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-cxx"
    _native_zig_asm="${BUILD_PREFIX}/bin/${_native_zig_triplet}-zig-asm"
    echo "DBG cross_compile osx: _native_zig_triplet=${_native_zig_triplet} (CONDA_TOOLCHAIN_HOST=${CONDA_TOOLCHAIN_HOST})"
    echo "  HOST_CC (osx): ${_native_zig_cc}"
    echo "  HOST_CXX (osx): ${_native_zig_cxx}"

    # NOTE: The host llvm-tblgen / clang-tblgen pre-build has been moved to
    # _llvm_build.sh (top, before the main cmake invocation).  It must run
    # AFTER _zig_wrappers.sh has installed the wrapper files — which happens
    # between _cross_compile.sh and _llvm_build.sh in the build.sh source order.
    # _host_tblgen_build / LLVM_TBLGEN / CLANG_TBLGEN are set there and
    # appended to CMAKE_CROSS_FLAGS before the main cmake call.

    # Preserve CMAKE_OSX_SYSROOT in NATIVE sub-project. The early osx block at
    # L12-20 sets it but L32's CMAKE_CROSS_FLAGS=( array re-assignment discards
    # it. Without merging it here, NATIVE discovers Xcode's MacOSX15.5.sdk and
    # injects -I<xcode>/usr/include ahead of zig's libc++ shadow headers,
    # breaking the libc++ header-ordering sentinel (<cstring>, <cstddef>, ...).
    # LLVM_ENABLE_LIBCXX=OFF: zig c++ auto-injects its bundled libcxx headers
    # (lib/zig/libcxx/include) for every invocation. On macOS NATIVE sub-cmake
    # compiles (tablegen etc.), those headers conflict with the macOS SDK
    # <cstddef>, which cannot find its sibling <stddef.h>. Disabling libcxx
    # in the NATIVE sub-build avoids the include-path conflict entirely.
    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_OSX_SYSROOT=${CONDA_BUILD_SYSROOT};-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0};-DCMAKE_C_COMPILER=${_native_zig_cc};-DCMAKE_CXX_COMPILER=${_native_zig_cxx};-DCMAKE_ASM_COMPILER=${_native_zig_asm};-DCMAKE_PREFIX_PATH=${BUILD_PREFIX};-DCMAKE_FIND_ROOT_PATH=${BUILD_PREFIX};-DLLVM_ENABLE_ZSTD=OFF;-DLLVM_ENABLE_LIBCXX=OFF"
    )
  elif is_not_unix; then
    _host_cc_exe="${BUILD_PREFIX}/Library/bin/${ZIG_TARGET_BUILD}-zig-cc.exe"
    _host_cxx_exe="${BUILD_PREFIX}/Library/bin/${ZIG_TARGET_BUILD}-zig-cxx.exe"
    _host_ar_exe="${BUILD_PREFIX}/Library/bin/${ZIG_TARGET_BUILD}-zig-ar.exe"
    _host_ranlib_exe="${BUILD_PREFIX}/Library/bin/${ZIG_TARGET_BUILD}-zig-ranlib.exe"

    CMAKE_CROSS_FLAGS+=(
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${_host_cc_exe};-DCMAKE_CXX_COMPILER=${_host_cxx_exe};-DCMAKE_AR=${_host_ar_exe};-DCMAKE_RANLIB=${_host_ranlib_exe};-DLLVM_ENABLE_ZSTD=OFF;-DCMAKE_OBJECT_PATH_MAX=1024"
    )
    echo "  HOST_CC: ${_host_cc_exe}"
    echo "  HOST_CXX: ${_host_cxx_exe}"
  fi

  # NOTE: Tablegen bypass flags (LLVM_TABLEGEN, CLANG_TABLEGEN_EXE, LLVM_NATIVE_TOOL_DIR)
  # are set in _llvm_build.sh AFTER the host pre-build runs (which requires wrappers
  # installed by _zig_wrappers.sh).  They are appended to CMAKE_CROSS_FLAGS there,
  # immediately before the main cmake invocation.

  # Zig parses compiler target queries in 3-component format (<arch>-<os>-<abi>);
  # clang's 4-component LLVM triple (e.g. aarch64-unknown-linux-gnu) makes zig
  # treat "unknown" as the OS and fail with UnknownOperatingSystem.
  # Strip the "-unknown-" middle component to get the zig-compatible triple.
  # NOTE: ZIG_LLVM_TRIPLET is also used in the runtimes is_cross block below.
  ZIG_LLVM_TRIPLET="${LLVM_TRIPLET/-unknown-/-}"
  ZIG_LLVM_TRIPLET="${ZIG_LLVM_TRIPLET/-w64-/-}"
  # Normalize apple-darwin → macos (zig requires macos, not darwin)
  if [[ "${ZIG_LLVM_TRIPLET}" == *-apple-darwin* ]]; then
    _zig_osver="${ZIG_LLVM_TRIPLET##*-apple-darwin}"
    _zig_target_arch="${ZIG_LLVM_TRIPLET%%-apple-darwin*}"
    [[ "${_zig_target_arch}" == "arm64" ]] && _zig_target_arch="aarch64"
    ZIG_LLVM_TRIPLET="${_zig_target_arch}-macos${_zig_osver:+.${_zig_osver}}-none"
    unset _zig_osver _zig_target_arch
  fi

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

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  (tablegen bypass flags set in _llvm_build.sh after host pre-build)"
fi

