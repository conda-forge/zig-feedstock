# CMake Configuration and Build Helpers for Zig Compilation

function cmake_build_install() {
  local build_dir=$1
  local install_prefix=${2:-}

  local current_dir
  current_dir=$(pwd)

  local install_args=()
  [[ -n "${install_prefix}" ]] && install_args+=(--prefix "${install_prefix}")

  cd "${build_dir}" || return 1
    cmake --build . -- -j"${CPU_COUNT}" ${NINJA_FLAGS:-} || return 1
    cmake --install . "${install_args[@]}" || return 1
  cd "${current_dir}" || return 1
}

function apply_cmake_patches() {
  local source_dir=$1

  # Check if CMAKE_PATCHES array exists and has elements
  if [[ -z "${CMAKE_PATCHES+x}" ]] || [[ ${#CMAKE_PATCHES[@]} -eq 0 ]]; then
    dbg echo "No CMAKE_PATCHES defined, skipping patch application"
    return 0
  fi

  dbg echo "Applying ${#CMAKE_PATCHES[@]} cmake patches to ${source_dir}"

  local patch_dir="${RECIPE_DIR}/patches/cmake"
  if [[ ! -d "${patch_dir}" ]]; then
    echo "ERROR: Patch directory ${patch_dir} does not exist" >&2
    return 1
  fi

  pushd "${source_dir}" > /dev/null || return 1
    for patch_file in "${CMAKE_PATCHES[@]}"; do
      local patch_path="${patch_dir}/${patch_file}"
      if [[ ! -f "${patch_path}" ]]; then
        echo "ERROR: Patch file ${patch_path} not found" >&2
        popd > /dev/null
        return 1
      fi

      dbg echo "  Applying patch: ${patch_file}"
      if patch -p1 < "${patch_path}"; then
        dbg echo "    ${patch_file} applied successfully"
      else
        echo "ERROR: Failed to apply patch ${patch_file}" >&2
        popd > /dev/null
        return 1
      fi
    done
  popd > /dev/null

  dbg echo "All cmake patches applied successfully"
  return 0
}

# Host-arch cmake build for no-emulator cross-compile (Plan B Phase 1).
# Builds a host-runnable zig2 binary in $SRC_DIR/build-host/ using BUILD_PREFIX
# native compilers and host-arch LLVM/clang/lld libs. The resulting zig2 is
# used in Phase 2 to cross-compile stage3 for the target platform.
#
# Args:
#   $1 - cmake source directory (already patched)
#   $2 - host build directory (e.g. $SRC_DIR/build-host)
function _zig_compute_triple_from_uname() {
  # Derive a versioned zig target triple from uname (build_platform jinja
  # vars are not exported to shell). Used as fallback when ZIG_TRIPLET is
  # "native"/empty, or when computing host triple in cmake_host_build.
  local arch os abi_ver
  arch="$(uname -m)"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${arch}" in
    arm64)   arch="aarch64" ;;
    amd64)   arch="x86_64" ;;
  esac
  case "${os}" in
    darwin)
      abi_ver="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      echo "${arch}-macos.${abi_ver}-none"
      ;;
    linux)
      abi_ver="${c_stdlib_version:-2.17}"
      echo "${arch}-linux-gnu.${abi_ver}"
      ;;
    *)
      echo "native"
      ;;
  esac
}

