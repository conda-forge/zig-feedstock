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

# Bootstrap zig runs on the build machine — always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
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

# Patch 0007 adds -Ddoctest-target to build.zig (Linux only)
is_linux && EXTRA_ZIG_ARGS+=(-Ddoctest-target=${ZIG_TRIPLET})
# ppc64le cross: skip docgen — qemu-ppc64le doesn't faithfully emulate traps,
# and the ppc64le GCC linker has __tls_get_addr DSO ordering issues with doctests
[[ "${target_platform}" == "linux-ppc64le" ]] && is_cross && EXTRA_ZIG_ARGS+=(-Dno-langref)

if is_osx; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SYSTEM_LIBCXX=c++
    -DCMAKE_C_FLAGS="-Wno-incompatible-pointer-types"
  )
else
  EXTRA_CMAKE_ARGS+=(-DZIG_SYSTEM_LIBCXX=stdc++)
  EXTRA_ZIG_ARGS+=(--maxrss 7500000000)
fi

if is_not_unix; then
  EXTRA_CMAKE_ARGS+=(
    -DZIG_SHARED_LLVM=OFF
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
is_linux && is_cross && perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;-lzstd;-lxml2;-lz\"@" "${cmake_build_dir}"/config.h
is_osx && is_cross &&   perl -pi -e "s@(ZIG_LLVM_\w+ \")${BUILD_PREFIX}@\$1${PREFIX}@" "${cmake_build_dir}"/config.h
is_osx &&               perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${cmake_build_dir}"/config.h

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


is_debug && echo "=== Building with ZIG ==="
if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  is_debug && echo "SUCCESS: zig build completed successfully"
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

# Workaround for ziglang/zig#14919: add synchronization.def so zig can generate
# libsynchronization.a when cross-compiling to Windows (e.g. OCaml BYTECCLIBS uses -lsynchronization).
# IMPORTANT: LIBRARY must be api-ms-win-core-synch-l1-2-0.dll, NOT synchronization.dll.
# "synchronization.dll" is neither a real DLL on disk nor a valid API Set Schema name — it doesn't
# exist as a physical file in Windows or MSYS2. The real MinGW-w64 alias points to
# libapi-ms-win-core-synch-l1-2-0.a, whose LIBRARY directive is api-ms-win-core-synch-l1-2-0.dll.
# Windows API Set Schema resolves api-ms-win-* names to the actual host DLL at runtime.
if is_not_unix; then
  _mingw_common="${PREFIX}/Library/lib/zig/libc/mingw/lib-common"
else
  _mingw_common="${PREFIX}/lib/zig/libc/mingw/lib-common"
fi
if [[ -d "${_mingw_common}" ]]; then
  cat > "${_mingw_common}/synchronization.def" << 'SYNCHRONIZATION_DEF'
LIBRARY api-ms-win-core-synch-l1-2-0.dll

EXPORTS

DeleteSynchronizationBarrier
EnterSynchronizationBarrier
InitializeConditionVariable
InitializeSynchronizationBarrier
InitOnceBeginInitialize
InitOnceComplete
InitOnceExecuteOnce
InitOnceInitialize
SignalObjectAndWait
Sleep
SleepConditionVariableCS
SleepConditionVariableSRW
WaitOnAddress
WakeAllConditionVariable
WakeByAddressAll
WakeByAddressSingle
WakeConditionVariable
SYNCHRONIZATION_DEF
fi

# Pre-generate Windows PE import libraries (.a) from zig's MinGW .def/.def.in files.
# flexlink (OCaml's Windows linker) calls -print-search-dirs to find library
# search paths, then looks for libXXX.a files at those paths.  zig generates
# import libs internally at link time (cached in ~/.cache/zig/), but flexlink
# needs them at a fixed, known location.
#
# Two types of source files exist in lib-common/:
#   .def     — ready to use directly with dlltool (e.g. shlwapi.def)
#   .def.in  — C preprocessor templates that conditionally include exports by
#              architecture using macros from def-include/func.def.in
#              (e.g. kernel32.def.in, ws2_32.def.in, ole32.def.in)
#
# uuid is special: compiled from libsrc/uuid.c (no DLL import lib needed).
# Only generates files that are missing; safe to re-run.
if [[ -d "${_mingw_common}" ]]; then
  if is_not_unix; then
    _zig_bin="${PREFIX}/Library/bin/zig.exe"
  else
    _zig_bin="${PREFIX}/bin/zig"
  fi
  _def_include="${_mingw_common}/../def-include"
  _mingw_libsrc="${_mingw_common}/../libsrc"

  _dlltool=""
  for _cand in \
      "${BUILD_PREFIX}/bin/llvm-dlltool" \
      "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
      "$(command -v llvm-dlltool 2>/dev/null || true)"; do
    if [[ -x "${_cand}" ]]; then
      _dlltool="${_cand}"
      break
    fi
  done

  if [[ -n "${_dlltool}" ]] && [[ -x "${_zig_bin}" ]]; then
    is_debug && echo "=== Generating MinGW import libs (dlltool=${_dlltool}) ==="
    _gen_count=0

    # Helper: generate .a from a processed .def file
    _gen_implib() {
      local stem="$1" def="$2"
      local lib="${_mingw_common}/lib${stem}.a"
      [[ -f "${lib}" ]] && return 0
      local dll
      dll="$(awk '/^LIBRARY/{gsub(/"/, "", $2); print $2; exit}' "${def}")"
      [[ -z "${dll}" ]] && dll="${stem}.dll"
      "${_dlltool}" -m i386:x86-64 -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
      _gen_count=$(( _gen_count + 1 ))
    }

    # Step 1: plain .def files (shlwapi.def, version.def, synchronization.def, etc.)
    for _def in "${_mingw_common}"/*.def; do
      [[ -f "${_def}" ]] || continue
      _stem="$(basename "${_def%.def}")"
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 2: .def.in template files (ws2_32, kernel32, ole32, advapi32, user32, ...)
    # Process through zig's C preprocessor with x86_64 defines so architecture
    # macros (F_X64, F_I386, F64, F32, etc.) expand correctly.
    for _def_in in "${_mingw_common}"/*.def.in; do
      [[ -f "${_def_in}" ]] || continue
      _stem="$(basename "${_def_in%.def.in}")"
      _lib="${_mingw_common}/lib${_stem}.a"
      [[ -f "${_lib}" ]] && continue
      _def="${_mingw_common}/${_stem}.def"
      if [[ ! -f "${_def}" ]]; then
        "${_zig_bin}" cc -E -P \
          -target x86_64-windows-gnu \
          -x assembler-with-cpp \
          -I"${_def_include}" \
          "${_def_in}" 2>/dev/null > "${_def}" || { rm -f "${_def}"; continue; }
      fi
      _gen_implib "${_stem}" "${_def}"
    done

    # Step 3: uuid — compiled from C source (no DLL, no import lib needed).
    # zig compiles libsrc/uuid.c into a static archive.
    _uuid_lib="${_mingw_common}/libuuid.a"
    _uuid_src="${_mingw_libsrc}/uuid.c"
    if [[ ! -f "${_uuid_lib}" ]] && [[ -f "${_uuid_src}" ]]; then
      _uuid_obj="${_mingw_common}/_uuid.o"
      "${_zig_bin}" cc -target x86_64-windows-gnu -c "${_uuid_src}" \
          -o "${_uuid_obj}" 2>/dev/null && \
        "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
      rm -f "${_uuid_obj}"
      _gen_count=$(( _gen_count + 1 ))
    fi

    is_debug && echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="
  else
    is_debug && echo "=== llvm-dlltool or zig not found; skipping import lib pre-generation ==="
  fi
fi

is_debug && echo "=== Build installed for package: ${PKG_NAME} ==="

# Cache successful build (saves before rattler-build cleanup)
if [[ "${ZIG_USE_CACHE:-}" == "0" ]] || [[ "${ZIG_USE_CACHE:-}" == "1" ]]; then
  # stub_cache.sh already sourced at the top if ZIG_USE_CACHE=1
  [[ "$(type -t stub_cache_save)" != "function" ]] && source "${RECIPE_DIR}/local-scripts/stub_cache.sh"
  stub_cache_save
  is_debug && echo "=== Build cached for future restoration ==="
fi
