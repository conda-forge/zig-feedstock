#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

source "${RECIPE_DIR}/building/_bash_check.sh"

# Local-only debug overrides — file is gitignored; create from recipe/local-scripts/debug-env.sh.example
if [[ -f "${RECIPE_DIR}/local-scripts/debug-env.sh" ]]; then
    source "${RECIPE_DIR}/local-scripts/debug-env.sh"
fi

# --- Functions ---

source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

build_platform="${build_platform:-${target_platform}}"

is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_osx() { [[ "${target_platform}" == "osx-"* ]]; }
is_unix() { [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; }
is_not_unix() { ! is_unix; }
is_cross() { [[ "${build_platform}" != "${target_platform}" ]]; }

dbg() { [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]] && "$@" || true; }

# --- Early exits ---

[[ -z "${CONDA_TRIPLET:-}" ]] && { echo "CONDA_TRIPLET must be specified in recipe.yaml env"; exit 1; }
[[ -z "${CONDA_ZIG_BUILD:-}" ]] && { echo "CONDA_ZIG_BUILD undefined, use zig_<arch> instead of _impl"; exit 1; }
[[ -z "${ZIG_TRIPLET:-}" ]] && { echo "ZIG_TRIPLET must be specified in recipe.yaml env"; exit 1; }

# zig 0.15+ requires macOS OS version as major.minor (e.g. "11.0" not bare "11").
# conda-forge c_stdlib_version may supply a bare major integer.
if is_osx; then
  _zig_os_ver="${ZIG_TRIPLET#*-macos.}"   # "11-none" or "10.13-none"
  _zig_os_ver="${_zig_os_ver%%-*}"         # "11"  or "10.13"
  if [[ "${_zig_os_ver}" != *.* ]]; then
    ZIG_TRIPLET="${ZIG_TRIPLET/-macos.${_zig_os_ver}-/-macos.${_zig_os_ver}.0-}"
    export ZIG_TRIPLET
  fi
fi
export ZIG_QEMU_ARCH="${ZIG_TRIPLET%%-*}"

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

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

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
# Args consumed only by cmake_fallback_build (patches 0004/0006/0007 apply there,
# not during the initial configure_cmake_zigcpp). Kept separate to avoid
# "Manually-specified variables were not used by the project" CMake warnings on
# the first configure pass.
EXTRA_CMAKE_ARGS_FALLBACK=()

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

# Tell the prefer-shared-libcxx patch where to find target-arch libc++.so.
# On cross-builds, zig_lib_dir points to the build host, so the patch's
# default probe finds wrong-arch libraries. This env var bypasses the
# arch guard and probes the target prefix directly.
#
# On macOS, conda places libcxx (a host: requirement, target-arch on cross)
# directly in ${PREFIX}/lib, NOT under a zig-llvm subdir. Pointing the env
# var here ensures the linker finds libc++.1.dylib at link time and emits a
# shared-library load command instead of falling through to static libcxx,
# which would otherwise collide at runtime with libLLVM/libclang-cpp's own
# libc++ (zig fires "LLVM and Clang have separate copies of libc++").
if is_osx; then
  export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib"
else
  export ZIG_SHARED_LIBCXX_DIR="${PREFIX}/lib/zig-llvm/lib"
fi

# Patch build.zig-doctest-forward-target adds -Ddoctest-target to build.zig.
# Applied universally; gated here to platforms that benefit from explicit
# target forwarding to zig2 self-hosted backend (avoids comptime f16->f32 bug).
if is_linux || is_osx; then
  EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
fi

