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
  _zig_lib="${PREFIX}/Library/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
else
  _zig_lib="${PREFIX}/lib/zig"
  _mingw_common="${_zig_lib}/libc/mingw/lib-common"
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
#
# Target arch detection for dlltool machine type and zig cc -target.
# ZIG_TRIPLET is e.g. "x86_64-windows-gnu" or "aarch64-windows-gnu".
_win_arch="${ZIG_TRIPLET%%-*}"
case "${_win_arch}" in
  x86_64)       _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu" ;;
  aarch64)      _dlltool_machine="arm64";        _win_target="aarch64-windows-gnu" ;;
  *)            _dlltool_machine="i386:x86-64"; _win_target="x86_64-windows-gnu"
                echo "WARN: unknown Windows arch '${_win_arch}', defaulting to x86_64" ;;
esac
if [[ -d "${_mingw_common}" ]]; then
  # Use the BUILD machine's zig binary (CONDA_ZIG_BUILD) so this works even
  # for cross-compilation targets (e.g. win-arm64 built on win-64) where the
  # installed zig binary is for the wrong architecture and can't execute.
  # BUILD_ZIG is the binary name (not a full path), so resolve via PATH first,
  # then fall back to explicit BUILD_PREFIX locations.
  _zig_bin="$(command -v "${BUILD_ZIG}" 2>/dev/null || true)"
  if [[ -z "${_zig_bin}" ]]; then
    if is_not_unix; then
      _zig_bin="${BUILD_PREFIX}/Library/bin/${BUILD_ZIG}"
    else
      _zig_bin="${BUILD_PREFIX}/bin/${BUILD_ZIG}"
    fi
  fi
  _def_include="${_mingw_common}/../def-include"
  _mingw_libsrc="${_mingw_common}/../libsrc"

  _dlltool=""
  for _cand in \
      "${BUILD_PREFIX}/bin/llvm-dlltool" \
      "${BUILD_PREFIX}/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool.exe" \
      "${BUILD_PREFIX}/Library/bin/llvm-dlltool" \
      "$(command -v llvm-dlltool 2>/dev/null || true)"; do
    if [[ -x "${_cand}" ]]; then
      _dlltool="${_cand}"
      break
    fi
  done

  is_debug && echo "=== MinGW import lib generation: zig=${_zig_bin} dlltool=${_dlltool:-not found} ==="
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
      "${_dlltool}" -m "${_dlltool_machine}" -D "${dll}" -d "${def}" -l "${lib}" 2>/dev/null || true
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
          -target "${_win_target}" \
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
      "${_zig_bin}" cc -target "${_win_target}" -c "${_uuid_src}" \
          -o "${_uuid_obj}" 2>/dev/null && \
        "${_zig_bin}" ar rcs "${_uuid_lib}" "${_uuid_obj}" 2>/dev/null || true
      rm -f "${_uuid_obj}"
      _gen_count=$(( _gen_count + 1 ))
    fi

    is_debug && echo "=== Generated ${_gen_count} import libs in ${_mingw_common} ==="

    # Step 4: Supplemental import libs from mingw-w64 .def.in templates.
    # Zig doesn't ship msvcrt.def or ucrtbase.def -- we provide complete
    # mingw-w64 versions that cover all exports (stdio, math, POSIX I/O, etc.).
    # These use #include "func.def.in" for arch macros, so -I must point to
    # our mingw-defs/ directory (NOT zig's def-include/).
    _supp_defs="${RECIPE_DIR}/building/mingw-defs"
    if [[ -d "${_supp_defs}" ]]; then
      is_debug && echo "=== Processing supplemental mingw-w64 .def.in templates ==="
      for _supp_in in "${_supp_defs}"/*.def.in; do
        [[ -f "${_supp_in}" ]] || continue
        _supp_stem="$(basename "${_supp_in%.def.in}")"
        # Skip support files (included by other .def.in, not standalone libs)
        case "${_supp_stem}" in
          func|ucrtbase-common|crt-aliases) continue ;;
        esac
        _supp_lib="${_mingw_common}/lib${_supp_stem}.a"
        [[ -f "${_supp_lib}" ]] && continue
        _supp_def="${_mingw_common}/${_supp_stem}.def"
        if [[ ! -f "${_supp_def}" ]]; then
          "${_zig_bin}" cc -E -P \
            -target "${_win_target}" \
            -x assembler-with-cpp \
            -I"${_supp_defs}" \
            "${_supp_in}" 2>/dev/null > "${_supp_def}" || { rm -f "${_supp_def}"; continue; }
        fi
        _gen_implib "${_supp_stem}" "${_supp_def}"
      done
      is_debug && echo "=== Supplemental import libs done (total ${_gen_count}) ==="
    fi

    # Pre-compile Windows CRT startup objects for flexlink.
    # flexlink explicitly links crt2.o (console exe), crt2win.o (GUI exe),
    # and dllcrt2.o (DLL) as the first object file.  Zig compiles these
    # internally, but flexlink searches for them on disk via -print-search-dirs
    # paths.  Compile from zig's bundled MinGW CRT sources.
    _mingw_crt="${_mingw_common}/../crt"
    _mingw_inc="${_mingw_common}/../include"
    _win_inc="${_zig_lib}/libc/include/any-windows-any"

    if [[ -d "${_mingw_crt}" ]]; then
      is_debug && echo "=== Compiling MinGW CRT startup objects from ${_mingw_crt} ==="
      is_debug && echo "=== CRT sources: $(ls "${_mingw_crt}" | tr '\n' ' ') ==="

      _crt_flags=(-target "${_win_target}" -mcpu=baseline
                  -I"${_mingw_inc}" -I"${_win_inc}"
                  -D_CRTIMP= -D__USE_MINGW_ACCESS -c)

      # crt2.o — console application entry (main)
      _crt2_obj="${_mingw_common}/crt2.o"
      if [[ ! -f "${_crt2_obj}" ]] && [[ -f "${_mingw_crt}/crtexe.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtexe.c" -o "${_crt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2.o ==" || true
      fi

      # crt2win.o — GUI application entry (WinMain)
      _crt2win_obj="${_mingw_common}/crt2win.o"
      if [[ ! -f "${_crt2win_obj}" ]] && [[ -f "${_mingw_crt}/crtexewin.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" -D_WINDOWS \
          "${_mingw_crt}/crtexewin.c" -o "${_crt2win_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled crt2win.o ===" || true
      fi

      # dllcrt2.o — DLL entry (DllMain)
      _dllcrt2_obj="${_mingw_common}/dllcrt2.o"
      if [[ ! -f "${_dllcrt2_obj}" ]] && [[ -f "${_mingw_crt}/crtdll.c" ]]; then
        "${_zig_bin}" cc "${_crt_flags[@]}" \
          "${_mingw_crt}/crtdll.c" -o "${_dllcrt2_obj}" 2>&1 | \
          { is_debug && cat || true; } && \
          is_debug && echo "=== Compiled dllcrt2.o ===" || true
      fi
    else
      is_debug && echo "=== MinGW CRT sources not found at ${_mingw_crt} ==="
    fi

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
