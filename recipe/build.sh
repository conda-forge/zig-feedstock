#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

source "${RECIPE_DIR}/building/_bash_check.sh"

# Local-only debug overrides — file is gitignored; create from recipe/local-scripts/debug-env.sh.example
if [[ -f "${RECIPE_DIR}/local-scripts/debug-env.sh" ]]; then
    source "${RECIPE_DIR}/local-scripts/debug-env.sh"
fi

build_platform="${build_platform:-${target_platform}}"

# --- Functions ---

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

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
  export CFLAGS="${CFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  export CXXFLAGS="${CXXFLAGS:-} -mlongcall -mcmodel=large -fno-partial-inlining -fno-ipa-cp-clone"
  # REL24 mitigation: --stub-group-size=0 lets binutils auto-size stub groups
  export LDFLAGS="${LDFLAGS:-} -Wl,--stub-group-size=0 -Wl,--wrap=pthread_atfork"
  export NINJA_FLAGS="-v"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_C_FLAGS="${CFLAGS}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"
  )
  EXTRA_CMAKE_ARGS+=(
    -DZIG_LLD_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so"
    -DZIG_ZIGCPP_BUNDLE_SO="${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so"
  )
fi

# Strip host-arch flags injected by conda-build for all cross targets.
# Safe for ppc64le: intentional -mlongcall etc. are target-arch flags
# (set in the ppc64le block above) and don't match the _drop_ppc filter.
if is_cross; then
  sanitize_and_export_cross_flags
fi

# Two-phase langref strategy: Phase 1 (here) ALWAYS skips langref
EXTRA_ZIG_ARGS+=(-Dno-langref)
EXTRA_CMAKE_ARGS+=(-DZIG_NO_LANGREF=ON)

if is_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  )
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
  EXTRA_ZIG_ARGS+=(--maxrss 8589934592)
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
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

if is_linux && is_cross; then
  EXTRA_ZIG_ARGS+=(
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes "${CONDA_BUILD_SYSROOT}"/lib64
  )
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

# LLVM_LIBRARIES from llvm-config which omits zstd/xml2/z. LLD's
is_linux && perl -pi -e 's@(find_package\(Threads\))@$1\nlist(APPEND LLVM_LIBRARIES "-lzstd" "-lxml2" "-lz")@' "${cmake_source_dir}"/CMakeLists.txt

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

# --- ppc64le bundle .so build (after cmake configure, before zig2 link) ---
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  dbg echo "=== ppc64le lld bundle ==="
  mkdir -p "${PREFIX}/lib"
  source "${RECIPE_DIR}/building/_lld_bundle.sh"
  build_lld_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${PREFIX}/lib/" || exit 1
  source "${RECIPE_DIR}/building/_zigcpp_bundle.sh"
  build_zigcpp_bundle_ppc64le "${CXX}" "${PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" "${cmake_build_dir}" || exit 1
  install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-zigcpp-bundle.so" "${PREFIX}/lib/" || exit 1
fi

# --- Post CMake Configuration ---

# Append extra link deps to config.h (cmake doesn't know about conda's split packaging)
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux && is_cross; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"

  # pthread_atfork stub + --wrap mechanism is cmake-path-only. zig-build path
  # falls through to libpthread_nonshared.a's pthread_atfork (REL24 risk --
  # bundles will address that separately).
  if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
    perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
    create_pthread_atfork_stub "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  fi

  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
fi

# Always-linux: sysroot ld-script rewrite (needed by wrapper compile and any zig cc
# invocation that lacks --sysroot flags). On native linux-64 the sysroot's
# libpthread.so contains absolute /usr/lib64/... paths that LLD can't resolve.
if is_linux; then
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"
fi

if is_linux && is_cross; then
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot"
fi

dbg echo "=== zig build env ==="
if [[ "${CMAKE_BUILD:-0}" == "1" ]]; then
  source "${RECIPE_DIR}/building/_cmake.sh"
  cmake_build "${cmake_source_dir}" "${cmake_build_dir}" "${PREFIX}"