# ppc64le: zig2.c is a ~11M-line auto-generated C TU. PowerPC direct branches
# are limited to 26-bit signed displacement (+/-32MB), and inter-function
# distances inside zig2.c exceed that range, producing GAS errors:
#   "Error: operand out of range (... is not between 0xfffffffffe000000 and 0x1fffffc)"
# -mlongcall makes GCC emit indirect calls via CTR for any-distance reach.
# Applies to both native and cross ppc64le builds (same generated source).
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  # -mlongcall: convert direct calls to indirect for our local code. Insufficient
  # alone since (a) partial-inline clones (.part.0/.constprop.0) plus -fno-plt
  # (conda-forge default) can still emit raw R_PPC64_REL24, (b) prebuilt
  # $PREFIX/lib/liblldELF.a (lld-20 package) was NOT built with -mlongcall, so
  # its global ctors call into std::vector helpers via REL24 -- and as LLVM/LLD 20
  # archives grew, the combined image exceeded REL24's +/-32MB reach.
  # -mcmodel=large: forces TOC-relative call sequences in our local code,
  # eliminating REL24 from zigcpp.a + zig2.c.o.
  # -Wl,--no-relax was REMOVED (build 22 -> 23): originally added believing it
  # preserved linker-inserted long-call stubs against prebuilt liblldELF.a, but
  # REL24 truncation persisted and got worse after the 2026-04-29/30 conda-forge
  # re-render bumped LLVM 20 archive sizes. --no-relax disables PPC64 TOC
  # optimization that the linker also uses to insert long-branch stubs; letting
  # default relaxation run allows ld.bfd to insert __longcall_* trampolines for
  # far calls into prebuilt liblldELF.a/libzigcpp.a global ctors.
  # Option B' only (B dropped: incompatible with PPC64 REL24).
  # B (DROPPED): -ffunction-sections -fdata-sections + -Wl,--gc-sections scatter
  #   intra-TU functions, defeating REL24 locality on PPC64 (+-32MB branch reach).
  # B': -fno-partial-inlining -fno-ipa-cp-clone prevents GCC from emitting
  #     .part.0/.constprop.0 cloned variants that bypass -mlongcall (the
  #     existing comment above explicitly flags this as a -mlongcall escape).
  export CFLAGS="${CFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export CXXFLAGS="${CXXFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  # REL24 mitigation: --stub-group-size=0 lets binutils auto-size stub groups
  # per section (replaces fixed 2MB; 0 = automatic, avoids "section .text exceeds
  # stub group size" when a single TU already exceeds 2MB).
  # REL24: route pthread_atfork through stub via --wrap to avoid R_PPC64_REL24
  # truncation from libpthread_nonshared.a(pthread_atfork.oS) in the sysroot.
  export LDFLAGS="${LDFLAGS:-} -Wl,--stub-group-size=0 -Wl,--wrap=pthread_atfork"
  export NINJA_FLAGS="-v"
  # Belt-and-suspenders: force CMAKE_{C,CXX,EXE_LINKER,SHARED_LINKER}_FLAGS via
  # the non-INIT command-line form (not _INIT). _INIT only seeds the cache on
  # the FIRST configure; cmake_fallback_build re-runs configure with the
  # patched CMakeLists.txt and the cached value can drift (env flags are not
  # re-read on re-configure once the cache is populated). Passing -D... on
  # every invocation forces the value, so flags reach both zigcpp's initial
  # compile/link AND any rebuild triggered by the patched re-configure.
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_FLAGS="${CFLAGS}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"
  )
  # Bundle paths: consumed only by patches 0006/0007 in cmake_fallback_build.
  # Kept out of EXTRA_CMAKE_ARGS to silence CMake "unused variable" warnings
  # on the initial configure_cmake_zigcpp pass (patches not yet applied there).
  EXTRA_CMAKE_ARGS_FALLBACK+=(
    -DZIG_LLD_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so"
    -DZIG_ZIGCPP_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so"
  )
fi

# osx cross with arch mismatch (e.g. osx-arm64 host -> osx-64 target):
# conda-forge target activation injects x86_64-only flags (-march=core2,
# -mtune=haswell, -mssse3) into CFLAGS/CXXFLAGS. CMake try_compile probes
# the BUILD-host compiler with `-arch arm64`, and the cross-clang wrapper
# x86_64-apple-darwin*-clang errors with "unsupported argument 'core2' to
# option '-march='". Stripping is safer than rewriting: zig's own target
# is set via -Dtarget=${ZIG_TRIPLET} and -Dcpu=baseline, so the dropped
# tuning flags are not load-bearing for the produced binary.
if is_osx && is_cross; then
  for _v in CFLAGS CXXFLAGS; do
    eval "_val=\${${_v}:-}"
    _val="$(echo "${_val}" \
      | sed -E 's/(^| )-march=[^ ]+//g; s/(^| )-mtune=[^ ]+//g; s/(^| )-mssse3//g; s/  +/ /g; s/^ +//; s/ +$//')"
    eval "export ${_v}=\"\${_val}\""
  done
  unset _v _val
