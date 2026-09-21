#!/usr/bin/env bash

set -uo pipefail
# DEBUG_ZIG_BUILD=1 switches this script into debug mode:
#   - errexit OFF, so a run continues past the first failing command
#   - xtrace ON, restoring the `+ cmd` tracing conda-build/rattler-build applies
# Default (0) is the CI mode: strict errexit, no xtrace.
#
# RECOVERY: conda-forge has NO per-run environment override. To trace a failing
# CI lane you must add DEBUG_ZIG_BUILD: "1" to recipe.yaml's zig_impl script env:
# block and push a round. Do that before investigating a build-script failure --
# xtrace is what made the osx-64 Rosetta `ar` failure diagnosable.
#
# brush 0.4.0 (#1245): with -x on, a bare VAR=value after a failing command
# inherits its status and errexit aborts. Never run -e and -x together.
if [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; then
  set +e
  set -x
else
  set -e
  { set +x; } 2>/dev/null
fi
IFS=$'\n\t'

# Fault instrumentation for the prologue below. An ERR trap does not alter the
# traced program, so unlike -x it is safe with errexit armed. brush leaves some
# BASH_* vars unset, hence the guards.
trap 'printf "BUILD-ERR: status=%s line=%s cmd=%s\n" "$?" "${LINENO:-?}" "${BASH_COMMAND:-?}" >&2' ERR

source "${RECIPE_DIR}/building/_bash_check.sh"

export build_platform="${build_platform:-${target_platform}}"

# --- Functions ---

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_build.sh"  # configure_cmake_zigcpp, build_zig_with_zig

# --- Step 1: Early exits ---
source "${RECIPE_DIR}/building/_guards.sh"

# --- Main ---

# Bootstrap selection (build_number == 0 only: no-op otherwise)
source "${RECIPE_DIR}/building/_upstream_bootstrap.sh"
setup_upstream_zig_bootstrap

# Bootstrap zig runs on the build machine -- always use CONDA_ZIG_BUILD
BUILD_ZIG="${CONDA_ZIG_BUILD}"

# Operator switch (off by default): rebuild a native bootstrap zig from our
# patched source (no 0003 GCC redirect) and use it instead of the published,
# 0003-contaminated CONDA_ZIG_BUILD. See recipe.yaml's bootstrap_native_rebuild
# and building/_native_bootstrap.sh. Gate is the flag OR the ppc64le carve-out
# in recipe.yaml (bootstrap_native_rebuild); carve-out is temporary for build 17.
if [[ "${ZIG_BOOTSTRAP_NATIVE_REBUILD:-0}" == "1" ]]; then
  if [[ ! -d "${SRC_DIR}/zig-source" ]]; then
    echo "ERROR: ZIG_BOOTSTRAP_NATIVE_REBUILD=1 but ${SRC_DIR}/zig-source is missing" >&2
    exit 1
  fi
  source "${RECIPE_DIR}/building/_native_bootstrap.sh"
  build_native_bootstrap_zig "${SRC_DIR}/zig-source" "${BUILD_ZIG}"
  BUILD_ZIG="${NATIVE_BOOTSTRAP_ZIG}"
fi

export CMAKE_BUILD_PARALLEL_LEVEL="${CPU_COUNT}"
export CMAKE_GENERATOR=Ninja
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR_OVERRIDE:-${SRC_DIR}/zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-local-cache"

cmake_source_dir="${SRC_DIR}/zig-source"
cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${PREFIX}"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${zig_build_dir}" && cp -r "${cmake_source_dir}"/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"

# --- Step 2: Common CMake/zig configuration ---
source "${RECIPE_DIR}/building/_configure_args.sh"

# --- libzigcpp Configuration ---

if is_linux; then
  source "${RECIPE_DIR}/building/_libc_tuning.sh"
  create_gcc14_glibc28_compat_lib

  if is_cross; then
    rm "${PREFIX}"/bin/llvm-config
    cp "${BUILD_PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config
  fi
fi

if is_osx && is_cross; then
  case "${target_platform}" in
    osx-64)     EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
    osx-arm64)  EXTRA_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
  esac
fi

configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

# --- Step 3: Post CMake Configuration ---
source "${RECIPE_DIR}/building/_config_h_fixups.sh"

# --- Cross-build setup (must happen BEFORE Stage 1 since EXTRA_ZIG_ARGS has --libc) ---

if is_linux; then
  source "${RECIPE_DIR}/building/_cross.sh"
  source "${RECIPE_DIR}/building/_atfork.sh"
  source "${RECIPE_DIR}/building/_sysroot_fix.sh"

  # Fix sysroot libc.so linker scripts 2.17 to use relative paths
  fix_sysroot_libc_scripts "${BUILD_PREFIX}"

  create_zig_linux_libc_file "${zig_build_dir}/libc_file"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_pthread_atfork_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
  perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/libc_single_threaded_stub.o\"|g" "${cmake_build_dir}/config.h"
  create_libc_single_threaded_stub "${CONDA_TRIPLET%%-*}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"
fi


if build_zig_with_zig "${zig_build_dir}" "${BUILD_ZIG}" "${PREFIX}"; then
  dbg echo "=== ZIG BUILD: SUCCESS ==="
else
  echo "ERROR: zig-build failed." >&2
  exit 1
fi


# Odd random occurence of zig.pdb
rm -f "${PREFIX}/bin/zig.pdb"

# macOS: --search-prefix adds a library search but does not embed LC_RPATH in the Mach-O binary.
if is_osx; then
  install_name_tool -add_rpath "${PREFIX}/lib" "${PREFIX}/bin/zig"
fi

if is_linux; then
  patchelf --set-rpath '$ORIGIN/../lib' "${PREFIX}/bin/zig"
fi

# --- Step 4: Phase 2 - build langref via stage3 (full compiler with translate_c) ---
source "${RECIPE_DIR}/building/_langref.sh"

# --- Step 5: Post-install packaging ---
source "${RECIPE_DIR}/building/_package_layout.sh"

dbg echo "=== Build installed for package: ${PKG_NAME} ==="