elif build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  :
else
  echo "ERROR: zig-build failed. Set CMAKE_BUILD=1 to force the cmake path explicitly." >&2
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
    command -v "qemu-${ZIG_QEMU_ARCH}" &>/dev/null && return 0
  fi
  return 1
}

if [[ "${SKIP_LANGREF:-0}" == "1" ]]; then
  echo "INFO: Phase 2 langref skipped: SKIP_LANGREF=1 (local dev override)" >&2
elif _can_run_stage3; then
  dbg echo "=== phase 2 langref ==="
  _stage3_runner=()
  if is_cross && is_linux; then
    _stage3_runner=("qemu-${ZIG_QEMU_ARCH}")
  fi

  # Zig hardcodes qemu-<arch> lookup. The regular qemu-powerpc64le variant
  _qemu_shadow_dir=""
  if [ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]; then
    _qemu_shadow_dir=$(mktemp -d)
    ln -sf "${QEMU_EXECVE}" "${_qemu_shadow_dir}/qemu-${ZIG_QEMU_ARCH}"
    export PATH="${_qemu_shadow_dir}:${PATH}"
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

# === Phase 2: Unified wrapper install ===
WRAPPER_SRC="${RECIPE_DIR}/building/zig-wrapper.c"
WRAPPER_OBJDIR="${SRC_DIR}/_wrapper_build"
mkdir -p "${WRAPPER_OBJDIR}"

# Determine platform-specific directories first
if is_not_unix; then
    WRAPPER_BIN_DIR="${PREFIX}/Library/bin"
    REAL_ZIG_DIR="${PREFIX}/Library/share/zig"
    REAL_ZIG_NAME="zig-real.exe"
    EXE_EXT=".exe"
else
    WRAPPER_BIN_DIR="${PREFIX}/bin"
    REAL_ZIG_DIR="${PREFIX}/share/zig"
    REAL_ZIG_NAME="zig-real"
    EXE_EXT=""
fi

WRAPPER_C="${WRAPPER_OBJDIR}/zig-wrapper-built.c"

# Wrapper's baked default -target. On Windows the wrapper is named
# <arch>-w64-mingw32-zig and the feedstock ships MinGW (.dll.a) import libs, so
# default to the GNU/MinGW ABI; users can still select MSVC explicitly with
# -target <arch>-windows-msvc (the wrapper suppresses its default when the user
# passes -target). This is independent of ZIG_TRIPLET, which still controls how
# the zig binary itself is built (zig is multi-target).
case "${target_platform}" in
    win-64)    WRAPPER_DEFAULT_TARGET="x86_64-windows-gnu" ;;
    win-arm64) WRAPPER_DEFAULT_TARGET="aarch64-windows-gnu" ;;
    win-32)    WRAPPER_DEFAULT_TARGET="x86-windows-gnu" ;;
    *)         WRAPPER_DEFAULT_TARGET="${ZIG_TRIPLET%%.[0-9]*}" ;;
esac

# Substitute compile-time placeholders. Substitute @ZIG_REAL_PATH@ with the
# absolute zig-real path; conda's binary prefix-replacement handles relocation at install time.
sed -e "s|@ZIG_TARGET@|${WRAPPER_DEFAULT_TARGET}|g" \
    -e "s|@ZIG_REAL_PATH@|${REAL_ZIG_DIR//\\//}/${REAL_ZIG_NAME}|g" \
    "${WRAPPER_SRC}" > "${WRAPPER_C}"

mkdir -p "${WRAPPER_BIN_DIR}" "${REAL_ZIG_DIR}"

# macOS Mach-O needs header padding for conda's install_name_tool relinking
if [[ "${target_platform}" == osx-* ]]; then
    WRAPPER_LDFLAGS="-Wl,-headerpad_max_install_names"
else
    WRAPPER_LDFLAGS=""
fi

dbg echo "=== pre-wrapper compile ==="

