#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
ZIG_ARCH="powerpc64le"

# Add ld.bfd for relocation issue
# CRITICAL: Remove conda's -fno-plt which breaks PowerPC64LE!
# Conda's default flags include -fno-plt which disables PLT usage
# -fno-plt forces direct branches (R_PPC64_REL24) which truncate at ±16MB
# For PowerPC64LE large binaries, we NEED PLT for unlimited function call range
# Remove -fno-plt and add -mcmodel=medium for TOC-relative addressing
# Also disable stack protection for build tools (glibc 2.28 __stack_chk_guard issues)
export CFLAGS="${CFLAGS//-fno-plt/} -fuse-ld=bfd -mcmodel=medium -fno-stack-protector"
export CXXFLAGS="${CXXFLAGS//-fno-plt/} -fuse-ld=bfd -mcmodel=medium -fno-stack-protector"
export LDFLAGS="${LDFLAGS} -fuse-ld=bfd"

# Ensure LD_LIBRARY_PATH includes BUILD_PREFIX/lib for libclang-cpp.so
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

qemu_prg=qemu-ppc64le-static

EXTRA_CMAKE_ARGS+=(
  -DZIG_TARGET_TRIPLE=${ZIG_ARCH}-linux-gnu
)

EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${SYSROOT_PATH}/lib64
  -Dtarget=${ZIG_ARCH}-linux-gnu
)

CMAKE_PATCHES+=(
  0001-linux-maxrss-CMakeLists.txt.patch
  0002-linux-pthread-atfork-stub-zig2-CMakeLists.txt.patch
  0003-cross-CMakeLists.txt.patch
)

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib
setup_crosscompiling_emulator "${qemu_prg}"
create_qemu_llvm_config_wrapper "${SYSROOT_PATH}"
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" "" "linux-ppc64le"
cat "${cmake_build_dir}"/config.h
remove_qemu_llvm_config_wrapper

# Build LLD libraries locally with -mcmodel=medium for PowerPC64LE
# This solves R_PPC64_REL24 relocation truncation errors that occur when linking
# large binaries (libzigcpp.a 50MB + liblldELF.a 11MB) with conda's pre-built LLD
echo "Building LLD libraries with -mcmodel=medium for PowerPC64LE..."
LLD_BUILD_DIR="${SRC_DIR}/lld-ppc64le-build"
build_lld_ppc64le_mcmodel "${SRC_DIR}/lld-source" "${LLD_BUILD_DIR}" "linux-ppc64le"
LLD_LIBS="${LLD_BUILD_DIR}/lib/liblldMinGW.a;${LLD_BUILD_DIR}/lib/liblldELF.a;${LLD_BUILD_DIR}/lib/liblldCOFF.a;${LLD_BUILD_DIR}/lib/liblldWasm.a;${LLD_BUILD_DIR}/lib/liblldMachO.a;${LLD_BUILD_DIR}/lib/liblldCommon.a"
perl -pi -e 's|#define ZIG_LLD_LIBRARIES ".*"|#define ZIG_LLD_LIBRARIES "'"${LLD_LIBS}"'"|g' "${cmake_build_dir}/config.h"

perl -pi -e 's/#define ZIG_LLVM_LINK_MODE "static"/#define ZIG_LLVM_LINK_MODE "shared"/g' "${cmake_build_dir}/config.h"
perl -pi -e 's|#define ZIG_LLVM_LIBRARIES ".*"|#define ZIG_LLVM_LIBRARIES "'${PREFIX}'/lib/libLLVM-20.so;-lz;-lzstd"|g' "${cmake_build_dir}/config.h"
perl -pi -e "s|(#define ZIG_LLVM_LIBRARIES \".*)\"|\$1;${ZIG_LOCAL_CACHE_DIR}/pthread_atfork_stub.o\"|g" "${cmake_build_dir}/config.h"

# Create Zig libc configuration file
create_zig_libc_file "${zig_build_dir}/libc_file" "${SYSROOT_PATH}" "${SYSROOT_ARCH}"

# Setup QEMU for the ZIG build (It is likely not used, but when in doubt ...)
ln -sf "$(which qemu-ppc64le-static)" "${BUILD_PREFIX}/bin/qemu-ppc64le"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

# Create pthread_atfork stub for glibc 2.28 (missing on PowerPC64LE)
create_pthread_atfork_stub "PowerPC64LE" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

remove_failing_langref "${zig_build_dir}"

# Prepare fallback CMake
# perl -pi -e 's/COMMAND ${LLVM_CONFIG_EXE}#COMMAND $ENV{CROSSCOMPILING_EMULATOR} ${LLVM_CONFIG_EXE}/' "${cmake_source_dir}"/cmake/Findllvm.cmake
perl -pi -e 's/( | ")${ZIG_EXECUTABLE}/ ${CROSSCOMPILING_EMULATOR}\1${ZIG_EXECUTABLE}/' "${cmake_source_dir}"/cmake/install.cmake

export ZIG_CROSS_TARGET_TRIPLE="${ZIG_ARCH}"-linux-gnu
export ZIG_CROSS_TARGET_MCPU="baseline"
