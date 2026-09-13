#!/usr/bin/env bash

set -euo pipefail
# brush 0.4.0 (#1245): xtrace clobbers $?, breaking set -e. Keep it off.
set +x
IFS=$'\n\t'

export build_platform="${build_platform:-${target_platform}}"

source "${RECIPE_DIR}/building/_bash_check.sh"
source "${RECIPE_DIR}/building/_tool_check.sh"

# --- Functions ---

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_zig_diag.sh"
source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

export ZIG_QEMU_ARCH="${ZIG_TRIPLET%%-*}"

if [[ "${PKG_NAME:-}" != "zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: >${PKG_NAME:-}< - Verify recipe.yaml script:"
  exit 1
fi

# === Build caching for quick recipe iteration ===
# Set ZIG_USE_CACHE=1 to enable build caching:
#   - First run: builds normally, caches result
#   - Subsequent runs: restores from cache, skips build
if [[ "${ZIG_USE_CACHE:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  if stub_cache_restore; then
    echo "=== Build restored from cache (skipping compilation) ==="
    exit 0
  fi
  echo "=== No cache found - will build and cache result ==="
  # Continue with normal build, cache will be saved at the end
fi

# --- Main ---

# Bootstrap selection (build_number == 0 only: no-op otherwise)
source "${RECIPE_DIR}/building/_upstream_bootstrap.sh"
setup_upstream_zig_bootstrap

# Bootstrap zig: upstream-bootstrap path if set, else CONDA_ZIG_BUILD
BUILD_ZIG="${ZIG_BOOTSTRAP_EXE:-${CONDA_ZIG_BUILD}}"

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR_OVERRIDE:-${SRC_DIR}/zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${PREFIX}"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"

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

# -fno-plt makes GCC emit inline-PLT relocations LLD cannot handle
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  export CFLAGS="${CFLAGS:-} -fplt"
  export CXXFLAGS="${CXXFLAGS:-} -fplt"
fi

# --- ppc64le R_PPC64_REL24 mitigation (defense in depth) ---
# Two mechanisms: -mlongcall via the CFLAGS/CXXFLAGS below, and the
# libzig-lld-bundle.so split (cmake patch 0006 + _lld_bundle.sh) that spreads
# the 24-bit branch relocation domain across separate PLT sections.
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  export CFLAGS="${CFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export CXXFLAGS="${CXXFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export LDFLAGS="${LDFLAGS:-} -Wl,--stub-group-size=0"
  export NINJA_FLAGS="-v"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_FLAGS="${CFLAGS}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"
  )
  # Use PREFIX/lib here (not ZIG_LOCAL_CACHE_DIR): these paths are baked into
  # the zig binary's DT_NEEDED at link time. conda-build's patchelf/prefix
  # replacement then rewrites PREFIX to the install location correctly.
  # The lld bundle is installed to PREFIX/lib/ (before zig2 link).
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLD_BUNDLE_SO="${PREFIX}/lib/libzig-lld-bundle.so"
  )
  EXTRA_ZIG_ARGS+=(--verbose-link)
  mkdir -p "${PREFIX}/bin"
  # Build-time only gcc-lookup lever; stripped before packaging (see below).
  ln -sf "${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-gcc" "${PREFIX}/bin/powerpc64le-conda-linux-gnu-gcc"
  ln -sf "${BUILD_PREFIX}/bin/powerpc64le-conda-linux-gnu-ld" "${PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
fi

# Strip host-arch flags injected by conda-build for cross builds.
# Safe for ppc64le/aarch64: intentional target-arch flags (e.g. -mlongcall,
# -march=armv8-a) are added in target-specific blocks elsewhere and don't
# match the sanitize filter for their own arch family.
if is_cross; then
  sanitize_and_export_cross_flags
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
  : # brush 0.4.0 $? guard
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  # --maxrss + the build.zig max_rss patch are linux-only.  Adding
  # them to osx (commit 22a8ddb) capped zig's build-graph scheduler
  # at 7 GB → forced more serial task execution → osx_64 native
  # build wall time grew from ~32 min (historical successes) to
  # ~58 min, tipping Azure's macOS-15 agents into abandonment.
  # Reverted to the no-cap default for osx; the heavy link step
  # uses < 7 GB in practice on osx-arm64 native builds (proven by
  # repeated successes), and lets zig parallelize across cores.
  EXTRA_ZIG_ARGS+=(--maxrss 8000000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    # Force dynamic CRT (/MD) for zigcpp objects so their /DEFAULTLIB
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  )
else
  : # brush 0.4.0 $? guard
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

# Embed PREFIX/lib RPATH at install time so binaries resolve libclang/libLLVM at runtime
if is_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
fi

# bare qemu-<arch> already exists on PATH (regular variant); this shadow
# makes zig's internal -fqemu lookup resolve to the execve variant instead.
_qemu_shadow_dir=""
if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
  _qemu_shadow_dir=$(mktemp -d)
  ln -sf "${QEMU_EXECVE}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
  export PATH="${_qemu_shadow_dir}:${PATH}"
  dbg echo "PATH shadow: qemu-${ZIG_QEMU_ARCH} -> ${QEMU_EXECVE}"
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
  # Enable qemu if qemu-execve-<arch> package is installed (conda-forge).
  # Provides qemu-<arch> in PATH which is what zig's -fqemu expects.
  if command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null; then
    EXTRA_ZIG_ARGS+=(-fqemu)
  fi
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib

  if is_cross; then
    rm "${PREFIX}"/bin/llvm-config
    cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
  fi
fi

if is_osx && is_cross; then
  case "${target_platform}" in
    osx-64)     EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
    osx-arm64)  EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
  esac
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- ppc64le bundle .so build (after cmake configure, before zig2 link) ---
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  mkdir -p "${PREFIX}/lib"
  source "${RECIPE_DIR}/building/_lld_bundle.sh"
  build_lld_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${PREFIX}/lib/" || exit 1
fi

# --- Post CMake Configuration ---

# Append zlib/zstd/libxml2 to config.h's ZIG_LLVM_LIBRARIES: conda's split
# packaging doesn't bake them in. Needed on every linux build.
is_linux && _cfg_subst "${cmake_build_dir}/config.h" '(ZIG_LLVM_LIBRARIES ".*)"' '\1;-lzstd;-lxml2;-lz"'
# Cross builds resolve LLVM on the build machine, so config.h's ZIG_LLVM_* paths
# point into ${BUILD_PREFIX} -- the wrong architecture. Windows needs the literal
# form: CMake writes native paths (C:/... or C:\...), ${BUILD_PREFIX} is MSYS (/c/...).
is_osx      && is_cross && _cfg_subst     "${cmake_build_dir}/config.h" "(ZIG_LLVM_\\w+ \")${BUILD_PREFIX}" "\\1${PREFIX}"
is_not_unix && is_cross && _cfg_subst_lit "${cmake_build_dir}/config.h" "${BUILD_PREFIX}" "${PREFIX}"
# Do NOT inject ${PREFIX}/lib/libc++.dylib into ZIG_LLVM_LIBRARIES on macOS:
# duplicate LC_LOAD_DYLIB, dyld aborts on SDK >= 26. See reference doc S8.

# zig2.c (the pre-generated C bootstrap from 0.16) calls getrandom,
# copy_file_range, and statx — all absent from conda-forge's glibc 2.17
# sysroot. Compile weak-symbol syscall() stubs and inject the .o into
# both the zig-build path (via config.h's ZIG_LLVM_LIBRARIES) and the
# CMake fallback path (via cmake/0002 target_link_libraries).
# Guard on CONDA_BUILD_SYSROOT: outside conda-forge CI (e.g. local
# dev with a modern glibc system), the stubs aren't needed.
if is_linux && [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
  source "${RECIPE_DIR}/building/_glibc217_syscall_stubs.sh"
  create_glibc217_syscall_stubs "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  _cfg_subst "${cmake_build_dir}/config.h" '(#define ZIG_LLVM_LIBRARIES ".*)"' "\\1;${ZIG_LOCAL_CACHE_DIR}/glibc217_syscall_stubs.o\"" g
fi

dbg grep -E '^#define (ZIG_|LLVM_)' "${cmake_build_dir}"/config.h

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  # Fix sysroot libc.so linker scripts 2.17 to use relative paths
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  for _sysroot_probe in usr/lib lib64 lib64/lp64d; do
    ls -ld "${CONDA_BUILD_SYSROOT:-/nonexistent}/${_sysroot_probe}" 2>&1 | sed 's/^/[sysroot-layout] /' || true
  done

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  _cfg_subst "${cmake_build_dir}/config.h" '(#define ZIG_LLVM_LIBRARIES ".*)"' "\\1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"" g
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  _cfg_subst "${cmake_build_dir}/config.h" '(#define ZIG_LLVM_LIBRARIES ".*)"' "\\1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"" g
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
fi


# --- Two-stage bootstrap for linux-ppc64le with upstream bootstrap ---
#
# When bootstrap_via_upstream=true (proxied by zig-bootstrap/ dir presence),
# the upstream linux-64 zig bootstrap binary lacks our ppc64le LdScript support
# and DWARF64 eh_frame skip patches.  Those missing patches cause panics during
# the ppc64le cross-compile of zig itself.
#
# Fix: build a native linux-64 zig from our PATCHED source first (Stage 1),
# using the upstream bootstrap which works fine for x86_64-linux-gnu.  Then
# use THAT patched-native zig as the bootstrap for the ppc64le cross-compile
# (Stage 2).
#
# Detection: target_platform==linux-ppc64le + is_cross + zig-bootstrap/ present.
if [[ "${target_platform}" == "linux-ppc64le" ]] && is_cross && \
   [[ -d "${SRC_DIR}/zig-bootstrap" ]]; then
  echo "[build.sh] linux-ppc64le + upstream bootstrap detected — engaging two-stage bootstrap"
  # build_native_zig_bootstrap needs create_glibc217_syscall_stubs; source it if
  # not already sourced (it's normally sourced later in build.sh only when needed).
  source "${RECIPE_DIR}/building/_glibc217_syscall_stubs.sh"
  export LLVM_VERSION="${LLVM_VERSION:-22}"
  build_native_zig_bootstrap
  BUILD_ZIG="${ZIG_TWO_STAGE_BOOTSTRAP_ZIG}"
  echo "[build.sh] linux-ppc64le: two-stage bootstrap engaged — Stage 1 native build complete, using patched native zig as bootstrap: ${BUILD_ZIG}"
fi

zig_diag_fingerprint
if zig_diag_exec phase1-zig-build -- build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  dbg echo "=== ZIG BUILD: SUCCESS ==="
else
  echo "ERROR: zig-build failed." >&2
  exit 1
fi


# Odd random occurence of zig.pdb
rm -f "${PREFIX}/bin/zig.pdb"

# macOS: --search-prefix adds a library search but does not embed LC_RPATH in the Mach-O binary.
if is_osx; then
  install_name_tool -add_rpath "${PREFIX}/lib" "${PREFIX}/bin/zig"
fi

if is_linux; then
  patchelf --set-rpath '$ORIGIN/../lib' "${PREFIX}/bin/zig"
fi

# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if is_linux; then
    [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ] && return 0
  fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (local dev override)" >&2
elif [[ "${target_platform}" != "linux-ppc64le" ]]; then
  echo "INFO: Phase 2 langref skipped: temporarily ppc64le-only while validating the PT_PHDR fix" >&2
elif _can_run_stage3; then
  dbg echo "=== PHASE 2: building langref via stage3 zig ==="
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("${QEMU_EXECVE}")
  fi

  # Passthrough lets the emulated stage3 exec the build-arch cross-gcc natively (opt-in, off by default).
  # rc is captured rather than handled inline so the END span prints before any exit.
  zig_diag_span "BEGIN phase2-langref"
  _langref_start=${SECONDS}
  _langref_rc=0
  (
    cd "${cmake_source_dir}" &&
    env QEMU_EXECVE_NATIVE_PASSTHROUGH=1 "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      -Ddoctest-target="${ZIG_TRIPLET}"
  ) || _langref_rc=$?
  zig_diag_span "END phase2-langref: rc=${_langref_rc} elapsed=$((SECONDS - _langref_start))s"
  if [[ ${_langref_rc} -ne 0 ]]; then
    if ! is_cross; then
      echo "ERROR: Phase 2 langref build failed (native build, expected to succeed)" >&2
      exit 1
    fi
    echo "WARNING: Phase 2 langref build failed (cross build, non-fatal)" >&2
  fi
else
  echo "INFO: Phase 2 langref skipped: cross build with no usable stage3 runner (need qemu on linux, wine on windows)" >&2
fi

dbg echo "Post-install implementation package: ${PKG_NAME}"
# Name Windows executables explicitly: MSYS's implicit .exe handling is not
# reliable for an ARM64 PE produced by an x64 cross-build.
_zig_exe_suffix=""
is_not_unix && _zig_exe_suffix=".exe"
mv "${PREFIX}/bin/zig${_zig_exe_suffix}" "${PREFIX}/bin/${CONDA_TRIPLET}-zig${_zig_exe_suffix}"

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  dbg echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}/bin/${CONDA_TRIPLET}-zig.exe" "${PREFIX}/Library/bin/${CONDA_TRIPLET}-zig.exe"
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  if [[ -d "${PREFIX}/doc" ]]; then
    _doc_entries=("${PREFIX}"/doc/*)
    if [[ -e "${_doc_entries[0]}" ]]; then
      mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
    fi
  fi
fi

source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

# Build-time only gcc-lookup lever; must not ship.
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  rm -f "${PREFIX}/bin/powerpc64le-conda-linux-gnu-gcc"
  rm -f "${PREFIX}/bin/powerpc64le-conda-linux-gnu-ld"
fi

dbg echo "=== Build installed for package: ${PKG_NAME} ==="

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  dbg echo "=== Build cached for future restoration ==="
fi