# Per-target wrapper compile flags:
# - linux-ppc64le: pass explicit --target= so zig resolves the ppc64le dynamic
#   linker (/lib64/ld64.so.2) instead of the build-host's x86_64 one, and
#   selects ppc64le's 128-bit-long-double ABI so glibc's bits/stdio-ldbl.h skips
#   the __LDBL_REDIR_DECL asm-label redirect (clang rejects it, gcc accepts).
#   Do NOT add -mlong-double-128: zig 0.15's cc driver folds it into the target
#   query string, producing an InvalidAbiVersion parse error.
# - win-*: compile with -g0 (no debug info) so zig's PE/COFF link does not emit
#   a CodeView .pdb sidecar, which trips package_contents strict checks. A
#   defensive *.pdb removal after the build catches any sidecar that slips through.
_WRAPPER_CC_EXTRA=""
case "${target_platform}" in
    linux-ppc64le) _WRAPPER_CC_EXTRA="--target=${ZIG_TRIPLET}" ;;
    win-*)         _WRAPPER_CC_EXTRA="-g0" ;;
esac

# Compile wrapper using the just-built zig
PRIMARY_WRAPPER="${WRAPPER_BIN_DIR}/${CONDA_TRIPLET}-zig${EXE_EXT}"
"${PREFIX}/bin/zig" cc -O2 ${_WRAPPER_CC_EXTRA} ${WRAPPER_LDFLAGS} "${WRAPPER_C}" -o "${PRIMARY_WRAPPER}"

# Cross-arch wrapper detection note for downstream consumers:
# All Windows variant wrappers (x86_64-w64-mingw32-zig.exe,
# aarch64-w64-mingw32-zig.exe, i686-w64-mingw32-zig.exe) land in the SAME
# ${PREFIX}/Library/bin directory when multiple zig_<cross-target> activation
# packages are stacked in a build environment. Consumer recipes probing for
# compiler presence by filename alone (e.g.,
#   test -x .../aarch64-w64-mingw32-zig.exe
# ) will FALSE-POSITIVE on an x86_64 host: the file exists but is an
# x86_64-PE executable and cannot natively run aarch64 code. Consumers MUST
# disambiguate by either:
#   (a) inspecting the PE machine header (file, objdump -f, dumpbin /headers)
#   (b) actually invoking the wrapper and checking exit status / output
# See P-5 in zig_cc_consumer_pain_points.md.

# Install ergonomic-name copies (canonical suffix list at
# ${RECIPE_DIR}/building/wrapper_modes.txt).
# Portable: simple file redirect, inline filter, CRLF strip — works in
# m2-bash 3.1 (no mapfile, no process substitution) and tolerates files
# checked out with CRLF line endings on Windows.
while IFS= read -r suffix || [ -n "${suffix}" ]; do
    suffix="${suffix%$'\r'}"
    case "${suffix}" in
        ''|'#'*) continue ;;
    esac
    cp -f "${PRIMARY_WRAPPER}" "${WRAPPER_BIN_DIR}/${CONDA_TRIPLET}-zig-${suffix}${EXE_EXT}"
done < "${RECIPE_DIR}/building/wrapper_modes.txt"

# Install wrapper_modes.txt for runtime self-test (A4)
case "${target_platform}" in
    win-*) SHARE_DIR="${PREFIX}/Library/share/zig-wrapper" ;;
    *)     SHARE_DIR="${PREFIX}/share/zig-wrapper" ;;
esac
mkdir -p "${SHARE_DIR}"
cp "${RECIPE_DIR}/building/wrapper_modes.txt" "${SHARE_DIR}/wrapper_modes.txt"

# zig's PE/COFF link can still emit a .pdb sidecar named after the output;
# it is not needed for the wrapper and trips package_contents strict checks.
case "${target_platform}" in
    win-*) rm -f "${WRAPPER_BIN_DIR}"/*.pdb ;;
esac

# Move raw zig out of PATH
mv "${PREFIX}/bin/zig" "${REAL_ZIG_DIR}/${REAL_ZIG_NAME}"

# === end Phase 2 ===

# Non-unix conda convention: artifacts go under Library/
if is_not_unix; then
  mkdir -p "${PREFIX}/Library/lib" "${PREFIX}/Library/doc"
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
if [[ "${ZIG_USE_CACHE:-}" == "0" || "${ZIG_USE_CACHE:-}" == "1" ]] && [[ -f "${RECIPE_DIR}/local-scripts/stub_cache.sh" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  dbg echo "=== Build cached for future restoration ==="
fi