function cmake_host_build() {
  local source_dir=$1
  local host_build_dir=$2

  mkdir -p "${host_build_dir}" || return 1

  local host_triple
  host_triple="$(_zig_compute_triple_from_uname)"

  dbg echo "Phase 1: host cmake build in ${host_build_dir} (target=${host_triple})"

  (
    cd "${host_build_dir}" &&
    CC="${CC_FOR_BUILD:-${CC}}" \
    CXX="${CXX_FOR_BUILD:-${CXX}}" \
    AR="${AR_FOR_BUILD:-${AR}}" \
    LD="${LD_FOR_BUILD:-${LD}}" \
    CFLAGS="${CFLAGS_FOR_BUILD:-}" \
    CXXFLAGS="${CXXFLAGS_FOR_BUILD:-}" \
    LDFLAGS="${LDFLAGS_FOR_BUILD:-}" \
    CMAKE_PREFIX_PATH="${BUILD_PREFIX}" \
    cmake "${source_dir}" \
      -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${host_build_dir}/install" \
      -DZIG_HOST_TARGET_TRIPLE="${host_triple}" \
      -DLLVM_DIR="${BUILD_PREFIX}/lib/cmake/llvm" \
      -DClang_DIR="${BUILD_PREFIX}/lib/cmake/clang" \
      -DLLD_DIR="${BUILD_PREFIX}/lib/cmake/lld" \
      -DZIG_STATIC_LLVM=OFF \
      -DZIG_SHARED_LLVM=ON
  ) || return 1

  # Build only zig2 — that's all Phase 2 needs
  cmake --build "${host_build_dir}" --target zig2 -- -j"${CPU_COUNT}" ${NINJA_FLAGS:-} || return 1

  dbg echo "Phase 1 complete: ${host_build_dir}/zig2 ready for cross-compile"
  return 0
}

