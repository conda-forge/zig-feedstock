# ZIG BUILD FUNCTIONS

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
        -Dversion-string="${PKG_VERSION}" || return 1
        # --search-prefix "${install_dir}" \
    cd "${current_dir}" || return 1
  else
    echo "No build directory found" >&2
    return 1
  fi
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

function configure_cmake_zigcpp() {
  local build_dir=$1
  local install_dir=$2
  local zig=${3:-}

  configure_cmake "${build_dir}" "${install_dir}" "${zig}"
  pushd "${build_dir}"
    cmake --build . --target zigcpp -- -j"${CPU_COUNT}"
  popd
}

function remove_failing_langref() {
  local build_dir=$1
  local testslistfile=${2:-"${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt}

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}"/doc/langref ]]; then
    # These langref code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
    # No idea why this comes up, there is no -lmvec_nonshared.a on the link command
    # there seems to be no way to redirect to sysroot/usr/lib64/libmvec_nonshared.a
    grep -v -f "${testslistfile}" "${build_dir}"/doc/langref.html.in > "${build_dir}"/doc/_langref.html.in
    mv "${build_dir}"/doc/_langref.html.in "${build_dir}"/doc/langref.html.in
    while IFS= read -r file
    do
      rm -f "${build_dir}"/doc/langref/"$file"
    done < "${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt
  else
    echo "No langref directory found"
    exit 1
  fi
}