fi

# Two-phase langref strategy: Phase 1 (here) ALWAYS skips langref because zig2
# is built with dev=core (no translate_c), and @cImport doctests panic with
# "development environment core does not support feature translate_c_command".
# Phase 2 below regenerates langref using the installed stage3 zig (dev=full).
EXTRA_ZIG_ARGS+=(-Dno-langref)
# cmake path: patch 0004-no-langref-optional makes upstream's hardcoded
# -Dno-langref opt-in via ZIG_NO_LANGREF; flip ON to match zig-with-zig path.
# Kept in EXTRA_CMAKE_ARGS_FALLBACK (not EXTRA_CMAKE_ARGS) so it is only
# passed to cmake_fallback_build's re-configure (after patch 0004 is applied),
# silencing "unused variable" warnings on the initial configure_cmake_zigcpp.
EXTRA_CMAKE_ARGS_FALLBACK+=(-DZIG_NO_LANGREF=ON)

if is_unix; then
  # zig binary links libclang-cpp.so.20.1 (linux) / libclang-cpp.20.1.dylib (osx)
  # at runtime; the cmake path does not use zig's native linker (which auto-embeds
  # DT_RUNPATH on linux or LC_RPATH on osx), so we must add the rpath explicitly --
  # otherwise the dynamic linker cannot locate the library at startup.
  # Windows PE/COFF has no rpath concept and is excluded from this block.
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
  # CMAKE_INSTALL_RPATH only affects zig2 itself (the cmake-built intermediate).
  # Stage3 (the final $PREFIX/bin/zig) is built by zig2 invoking `zig build install`,
  # so it doesn't inherit cmake's rpath.  Pass --search-prefix via the upstream
  # ZIG_EXTRA_BUILD_ARGS hook: cmake appends it to ZIG_BUILD_ARGS, and zig's
  # --search-prefix adds ${PREFIX}/lib as -L and embeds it as DT_RUNPATH (linux)
  # or LC_RPATH (osx), so the dynamic linker can find libclang-cpp at startup.
  # ZIG_EXTRA_BUILD_ARGS reaches upstream cmake's zig2 build invocation that
  # produces stage3. On osx we ALSO append --maxrss here because that upstream
  # invocation does NOT consume our EXTRA_ZIG_ARGS array (which only feeds our
  # own build_zig_with_zig path). osx-arm64 GHA runners auto-budget zig's
  # --maxrss to ~7 GiB; stage3 declares ~7.8 GB → `memory_blocked_steps`
  # assertion in build_runner.zig:679. Semicolon-separated form is the cmake
  # list syntax; cmake splits on ; and appends each token as a separate arg.
  if is_osx; then
    _zig_extra="--search-prefix;${PREFIX};--maxrss;8589934592"
  else
    _zig_extra="--search-prefix;${PREFIX}"
  fi
  # Wire --libc to the cmake path (ZIG_EXTRA_BUILD_ARGS); without this, zig2 under
  # qemu auto-augments the target triple with kernel-version range and fails libc resolution.
  if is_linux && is_cross; then
    _zig_extra="${_zig_extra};--libc;${zig_build_dir}/libc_file"
  fi
  EXTRA_CMAKE_ARGS+=(
    "-DZIG_EXTRA_BUILD_ARGS=${_zig_extra}"
  )
  unset _zig_extra
