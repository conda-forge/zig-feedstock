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
    is_debug && echo "No CMAKE_PATCHES defined, skipping patch application"
    return 0
  fi

  is_debug && echo "Applying ${#CMAKE_PATCHES[@]} cmake patches to ${source_dir}"

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

      is_debug && echo "  Applying patch: ${patch_file}"
      if patch -p1 < "${patch_path}"; then
        is_debug && echo "    ${patch_file} applied successfully"
      else
        echo "ERROR: Failed to apply patch ${patch_file}" >&2
        popd > /dev/null
        return 1
      fi
    done
  popd > /dev/null

  is_debug && echo "All cmake patches applied successfully"
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

  if is_linux; then
    CMAKE_PATCHES+=(
      0001-linux-maxrss-CMakeLists.txt.patch
      0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
    )
    if is_cross; then
      CMAKE_PATCHES+=(0003-cross-CMakeLists.txt.patch)
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

  is_debug && echo "Applying CMake patches..."
  apply_cmake_patches "${source_dir}"

  if cmake_build_install "${build_dir}" "${install_prefix}"; then
    is_debug && echo "SUCCESS: cmake fallback build completed successfully"
  else
    echo "ERROR: Both zig build and cmake build failed" >&2
    exit 1
  fi
}
