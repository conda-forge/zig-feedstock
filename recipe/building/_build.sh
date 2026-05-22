# ZIG BUILD FUNCTIONS

source "${RECIPE_DIR}/building/_common.sh"

function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  dbg echo "[build_zig_with_zig] zig=${zig} build_dir=${build_dir} install_dir=${install_dir}"
  dbg echo "[build_zig_with_zig] EXTRA_ZIG_ARGS: ${EXTRA_ZIG_ARGS[*]+\"${EXTRA_ZIG_ARGS[*]}\"}"

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      local rc=0
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
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

# build_native_zig_bootstrap — two-stage bootstrap for ppc64le cross builds.
#
# WHY THIS IS NEEDED:
#   The upstream ziglang.org linux-64 bootstrap binary (used when
#   bootstrap_via_upstream=true) was built from upstream 0.17 source
#   WITHOUT our patches.  In particular it lacks:
#     - ppc64le LdScript support (our patches/ppc64le/0001-arch-support-LdScript.zig.patch
#       and friends): the upstream bootstrap panics when it encounters the ppc64le
#       sysroot's text linker scripts during the cross-compile of zig itself.
#     - DWARF64 eh_frame skip (Elf-eh_frame-skip-dwarf64.patch): can trigger
#       additional panics in the bootstrap stage.
#   Our patched source fixes both issues, but those fixes only take effect in
#   the zig binary we *produce* — not in the upstream bootstrap we *use*.
#   Solution: build a native linux-64 zig from our patched source first (using
#   the upstream bootstrap which works fine for x86_64-linux-gnu), then use
#   THAT patched-native zig as the bootstrap for the ppc64le cross-compile.
#
# WHEN IT ACTIVATES:
#   Only for linux-ppc64le cross builds with bootstrap_via_upstream=true.
#   This is the only combination where the upstream bootstrap lacks our patches
#   and those patches are needed by the bootstrap stage of the cross-compile.
#
# WHEN IT CAN BE REMOVED:
#   When upstream 0.17 (or later) restores ppc64le LdScript support in their
#   shipped binary, OR when conda-forge publishes a matching zig_impl_linux-64
#   0.17 package so bootstrap_via_upstream can be set to false.
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