fi

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
  # Stage3 zig build declares ~7.8 GB upper bound; osx-arm64 GHA runners
  # auto-budget zig's --maxrss to ~7 GiB based on system RAM, which trips
  # `assert(memory_blocked_steps.items.len == 0)` in build_runner.zig.
  # Pin to 8 GiB. Same value also appended via ZIG_EXTRA_BUILD_ARGS above
  # for upstream cmake's zig2 build (different invocation path).
  EXTRA_ZIG_ARGS+=(--maxrss 8589934592)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
    # Force dynamic CRT (/MD) for zigcpp objects so their /DEFAULTLIB
    # directives emit ucrt.lib (dynamic), matching what bootstrap zig's
    # Lld.zig adds. Without this, cmake may compile with /MT (static)
    # producing /DEFAULTLIB:libucrt -- then lld-link sees both libucrt.lib
    # and ucrt.lib and fails with duplicate symbols.
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
  # qemu binary-name shim: ZIG_TRIPLET on ppc64le starts with the GCC arch
  # name "powerpc64le-...", so "${ZIG_TRIPLET%%-*}" = "powerpc64le". The
  # conda-forge package qemu-execve-ppc64le ships its binary as qemu-ppc64le,
  # so qemu-powerpc64le is missing from PATH and CROSSCOMPILING_EMULATOR
  # detection in _cmake.sh fails. Bridge the gap by symlinking into
  # BUILD_PREFIX/bin (always on PATH and writable in build env).
  # TODO: drop once qemu-execve-ppc64le ships qemu-powerpc64le upstream.
  if [[ "${target_platform}" == "linux-ppc64le" ]] \
     && ! command -v qemu-powerpc64le &>/dev/null \
     && command -v qemu-ppc64le &>/dev/null; then
    ln -sf "$(command -v qemu-ppc64le)" "${BUILD_PREFIX}/bin/qemu-powerpc64le"
  fi
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
  
  is_cross && rm "${PREFIX}"/bin/llvm-config && cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
fi

# CMAKE_BUILD=1 path: cmake's target_link_libraries(zig2 ...) gets
# LLVM_LIBRARIES from llvm-config which omits zstd/xml2/z. LLD's
# static archives (liblldELF.a etc.) reference ZSTD_createCCtx and
# friends, so the link fails (e.g. linux-aarch64). Append the libs
# to LLVM_LIBRARIES at the source — this mirrors the post-configure
# config.h perl edit (line below) that handles the zig-with-zig
# path. Insertion site (after find_package(Threads), ~line 187) is
# outside the 784-1015 region the existing cmake patches touch.
is_linux && perl -pi -e 's@(find_package\(Threads\))@$1\nlist(APPEND LLVM_LIBRARIES "-lzstd" "-lxml2" "-lz")@' "${cmake_source_dir}"/CMakeLists.txt

# osx cross: CMake's compiler detection probes the raw clang binary which
# resolves to the build (runner) arch — the conda cross-compiler on macOS is
# the same clang++ binary with -arch <target> in CXXFLAGS, but try_compile
# ignores those flags at probe time. CMake then writes CMAKE_OSX_ARCHITECTURES
# matching the host, and Phase A's configure_cmake_zigcpp builds host-arch
# objects into build-release/zigcpp/libzigcpp.a. Phase 3 stage3 (cross to
# target arch) then fails with "invalid cpu architecture: <host>" parsing
# libzigcpp.a. Fix: force the target arch via -DCMAKE_OSX_ARCHITECTURES so
# both Phase A and Phase 2 (cmake_fallback_build) build target-arch objects.
if is_osx && is_cross; then
  case "${target_platform}" in
    osx-64)     EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
    osx-arm64)  EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
  esac
fi

