#!/usr/bin/env bash
set -euo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

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

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" "" "${target_platform}"
cat "${cmake_build_dir}"/config.h

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
create_zig_libc_file "${zig_build_dir}/libc_file"

# Create pthread_atfork stub for glibc 2.28 (missing on PowerPC64LE)
create_pthread_atfork_stub "${ZIG_ARCH}" "${CC}" "${ZIG_LOCAL_CACHE_DIR}"

remove_failing_langref "${zig_build_dir}"
