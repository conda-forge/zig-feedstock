# ZIG BUILD FUNCTIONS

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  is_debug && echo "[build_zig_with_zig] zig=${zig} build_dir=${build_dir} install_dir=${install_dir}"
  is_debug && echo "[build_zig_with_zig] EXTRA_ZIG_ARGS: ${EXTRA_ZIG_ARGS[*]+"${EXTRA_ZIG_ARGS[*]}"}"

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      local rc=0
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
        -Dversion-string="${PKG_VERSION}" || rc=$?
    cd "${current_dir}" || return 1
    if [[ ${rc} -ne 0 ]]; then
      echo "[build_zig_with_zig] FAILED (exit code ${rc})" >&2
      return ${rc}
    fi
  else
    echo "[build_zig_with_zig] No build directory found: ${build_dir}" >&2
    return 1
  fi
}

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2

  # Build local cmake args array
  local cmake_args=()

  # Add zig compiler configuration if provided
  if [[ -n "${ZIG_CC:-}" ]] && [[ -n "${ZIG_CXX:-}" ]]; then
    cmake_args+=("-DCMAKE_C_COMPILER=${ZIG_CC}")
    cmake_args+=("-DCMAKE_CXX_COMPILER=${ZIG_CXX}")
    cmake_args+=("-DCMAKE_AR=${ZIG_AR:-ar}")
    cmake_args+=("-DCMAKE_RANLIB=${ZIG_RANLIB:-ranlib}")
  fi

  # Merge with global EXTRA_CMAKE_ARGS if it exists
  if [[ -n "${EXTRA_CMAKE_ARGS+x}" ]]; then
    cmake_args+=("${EXTRA_CMAKE_ARGS[@]}")
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

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2

  configure_cmake "${build_dir}" "${install_dir}"
  pushd "${build_dir}"
    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  popd
}
