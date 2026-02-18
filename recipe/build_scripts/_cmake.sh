# CMake Configuration and Build Helpers for Zig Compilation
function cmake_build_install() {
  local build_dir=$1

  local current_dir
  current_dir=$(pwd)

  cd "${build_dir}" || return 1
    cmake --build . -- -j"${CPU_COUNT}" || return 1
    cmake --install . || return 1
  cd "${current_dir}" || return 1
}

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  # Build local cmake args array
  local cmake_args=()

  # Add zig compiler configuration if provided
  # Prefer ZIG_CC/ZIG_CXX from setup_zig_cc, fallback to legacy zig parameter
  if [[ -n "${ZIG_CC:-}" ]] && [[ -n "${ZIG_CXX:-}" ]]; then
    # Use wrappers created by setup_zig_cc (preferred)
    cmake_args+=("-DCMAKE_C_COMPILER=${ZIG_CC}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${ZIG_CXX}")
    cmake_args+=("-DCMAKE_AR=${ZIG_AR:-${zig:-ar}}")
    cmake_args+=("-DCMAKE_RANLIB=${ZIG_RANLIB:-ranlib}")
  elif [[ -n "${zig}" ]]; then
    # Legacy path: construct zig compiler args (requires ZIG_TARGET)
    local _target="${ZIG_TARGET:-x86_64-linux-gnu}"
    local _c="${zig};cc;-target;${_target};-mcpu=${MCPU:-baseline}"
    local _cxx="${zig};c++;-target;${_target};-mcpu=${MCPU:-baseline}"

    # Add QEMU flag for native (non-cross) compilation
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
      _c="${_c};-fqemu"
      _cxx="${_cxx};-fqemu"
    fi

    cmake_args+=("-DCMAKE_C_COMPILER=${_c}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${_cxx}")
    cmake_args+=("-DCMAKE_AR=${zig}")
    cmake_args+=("-DZIG_AR_WORKAROUND=ON")
  fi

  # Merge with global EXTRA_CMAKE_ARGS if it exists
  # Use ${var+x} syntax for bash 3.2 compatibility (macOS default bash)
  if [[ -n "${EXTRA_CMAKE_ARGS+x}" ]]; then
    cmake_args+=("${EXTRA_CMAKE_ARGS[@]}")
  fi

  # Add CMAKE_ARGS from environment if requested
  if [[ ${USE_CMAKE_ARGS:-0} == 1 ]]; then
    IFS=' ' read -r -a cmake_args_from_env <<< "${CMAKE_ARGS:-}"
    cmake_args+=("${cmake_args_from_env[@]}")
  fi

  # Create build directory and run cmake
  mkdir -p "${build_dir}" || return 1

  (
    cd "${build_dir}" &&
    cmake "${cmake_source_dir}" \
      -D CMAKE_INSTALL_PREFIX="${install_dir}" \
      "${cmake_args[@]}" \
      -G Ninja
  ) || return 1
}

function apply_cmake_patches() {
  local build_dir=$1

  # Check if CMAKE_PATCHES array exists and has elements
  if [[ -z "${CMAKE_PATCHES+x}" ]] || [[ ${#CMAKE_PATCHES[@]} -eq 0 ]]; then
    echo "No CMAKE_PATCHES defined, skipping patch application"
    return 0
  fi

  echo "Applying ${#CMAKE_PATCHES[@]} cmake patches to ${build_dir}"

  local patch_dir="${RECIPE_DIR}/patches/cmake"
  if [[ ! -d "${patch_dir}" ]]; then
    echo "ERROR: Patch directory ${patch_dir} does not exist" >&2
    return 1
  fi

  pushd "${build_dir}" > /dev/null || return 1
    for patch_file in "${CMAKE_PATCHES[@]}"; do
      local patch_path="${patch_dir}/${patch_file}"
      if [[ ! -f "${patch_path}" ]]; then
        echo "ERROR: Patch file ${patch_path} not found" >&2
        popd > /dev/null
        return 1
      fi

      echo "  Applying patch: ${patch_file}"
      if patch -p1 < "${patch_path}"; then
        echo "    ✓ ${patch_file} applied successfully"
      else
        echo "ERROR: Failed to apply patch ${patch_file}" >&2
        popd > /dev/null
        return 1
      fi
    done
  popd > /dev/null

  echo "All cmake patches applied successfully"
  return 0
}
