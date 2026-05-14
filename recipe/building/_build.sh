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

  # Build local cmake args array — always use conda's CC/CXX (clang/gcc),
  # never zig-cc (which has a baked-in target that conflicts with cross-builds).
  local cmake_args=()

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

# Build a native zig from source when the conda bootstrap can't compile a new version.
# Useful when upstream zig changes break self-compilation with the previous release.
# Usage: build_native_zig <install_dir>
# Sets BUILD_ZIG to the native-built binary path on success.
function build_native_zig() {
  local install_dir=$1
  echo "=== BUILD_NATIVE_ZIG: building native zig via build_native.sh ==="
  "${RECIPE_DIR}/building/build_native.sh" "${install_dir}"
  BUILD_ZIG="${install_dir}/zig_native_patched"
  echo "=== Using native-built zig as bootstrap: ${BUILD_ZIG} ==="
}

# sanitize_cross_cflags TARGET_ARCH FLAGS...
# Strips arch-incompatible -march/-mtune/-mcpu/-mfeat flags injected by
# conda-build for the build host; deduplicates; prints cleaned flags.
# Intentional target-arch flags (e.g. ppc64le -mlongcall) are never touched
# because they match the target arch family, not the host arch family.
sanitize_cross_cflags() {
  local _tarch="$1"; shift
  local _flags="$*" _result="" _seen="" _flag

  local _drop_x86='-march=nocona|-march=core2|-march=haswell|-march=skylake|-march=x86-64|-march=x86-64-v[234]|-mtune=nocona|-mtune=core2|-mtune=haswell|-mtune=skylake|-mtune=generic|-mssse3|-msse4|-msse4\.1|-msse4\.2|-mavx|-mavx2|-mfma'
  local _drop_arm='-march=armv8-a|-march=armv8\.[0-9]-a|-march=armv9-a|-mtune=cortex-[a-z0-9-]+|-mtune=neoverse-[a-z0-9-]+'
  local _drop_ppc='-mcpu=power[0-9]+|-mtune=power[0-9]+|-mvsx|-maltivec'

  local _remove_pat
  case "${_tarch}" in
    aarch64|arm64)  _remove_pat="${_drop_x86}|${_drop_ppc}" ;;
    ppc64le)        _remove_pat="${_drop_x86}|${_drop_arm}" ;;
    64|x86_64)      _remove_pat="${_drop_arm}|${_drop_ppc}" ;;
    *)              _remove_pat="${_drop_x86}|${_drop_arm}|${_drop_ppc}" ;;
  esac

  for _flag in ${_flags}; do
    printf '%s\n' "${_flag}" | grep -qE "^(${_remove_pat})$" && continue
    printf ' %s ' "${_seen}" | grep -qF " ${_flag} " && continue
    _seen="${_seen} ${_flag}"
    _result="${_result:+${_result} }${_flag}"
  done
  echo "${_result}"
}

# sanitize_and_export_cross_flags -- sanitize CFLAGS/CXXFLAGS for cross builds.
# Reads ${target_platform}; mutates and re-exports CFLAGS and CXXFLAGS.
sanitize_and_export_cross_flags() {
  local _arch="${target_platform##*-}"
  local _v
  for _v in CFLAGS CXXFLAGS; do
    [[ -z "${!_v:-}" ]] && continue
    declare -g "${_v}=$(sanitize_cross_cflags "${_arch}" "${!_v}")"
    export "${_v}"
  done
}
