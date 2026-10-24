# ZIG BUILD FUNCTIONS

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_zig_diag.sh"

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  dbg echo "[build_zig_with_zig] zig=${zig} build_dir=${build_dir} install_dir=${install_dir}"
  dbg echo "[build_zig_with_zig] ZIG_MAKER_ARGS: ${ZIG_MAKER_ARGS[*]+\"${ZIG_MAKER_ARGS[*]}\"}"
  dbg echo "[build_zig_with_zig] ZIG_PKG_OPTS: ${ZIG_PKG_OPTS[*]+\"${ZIG_PKG_OPTS[*]}\"}"

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      local rc=0
      "${zig}" build \
        --prefix "${install_dir}" \
        ${ZIG_MAKER_ARGS[@]+"${ZIG_MAKER_ARGS[@]}"} \
        ${ZIG_PKG_OPTS[@]+"${ZIG_PKG_OPTS[@]}"} \
        -Dversion-string="${PKG_VERSION}" 2>&1 || rc=$?
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

# osx has no conda compiler activation: the bootstrap zig is CC/CXX for the
# zigcpp cmake build, with conda's libc++ headers (ABI match with libLLVM).
function setup_osx_zig_cc() {
  local dir="${SRC_DIR}/_zigcc"
  mkdir -p "${dir}" || return 1
  printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' \
    "${BUILD_ZIG}" "${ZIG_TRIPLET}" > "${dir}/zig-cc"
  # `zig cc` + -I: `zig c++` injects its bundled libcxx; -I beats every -isystem
  printf '#!/bin/sh\nexec "%s" cc -target %s -nostdinc++ -I "%s/include/c++/v1" "$@"\n' \
    "${BUILD_ZIG}" "${ZIG_TRIPLET}" "${PREFIX}" > "${dir}/zig-c++"
  chmod +x "${dir}/zig-cc" "${dir}/zig-c++" || return 1

  export CC="${dir}/zig-cc"
  export CXX="${dir}/zig-c++"
  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_AR="$(command -v llvm-ar)"
    -DCMAKE_RANLIB="$(command -v llvm-ranlib)"
    -DCMAKE_FIND_FRAMEWORK=LAST
    -DCMAKE_FIND_APPBUNDLE=LAST
  )

  # What conda's clang activation used to export via CMAKE_ARGS
  local _int
  _int="$(command -v llvm-install-name-tool || command -v install_name_tool || true)"
  if [[ -n "${_int}" ]]; then
    export INSTALL_NAME_TOOL="${_int}"
    EXTRA_CMAKE_ARGS+=(-DCMAKE_INSTALL_NAME_TOOL="${_int}")
  fi
  [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]] && \
    EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}")
  [[ -n "${CONDA_BUILD_SYSROOT:-}" ]] && \
    EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT="${CONDA_BUILD_SYSROOT}")

  if is_cross; then
    local _arch
    case "${target_platform}" in
      osx-64) _arch=x86_64 ;;
      *)      _arch=arm64 ;;
    esac
    # llvm-config derives its prefix from its own location: a build-arch copy
    # in PREFIX/bin (listed first below) yields host-arch LLVM/clang paths.
    if [[ -x "${BUILD_PREFIX}/bin/llvm-config" ]]; then
      rm -f "${PREFIX}/bin/llvm-config"
      cp "${BUILD_PREFIX}/bin/llvm-config" "${PREFIX}/bin/llvm-config" || return 1
    fi
    # CMAKE_OSX_ARCHITECTURES is already set in build.sh
    EXTRA_CMAKE_ARGS+=(
      -DCMAKE_SYSTEM_NAME=Darwin
      -DCMAKE_SYSTEM_PROCESSOR="${_arch}"
      -DCMAKE_PREFIX_PATH="${PREFIX}"
      -DCMAKE_PROGRAM_PATH="${PREFIX}/bin;${BUILD_PREFIX}/bin"
      -DCMAKE_FIND_ROOT_PATH="${PREFIX};${CONDA_BUILD_SYSROOT:-}"
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    )
  else
    EXTRA_CMAKE_ARGS+=(-DCMAKE_PROGRAM_PATH="${BUILD_PREFIX}/bin;${PREFIX}/bin")
  fi
}

function configure_cmake() {
  local build_dir=$1
  local install_dir=$2

  # Build local cmake args array — conda's CC/CXX (clang/gcc), except osx
  # (setup_osx_zig_cc); never zig-cc elsewhere (baked-in target breaks cross).
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

  if is_osx; then
    setup_osx_zig_cc || return 1
  fi
  configure_cmake "${build_dir}" "${install_dir}"
  pushd "${build_dir}"
    cmake --build . --target zigcpp -- -j"${CPU_COUNT}" ${NINJA_FLAGS:-}
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

# ppc64le two-stage bootstrap. Rationale and removal condition: reference doc S7.
#
# OUTPUTS:
#   Sets the variable ZIG_TWO_STAGE_BOOTSTRAP_ZIG to the path of the patched
#   native zig binary (caller must assign to BUILD_ZIG).
#
# Usage: build_native_zig_bootstrap
function build_native_zig_bootstrap() {
  local _install_dir="${SRC_DIR}/native-zig-bootstrap-install"
  # build_native.sh uses an isolated conda env (separate LLVM, toolchain, and
  # sysroot) — this avoids contamination from the cross-compile env's ppc64le
  # LLVM/sysroot settings that would break a native x86_64-linux-gnu build.
  BUILD_NATIVE_STAGE1_ONLY=1 build_native_zig "${_install_dir}"
  ZIG_TWO_STAGE_BOOTSTRAP_ZIG="${BUILD_ZIG}"
  echo "[build_native_zig_bootstrap] patched native zig ready: ${ZIG_TWO_STAGE_BOOTSTRAP_ZIG}"
}