# CMake fallback build — invoked when zig-build-with-zig fails.
# Assembles platform-specific CMAKE_PATCHES, applies them, and runs cmake build.
#
# Args:
#   $1 - cmake source directory
#   $2 - cmake build directory
#   $3 - install prefix
function cmake_fallback_build() {
  local source_dir=$1
  local build_dir=$2
  local install_prefix=$3

  # ZIG_TRIPLET resolves to "native" for native builds (jinja conditional
  # only matches cross variants). Force a versioned triple so zig stdlib
  # selects syscall-fallback paths instead of libc calls.
  local zig_host_triple="${ZIG_TRIPLET:-}"
  if [[ -z "${zig_host_triple}" ]] || [[ "${zig_host_triple}" == "native" ]]; then
    zig_host_triple="$(_zig_compute_triple_from_uname)"
  fi
  EXTRA_CMAKE_ARGS+=(-DZIG_HOST_TARGET_TRIPLE="${zig_host_triple}")

  CMAKE_PATCHES=()

  if is_linux; then
    CMAKE_PATCHES+=(
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
    fi
  fi

  # Universal: make -Dno-langref opt-in via -DZIG_NO_LANGREF=ON.
  # Default OFF restores langref.html generation that the upstream cmake
  # path otherwise hardcodes off.
  CMAKE_PATCHES+=(0004-no-langref-optional-CMakeLists.txt.patch)

  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    CMAKE_PATCHES+=(0005-ppc64le-mlongcall-CMakeLists.txt.patch)
    CMAKE_PATCHES+=(0006-ppc64le-lld-bundle-CMakeLists.txt.patch)
  fi

  if is_linux; then
    if is_cross; then
      perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${source_dir}"/cmake/install.cmake
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TRIPLET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
  fi

  if is_not_unix; then
    local _version
    _version=$(ls -1v "${VSINSTALLDIR}/VC/Tools/MSVC" | tail -n 1)
    local _UCRT_LIB_PATH="C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\ucrt\x64;C:\Windows\System32"
    local _MSVC_LIB_PATH="${VSINSTALLDIR//\\/\/}/VC/Tools/MSVC/${_version}/lib/x64"
    EXTRA_CMAKE_ARGS+=(
      -DZIG_CMAKE_PREFIX_PATH="${_MSVC_LIB_PATH};${_UCRT_LIB_PATH};${LIBPATH}"
    )
    CMAKE_PATCHES+=(
      0001-win-deprecations-zig_llvm.cpp.patch
      0001-win-deprecations-zig_llvm-ar.cpp.patch
    )
  fi

  # Plan B detection: for no-emulator cross-compile (osx-64 -> osx-arm64), build a
  # host-arch zig2 first, then use it to cross-compile stage3.
  # Linux cross uses qemu (existing CROSSCOMPILING_EMULATOR path).
  # Detection: macOS cross only -- linux qemu cross goes through existing flow.
  local need_host_build=0
  if is_cross && [[ "$(uname -s)" == "Darwin" ]]; then
    need_host_build=1
  fi

  dbg echo "Applying CMake patches..."
  apply_cmake_patches "${source_dir}"

  # ppc64le: 0005 patch adds target_compile_options(zigcpp PRIVATE -mlongcall)
  # but ninja considers libzigcpp.a up-to-date (source files unchanged) and
  # skips recompile. Delete the archive so ninja MUST rebuild zigcpp objects
  # with the new flag, otherwise zig2 link fails with R_PPC64_REL24 overflow.
  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    rm -f "${build_dir}/zigcpp/libzigcpp.a"
    rm -rf "${build_dir}/CMakeFiles/zigcpp.dir"
  fi

  # Re-configure cmake AFTER patches are applied. configure_cmake_zigcpp ran
  # earlier in build.sh with unpatched CMakeLists.txt, so Ninja files have
  # stale build-graph variables (notably BUILD_ZIG2_ARGS hardcoded -target
  # ${ZIG_HOST_TARGET_TRIPLE} = build host, not target). Re-running cmake
  # configure regenerates Ninja with the patched CMakeLists.txt so env-driven
  # cross overrides (ZIG_CROSS_TARGET_TRIPLE, CROSSCOMPILING_EMULATOR) take
  # effect. Skip for osx-cross which has its own Phase 2 reconfigure flow.
  if [[ "${need_host_build}" -eq 0 ]]; then
    if is_linux && is_cross; then
      _qemu_arch="${ZIG_TRIPLET%%-*}"
      if command -v "qemu-${_qemu_arch}" &>/dev/null; then
        export CROSSCOMPILING_EMULATOR="qemu-${_qemu_arch}"
        dbg echo "Set CROSSCOMPILING_EMULATOR=${CROSSCOMPILING_EMULATOR} for cross-cmake reconfigure"
      else
        echo "WARNING: linux-cross cmake path requires qemu-${_qemu_arch}; build will likely fail" >&2
      fi
    fi
    dbg echo "Re-configuring cmake with patched CMakeLists.txt..."
  if ! configure_cmake "${build_dir}" "${install_prefix}"; then
      echo "ERROR: cmake re-configure after patch application failed" >&2
      return 1
    fi
  fi

  if [[ "${need_host_build}" -eq 1 ]]; then
    local host_build_dir="${SRC_DIR}/build-host"
    if ! cmake_host_build "${source_dir}" "${host_build_dir}"; then
      echo "ERROR: Phase 1 host cmake build failed" >&2
      exit 1
    fi

    # Phase 2: configure target cmake (generates target config.h) but do NOT
    # build wasm2c/zig1/zig2 — we'll use the host-built zig2 for stage3.
    # configure_cmake (in _build.sh) generates ${build_dir}/config.h with
    # target-specific LLVM/clang/lld paths from $PREFIX.
    #
    # Force find_package(LLVM/Clang/LLD) to resolve in $PREFIX (target arch).
    # Without these, cmake picks up the host-arch copies from $BUILD_PREFIX
    # (installed there for Phase 1's cmake_host_build), and Phase 3 stage3
    # link fails with "invalid cpu architecture: x86_64" against
    # $BUILD_PREFIX/lib/libLLVM-20.dylib while targeting aarch64-macos.
    local _saved_extra_cmake_args=()
    if [[ -n "${EXTRA_CMAKE_ARGS+x}" ]]; then
      _saved_extra_cmake_args=("${EXTRA_CMAKE_ARGS[@]}")
    fi
    EXTRA_CMAKE_ARGS+=(
      -DLLVM_DIR="${PREFIX}/lib/cmake/llvm"
      -DClang_DIR="${PREFIX}/lib/cmake/clang"
      -DLLD_DIR="${PREFIX}/lib/cmake/lld"
      -DCMAKE_PREFIX_PATH="${PREFIX}"
    )
    if ! configure_cmake "${build_dir}" "${install_prefix}"; then
      echo "ERROR: Phase 2 target cmake configure failed" >&2
      exit 1
    fi
    # Restore EXTRA_CMAKE_ARGS so subsequent invocations are unaffected.
    EXTRA_CMAKE_ARGS=("${_saved_extra_cmake_args[@]+"${_saved_extra_cmake_args[@]}"}")

    # Phase 2 just regenerated config.h, overwriting build.sh post-Phase-A
    # perl edits. zig's cmake/Findllvm.cmake calls llvm-config directly
    # (ignoring -DLLVM_DIR), and find_program picks $BUILD_PREFIX/bin/llvm-config
    # first via PATH/CMAKE_PREFIX_PATH. This poisons ZIG_LLVM_* paths with
    # BUILD_PREFIX (x86_64) entries that break aarch64 stage3 link.
    # Rewrite all BUILD_PREFIX -> PREFIX in ZIG_LLVM_* lines + append libc++.
    perl -pi -e "s@${BUILD_PREFIX}@${PREFIX}@g if /ZIG_LLVM_/" "${build_dir}/config.h"
    perl -pi -e "s@(ZIG_LLVM_LIBRARIES \".*)\"@\$1;${PREFIX}/lib/libc++.dylib\"@" "${build_dir}/config.h"

    # Phase 3: drive stage3 cross-compile via host zig2 with target config.h
    local host_zig2="${host_build_dir}/zig2"
    if [[ ! -x "${host_zig2}" ]]; then
      echo "ERROR: host zig2 not found at ${host_zig2}" >&2
      exit 1
    fi

    # Phase 3 hardcodes its zig-build invocation (does NOT pull EXTRA_ZIG_ARGS).
    # Stage3 'compile exe zig ReleaseFast' declares ~7.8 GB upper bound; on osx-arm64
    # GHA runners zig auto-budgets --maxrss to ~7 GiB based on system RAM, tripping
    # `assert(memory_blocked_steps.items.len == 0)` in build_runner.zig:679. Pin
    # to 8 GiB here too so cross builds (e.g. osx-arm64 -> osx-64) clear the gate.
    # Linux uses 7500000000 in EXTRA_ZIG_ARGS; this Phase 3 path is osx-only.
    dbg echo "Phase 3: cross-compiling stage3 via ${host_zig2} -> ${install_prefix}"
    (
      cd "${source_dir}" &&
      "${host_zig2}" build \
        --zig-lib-dir "${source_dir}/lib" \
        --prefix "${install_prefix}" \
        --search-prefix "${PREFIX}" \
        --maxrss 8589934592 \
        "-Dversion-string=${PKG_VERSION:-0.16.0}" \
        "-Dtarget=${ZIG_TRIPLET}" \
        -Dcpu=baseline \
        -Denable-llvm \
        "-Dconfig_h=${build_dir}/config.h" \
        -Doptimize=ReleaseFast \
        -Dno-langref \
        -Dstrip
    ) || {
        echo "ERROR: Phase 3 stage3 cross-compile failed" >&2
        exit 1
      }

    dbg echo "SUCCESS: two-phase cmake cross-build completed"
    return 0
  fi

  # ppc64le: build libzig-lld-bundle.so before invoking cmake, so the bundle
  # is available for the linker when zig2 is linked.  This is a cmake-path-only
  # concern: the zig-build-zig path does not consume the bundle at all.
  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    source "${RECIPE_DIR}/building/_lld_bundle.sh"
    dbg echo "=== CMAKE FALLBACK: build_lld_bundle_ppc64le ==="
    build_lld_bundle_ppc64le "${CXX}" "${install_prefix}" "${ZIG_LOCAL_CACHE_DIR}"
  fi

  if cmake_build_install "${build_dir}" "${install_prefix}"; then
    dbg echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed" >&2
    exit 1
  fi

  if [[ "${target_platform}" == "linux-ppc64le" ]]; then
    install -m 755 "${ZIG_LOCAL_CACHE_DIR}/libzig-lld-bundle.so" "${install_prefix}/lib/"
  fi
}
