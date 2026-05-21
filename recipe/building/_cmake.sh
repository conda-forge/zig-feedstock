# CMake Configuration and Build Helpers for Zig Compilation

function cmake_build_install() {
  local build_dir=$1
  local install_prefix=${2:-}

  local current_dir
  current_dir=$(pwd)

  local install_args=()
  [[ -n "${install_prefix}" ]] && install_args+=(--prefix "${install_prefix}")

  cd "${build_dir}" || return 1
    cmake --build . -- -j"${CPU_COUNT}" || return 1
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

  CMAKE_PATCHES=()

  # Cross-compile stage1 host-tool split: zig-wasm2c / zig1 must run
  # on the build host.  Applied on every cross variant (osx + linux-
  # cross).  The patch routes those two targets through add_custom_
  # command + ZIG_STAGE1_HOST_CC (the -D flag is seeded earlier in
  # build.sh).
  #
  # NB: 0003-cross-CMakeLists.txt.patch (linux-cross) used to wrap
  # the wasm2c/zig1 invocations with ${CROSSCOMPILING_EMULATOR} so
  # qemu could run target-arch binaries.  With stage1-host-cc those
  # binaries are now host-arch and don't need an emulator.  The
  # other halves of 0003-cross (ZIG_CROSS_TARGET_TRIPLE / zig2 /
  # compiler_rt args / install.cmake's emulator-prefix substitution)
  # are still valid because zig2 and the install step use the
  # target-arch zig.
  # TODO(stage1-host-cc unify): when both patches are applied, the
  # 0003-cross hunks at @@-652 and @@-685 (emulator prefix on zig-
  # wasm2c / zig1) will fail because stage1-host-cc already rewrote
  # those COMMANDs.  Either:
  #   (a) split 0003-cross into _stage1 (drop) + _stage2 (keep), or
  #   (b) make stage1-host-cc patch resilient to the emulator-
  #       prefixed COMMANDs.
  # Until then, on linux-cross only stage1-host-cc applies; the
  # qemu fallback path is unreachable in practice (upstream-bootstrap
  # never enters CMake fallback).
  if [[ -n "${CC_FOR_BUILD:-}" && "${CC_FOR_BUILD:-}" != "${CC:-}" ]]; then
    CMAKE_PATCHES+=(0003-cmake-stage1-host-cc-CMakeLists.txt.patch)
  fi

  if is_linux; then
    CMAKE_PATCHES+=(
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      # 0003-cross conflicts with stage1-host-cc on linux-cross
      # (see TODO above).  Apply only when stage1-host-cc isn't.
      if [[ -z "${CC_FOR_BUILD:-}" || "${CC_FOR_BUILD:-}" == "${CC:-}" ]]; then
        CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
        perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${source_dir}"/cmake/install.cmake
      fi
      export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TRIPLET}"
      export ZIG_CROSS_TARGET_MCPU="baseline"
    fi
    if [[ "${target_platform}" == "linux-ppc64le" ]]; then
      CMAKE_PATCHES+=(0005-ppc64le-mlongcall-CMakeLists.txt.patch)
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

  if cmake_build_install "${build_dir}" "${install_prefix}"; then
    dbg echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed" >&2
    exit 1
  fi
}