# Local-only additional patches (gitignored directory)
if [[ -n "${LOCAL_PATCHES_DIR:-}" && -d "${LOCAL_PATCHES_DIR}" ]]; then
    for _p in "${LOCAL_PATCHES_DIR}"/*.patch; do
        [[ -f "${_p}" ]] || continue
        echo "Applying local patch: $(basename "${_p}")"
        patch -p1 < "${_p}"
    done
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- ppc64le: build + install LLD and zigcpp bundles (path-independent) ---
# Must run AFTER configure_cmake_zigcpp (which produces build-release/zigcpp/libzigcpp.a)
# and BEFORE the build-path fork so both cmake_fallback_build and build_zig_with_zig
# paths ship the bundles in ${PREFIX}/lib.
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  dbg echo "=== ppc64le: build + install bundles (path-independent) ==="
  mkdir -p "${PREFIX}/lib"
  source "${RECIPE_DIR}/building/_lld_bundle.sh"
  dbg echo "=== ppc64le: build_lld_bundle_ppc64le ==="
  build_lld_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${PREFIX}/lib/" || exit 1
  source "${RECIPE_DIR}/building/_zigcpp_bundle.sh"
  dbg echo "=== ppc64le: build_zigcpp_bundle_ppc64le ==="
  build_zigcpp_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" "${cmake_build_dir}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so" "${PREFIX}/lib/" || exit 1
fi

# --- Post CMake Configuration ---
dbg echo "=== POST-CMAKE: starting post-cmake configuration ==="

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
dbg echo "=== POST-CMAKE: perl config.h edits ==="
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

dbg echo "=== DEBUG ===" && dbg cat "${cmake_build_dir}"/config.h && dbg echo "=== DEBUG ==="

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux && is_cross; then
  dbg echo "=== POST-CMAKE: linux cross-build setup ==="
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  dbg echo "=== POST-CMAKE: fix_sysroot_libc_scripts ==="
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  dbg echo "=== POST-CMAKE: create_zig_linux_libc_file ==="
  create_zig_linux_libc_file "${zig_build_dir}/libc_file"

  # pthread_atfork stub + --wrap mechanism is cmake-path-only. zig-build path
  # falls through to libpthread_nonshared.a's pthread_atfork (REL24 risk --
  # bundles will address that separately).
  if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
    perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
    dbg echo "=== POST-CMAKE: create_pthread_atfork_stub ==="
    create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  fi

  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  dbg echo "=== POST-CMAKE: create_libc_single_threaded_stub ==="
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  dbg echo "=== POST-CMAKE: cross-build setup DONE ==="
fi

# QEMU env for ppc64le cross-build execution.
# QEMU_LD_PREFIX lets qemu-user find the ppc64le dynamic linker (/lib64/ld64.so.2)
# and shared libraries from the cross sysroot. Without this, dynamically-linked
# binaries crash with SIGSEGV before reaching main() because the loader fails.
# Must be exported BEFORE any qemu invocation (zig build install can trigger
# qemu via binfmt when the freshly-cross-compiled zig binary is run).
# The cross gcc package installs its sysroot at ${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot.
if is_linux && is_cross; then
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot"

fi

dbg echo "=== ZIG BUILD: starting zig build ==="
dbg echo "=== ZIG BUILD: zig=${BUILD_ZIG} dir=${zig_build_dir} ==="
if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
  dbg echo "=== ZIG BUILD: CMAKE_BUILD=1, forcing cmake build (bypass zig-with-zig) ==="
  source "${RECIPE_DIR}/building/_cmake.sh"  # cmake_fallback_build
  cmake_fallback_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
elif build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  dbg echo "=== ZIG BUILD: SUCCESS ==="
elif [[ "${CMAKE_FALLBACK:-1}" == "1" ]]; then
  dbg echo "=== ZIG BUILD: FAILED, trying cmake fallback ==="
  source "${RECIPE_DIR}/building/_cmake.sh"  # cmake_fallback_build
  cmake_fallback_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
else
  echo "Build zig with zig failed and CMake fallback disabled"
  exit 1
fi


# Odd random occurence of zig.pdb
rm -f ${PREFIX}/bin/zig.pdb

# macOS: stage3 is built by zig2 invoking `zig build install`, which does not
# inherit cmake's CMAKE_INSTALL_RPATH.  --search-prefix adds a library search
# path at link time but does not embed LC_RPATH in the Mach-O binary.  Without
# an explicit rpath the dynamic linker cannot locate libclang-cpp.20.1.dylib at
# startup (e.g. when Phase 2 runs $PREFIX/bin/zig build langref).
if is_osx; then
  install_name_tool -add_rpath "${PREFIX}/lib" "${PREFIX}/bin/zig"
fi

# Linux: same problem on ELF. --search-prefix does not unconditionally embed
# DT_RUNPATH. Use a relative rpath ($ORIGIN/../lib) so the binary works under
# qemu user-mode emulation in cross builds (qemu rewrites absolute paths via
# QEMU_LD_PREFIX/sysroot, which would hide $PREFIX/lib; relative rpath is
# resolved by the dynamic linker from the binary's own location, bypassing
# qemu's path rewriting). Phase 2 langref needs to dlopen libclang-cpp.so.20.1
# from $PREFIX/lib via qemu-${arch}, so without this the cross build silently
# skips langref and the package_contents test fails on linux-aarch64.
if is_linux; then
  patchelf --set-rpath '$ORIGIN/../lib' "${PREFIX}/bin/zig"
fi


# --- Phase 2: build langref via stage3 (full compiler with translate_c) ---
# Phase 1 skipped langref (zig2 has dev=core, no translate_c). Now use the
# just-installed stage3/bin/zig (dev=full) to generate doc/langref.html.
# Gated on stage3 being executable: native always, linux-cross only if a
# qemu user-mode emulator for the target arch is available in PATH.
_can_run_stage3() {
  if ! is_cross; then return 0; fi
  if is_linux; then
    command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null && return 0
  fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (local dev override)" >&2
elif _can_run_stage3; then
  dbg echo "=== PHASE 2: building langref via stage3 zig ==="
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # Zig hardcodes qemu-<arch> lookup. The regular qemu-powerpc64le variant
  # (symlinked from qemu-ppc64le at build setup) doesn't redirect nested execve
  # calls -- but doctest panic/runtime-safety paths (dl_iterate_phdr, getcontext,
  # abort) require it. Shadow PATH with the execve variant for this step only;
  # QEMU_EXECVE is set by the qemu-execve-ppc64le activation script.
  _qemu_shadow_dir=""
  if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
    _qemu_shadow_dir=$(mktemp -d)
    ln -sf "${QEMU_EXECVE}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
    export PATH="${_qemu_shadow_dir}:${PATH}"
    dbg echo "PATH shadow: qemu-${ZIG_QEMU_ARCH} -> ${QEMU_EXECVE}"
  fi

  (
    cd "${cmake_source_dir}" &&
    "${_stage3_runner[@]+"${_stage3_runner[@]}"}" "${PREFIX}/bin/zig" build langref \
      --prefix "${PREFIX}" \
      -Dversion-string="${PKG_VERSION}" \
      -Ddoctest-target="${ZIG_TRIPLET}"
  ) || {
    if ! is_cross; then
      echo "ERROR: Phase 2 langref build failed (native build, expected to succeed)" >&2
      exit 1
    fi
    echo "WARNING: Phase 2 langref build failed (cross build, non-fatal)" >&2
  }

  if [ -n "${_qemu_shadow_dir:-}" ]; then
    rm -rf "${_qemu_shadow_dir}"
    unset _qemu_shadow_dir
  fi
else
  echo "INFO: Phase 2 langref skipped: stage3 not runnable on this host (cross without qemu/wine)" >&2
fi

dbg echo "=== POST-INSTALL: mv zig to ${CONDA_TRIPLET}-zig ==="
mv "${PREFIX}"/bin/zig "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig
dbg echo "=== POST-INSTALL: mv done ==="

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  dbg echo "Relocating to Library/ for non-unix conda convention"
  mkdir -p "${PREFIX}/Library/bin" "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
  mv "${PREFIX}"/bin/"${CONDA_TRIPLET}"-zig "${PREFIX}"/Library/bin/"${CONDA_TRIPLET}"-zig
  mv "${PREFIX}"/lib/zig "${PREFIX}"/Library/lib/zig
  [[ -d "${PREFIX}/doc" ]] && mv "${PREFIX}"/doc/* "${PREFIX}"/Library/doc/
fi

# MinGW import lib pre-generation (Windows targets only)
source "${RECIPE_DIR}/building/_mingw.sh"
generate_mingw_import_libs

dbg echo "=== Build installed for package: ${PKG_NAME} ==="

# ZIG_USE_CACHE trinary semantics (intentional):
#   unset / empty → no cache action (CI default)
#   "0"           → save current build artifacts into cache
#   "1"           → restore cached artifacts from prior run
#   any other     → no-op (filters garbage values silently)
# Cache successful build (saves before rattler-build cleanup)
if ([[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]) && [[ -f "${RECIPE_DIR}/local-scripts/stub_cache.sh" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  dbg echo "=== Build cached for future restoration ==="
fi

