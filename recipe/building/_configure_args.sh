# Declares and populates EXTRA_CMAKE_ARGS / EXTRA_ZIG_ARGS: baseline cpu/target flags,
# per-platform CMake tuning (osx/win/linux), RPATH embedding, and (linux+cross) the
# --libc / qemu resolve-and-shadow block that arms -fqemu.
# Requires: ZIG_TRIPLET, PREFIX, target_platform, cmake_build_dir, zig_build_dir,
#   CONDA_BUILD_SYSROOT (cross), QEMU_EXECVE (optional).

# --- Common CMake/zig configuration ---

EXTRA_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DZIG_TARGET_MCPU=baseline
  -DZIG_TARGET_TRIPLE=${ZIG_TRIPLET}
  -DZIG_USE_LLVM_CONFIG=ON
)

# Remember: CPU MUST be baseline, otherwise it create non-portable zig code (optimized for a given hardware)
EXTRA_ZIG_ARGS=(
  --search-prefix "${PREFIX}"
  -Dconfig_h="${cmake_build_dir}"/config.h
  -Dcpu=baseline
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Dstatic-llvm=false
  -Dstrip=true
  -Dtarget=${ZIG_TRIPLET}
  -Duse-zig-libcxx=false
)

# --- Platform Configuration ---

# Patch build.zig-02-doctest-forward-target adds -Ddoctest-target to build.zig.
# Gated to linux/osx where the patch applies and where doctest target forwarding matters.
if is_unix; then
  EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
fi

# Two-phase langref strategy: Phase 1 (here) ALWAYS skips langref HTML installation;
# Phase 2 (zig build langref) handles it separately when stage3 is runnable.
EXTRA_ZIG_ARGS+=(-Dno-langref)

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
  EXTRA_ZIG_ARGS+=(--maxrss 8589934592)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7800000000)
fi

# -fno-plt makes GCC emit inline-PLT relocations that LLD cannot handle
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  export CFLAGS="${CFLAGS:-} -fplt"
  export CXXFLAGS="${CXXFLAGS:-} -fplt"
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    # Force dynamic CRT (/MD) for zigcpp objects so their /DEFAULTLIB
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

# Embed PREFIX/lib RPATH at install time so binaries resolve libclang/libLLVM at runtime
if is_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
  # Resolve the qemu-user emulator ONCE, before anything consults it.
  #
  # Four spellings are in play and none is interchangeable:
  #   package  qemu-execve-<conda-arch>  e.g. qemu-execve-ppc64le
  #   binary   qemu-<conda-arch>         e.g. qemu-ppc64le
  #   zig      qemu-<llvm-arch>          e.g. qemu-powerpc64le  <- what -fqemu execs
  #   handle   $QEMU_EXECVE              absolute path, exported by the package
  #
  # Prefer $QEMU_EXECVE: a bare `command -v` can pick up the CI image's
  # /usr/bin/qemu-<arch>-static binfmt interpreter, which is unpinned and, before
  # qemu 11, SIGSEGVs on rseq under glibc >=2.35.  Exporting it also turns on
  # qemu's execve() redirect so child processes stay emulated.
  _zig_qemu=""
  if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
    _zig_qemu="${QEMU_EXECVE}"
  else
    _zig_qemu="$(command -v "qemu-${target_platform#linux-}" 2>/dev/null \
                 || command -v "qemu-${ZIG_QEMU_ARCH}" 2>/dev/null || true)"
  fi

  # zig hardcodes a qemu-<llvm-arch> PATH lookup for -fqemu, a different spelling
  # from the one the package installs.  Shadow it BEFORE -fqemu is decided just
  # below.  This used to happen only inside the Phase 2 langref block far below --
  # too late for -fqemu -- with an ad-hoc ppc64le-only BUILD_PREFIX symlink
  # papering over the gap.  Torn down by the existing _qemu_shadow_dir cleanup
  # after Phase 2.
  _qemu_shadow_dir=""
  if [ -n "${_zig_qemu}" ]; then
    export QEMU_EXECVE="${_zig_qemu}"
    # Emulated libc-linked binaries need the loader resolved against the TARGET
    # sysroot; unset, qemu uses the host root and they SIGSEGV.
    if [ -z "${QEMU_LD_PREFIX:-}" ] && [ -n "${CONDA_BUILD_SYSROOT:-}" ] && [ -d "${CONDA_BUILD_SYSROOT}" ]; then
      export QEMU_LD_PREFIX="${CONDA_BUILD_SYSROOT}"
    fi
    _qemu_shadow_dir="$(mktemp -d)"
    ln -sf "${_zig_qemu}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
    ln -sf "${_zig_qemu}" "${_qemu_shadow_dir}/qemu-${target_platform#linux-}"
    export PATH="${_qemu_shadow_dir}:${PATH}"
    dbg echo "qemu: ${_zig_qemu} (shadowed as qemu-${ZIG_QEMU_ARCH} and qemu-${target_platform#linux-})"
    EXTRA_ZIG_ARGS+=(-fqemu)
  else
    dbg echo "qemu: none found for ${ZIG_QEMU_ARCH}; -fqemu disabled"
  fi
fi
