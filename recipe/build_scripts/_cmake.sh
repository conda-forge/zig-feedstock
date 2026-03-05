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
