#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# --- Functions ---

source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

is_debug() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; }

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

if [[ "${PKG_NAME:-}" != "zig_impl_"* ]]; then
  echo "ERROR: Unknown package name: ${PKG_NAME} - Verify recipe.yaml script:"
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

# Bootstrap selection (build_number == 0 only): use upstream
# ziglang.org binary as bootstrap when this is the first build of a
# new zig release. Subsequent builds use conda-forge's published
# zig_impl_${build_platform} which can parse the matching build.zig
# directly. recipe.yaml gates the source-entry download on
# build_number == 0; this helper is a no-op when zig-bootstrap/
# wasn't extracted.
source "${RECIPE_DIR}/building/_upstream_bootstrap.sh"
setup_upstream_zig_bootstrap

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
# Point the cmake install prefix directly at ${PREFIX}. Zig's upstream
# cmake/install.cmake bakes the configure-time CMAKE_INSTALL_PREFIX into
# the install script (it invokes `zig build --prefix ${CMAKE_INSTALL_PREFIX}`
# via install(CODE ...)), so `cmake --install . --prefix X` at install time
# is silently ignored. Using ${PREFIX} here ensures the CMake fallback path
# lands files where the rest of build.sh expects them.
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

# Cross-compile stage1 host-tool split: zig-wasm2c / zig1 are
# build-host tools; when CC ≠ CC_FOR_BUILD CMAKE_C_COMPILER produces
# binaries that can't run on the build host.  ZIG_STAGE1_HOST_CC
# routes those targets through the build-host compiler (via add_
# custom_command in patches/cmake/0003-cmake-stage1-host-cc-...),
# leaving zig2 / compiler_rt / zigcpp on CMAKE_C_COMPILER.
#
# Applied on every cross variant (osx + linux-cross).  For linux-cross
# this replaces the qemu emulator path that used to wrap zig-wasm2c /
# zig1 invocations in 0003-cross-CMakeLists.txt.patch.
if [[ -n "${CC_FOR_BUILD:-}" && "${CC_FOR_BUILD:-}" != "${CC:-}" ]]; then
  EXTRA_CMAKE_ARGS+=(-DZIG_STAGE1_HOST_CC="${CC_FOR_BUILD}")
fi

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

# Patch 0007 adds -Ddoctest-target to build.zig (Linux only)
is_linux && EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
# ppc64le cross: skip docgen — qemu-ppc64le doesn't faithfully emulate traps,
# and the ppc64le GCC linker has __tls_get_addr DSO ordering issues with doctests
[[ "${target_platform}" == "linux-ppc64le" ]] && is_cross && EXTRA_ZIG_ARGS+=(-Dno-langref)

# Strip host-arch flags injected by conda-build for cross builds.
# Safe for ppc64le/aarch64: intentional target-arch flags (e.g. -mlongcall,
# -march=armv8-a) are added in target-specific blocks elsewhere and don't
# match the sanitize filter for their own arch family.
if is_cross; then
  sanitize_and_export_cross_flags
fi

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
  # macOS-15-arm64 GitHub Actions runners ship with ~7 GB RAM; zig's
  # ReleaseSafe link step declares an 8 GB upper bound and refuses to
  # schedule itself unless explicitly allowed.  Pass --maxrss 8 GB so
  # zig will run the step (overflow into swap is fine on a clean
  # runner).  Do *not* set this on macOS-15 x86_64 (Azure) — those
  # agents have plenty of RAM and capping the scheduler caused
  # serialization slowdowns previously (see the linux comment below).
  if [[ "${build_platform}" == "osx-arm64" ]]; then
    EXTRA_ZIG_ARGS+=(--maxrss 8000000000)
    if [[ "${target_platform}" == "osx-64" ]]; then
      EXTRA_CMAKE_ARGS+=(
        -DCMAKE_OSX_ARCHITECTURES=x86_64
      )
    fi
  fi
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  # --maxrss + the build.zig max_rss patch are linux-only.  Adding
  # them to osx (commit 22a8ddb) capped zig's build-graph scheduler
  # at 7 GB → forced more serial task execution → osx_64 native
  # build wall time grew from ~32 min (historical successes) to
  # ~58 min, tipping Azure's macOS-15 agents into abandonment.
  # Reverted to the no-cap default for osx; the heavy link step
  # uses < 7 GB in practice on osx-arm64 native builds (proven by
  # repeated successes), and lets zig parallelize across cores.
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    # Bootstrap libucrt/ucrt confilct may come from /DEFAULTLIB:libucrt (hopefully not from LLVM)
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SHARED_LLVM=ON)
fi

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
  # Enable qemu only if zig-qemu package is installed (provides qemu-<arch>
  # binaries that zig expects). conda's qemu-user-<arch> uses different names.
  if [[ -d "${PREFIX}/lib/zig-qemu" ]]; then
    export PATH="${PREFIX}/lib/zig-qemu:${PATH}"
    EXTRA_ZIG_ARGS+=(-fqemu)
  fi
fi

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib

  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- Post CMake Configuration ---

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
# Append LLVM deps that conda's split packaging doesn't bake into
# config.h's ZIG_LLVM_LIBRARIES: zlib (adler32 refs in lld-ELF),
# zstd (compression), libxml2. Needed on every native + cross linux
# build — linux-aarch64 failed linking zig2 with undefined adler32
# when this was gated on `is_cross`.
is_linux && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

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
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/glibc217_syscall_stubs.o\"|g" "${cmake_build_dir}/config.h"
fi

is_debug && echo "=== DEBUG ===" && cat "${cmake_build_dir}"/config.h && echo "=== DEBUG ==="

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux && is_cross; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  # Fix sysroot libc.so linker scripts 2.17 to use relative paths
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
fi

# Optional: build native zig from source when conda bootstrap can't compile new version.
# Set BUILD_NATIVE_ZIG=1 to enable. Not needed since build 12 (ld script patch in package).
if is_linux && [[ "${BUILD_NATIVE_ZIG:-0}" == "1" ]]; then
  build_native_zig "${SRC_DIR}/native-zig-install"
fi


is_debug && echo "=== Building with ZIG ===" || true
if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  # NB: `|| true` — in non-debug is_debug returns 1 and that becomes the
  # branch's last-executed exit status, which trips `set -e` in build.sh.
  is_debug && echo "SUCCESS: zig build completed successfully" || true
elif [[ "${CMAKE_FALLBACK:-1}" == "1" ]]; then
  source "${RECIPE_DIR}/building/_cmake.sh"  # cmake_fallback_build
  cmake_fallback_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
else
  echo "Build zig with zig failed and CMake fallback disabled"
  exit 1
fi


# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

is_debug && echo "Post-install implementation package: ${PKG_NAME}"
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  is_debug && echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

is_debug && echo "=== Build installed for package: ${PKG_NAME} ==="

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  is_debug && echo "=== Build cached for future restoration ==="
fi
