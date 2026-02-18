#!/usr/bin/env bash
# Cross-target build for linux-ppc64le using zig as C/C++ compiler
# Binary RUNS on linux-ppc64le (cross-compiled from linux-64)
# Requires QEMU for emulation during build verification
#
# Note: Cross-target still needs QEMU setup for running the built binary
# during the build process, but uses zig cc for compilation.

set -euo pipefail
source "${RECIPE_DIR}/build_scripts/_functions.sh"

SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
ZIG_TARGET="powerpc64le-linux-gnu"
ZIG_MCPU="baseline"
BOOTSTRAP_ZIG="${zig:-${BUILD_PREFIX}/bin/zig}"

echo "=== Cross-target: linux-64 -> linux-ppc64le using zig cc ==="
echo "  ZIG_TARGET: ${ZIG_TARGET}"
echo "  BOOTSTRAP_ZIG: ${BOOTSTRAP_ZIG}"
echo "  SYSROOT_PATH: ${SYSROOT_PATH}"

# Disable stack protection for cross-compilation build tools
export CFLAGS="${CFLAGS} -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS} -fno-stack-protector"

qemu_prg=qemu-ppc64le-static

# Setup zig as C/C++ compiler
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TARGET}" "${ZIG_MCPU}"

EXTRA_CMAKE_ARGS+=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=ppc64le
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    -DCMAKE_CROSSCOMPILING=ON
    -DZIG_TARGET_TRIPLE=${ZIG_TARGET}
)

# Note: -Dcpu=baseline is already set in build.sh base EXTRA_ZIG_ARGS
EXTRA_ZIG_ARGS+=(
    -fqemu
    --libc "${zig_build_dir}"/libc_file
    --libc-runtimes ${SYSROOT_PATH}/lib64
    -Dtarget=${ZIG_TARGET}
)

# Only maxrss patch needed with zig cc
CMAKE_PATCHES+=(
    0001-linux-maxrss-CMakeLists.txt.patch
    0003-cross-CMakeLists.txt.patch
)

# QEMU setup for running the built binary
setup_crosscompiling_emulator "${qemu_prg}"
create_qemu_llvm_config_wrapper "${SYSROOT_PATH}"
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" "${BOOTSTRAP_ZIG}"
remove_qemu_llvm_config_wrapper

# Create Zig libc configuration file (still needed for zig build step)
create_zig_libc_file "${zig_build_dir}/libc_file" "${SYSROOT_PATH}" "${SYSROOT_ARCH}"

# Setup QEMU for the ZIG build
ln -sf "$(which qemu-ppc64le-static)" "${BUILD_PREFIX}/bin/qemu-ppc64le"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

# Remove documentation tests that fail during cross-compilation
remove_failing_langref "${zig_build_dir}"

# Prepare fallback CMake
perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_TARGET}"
export ZIG_CROSS_TARGET_MCPU="${ZIG_MCPU}"
