#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${zig_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# Now set up PowerPC64LE cross-compilation environment for Stage 2
SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"
ZIG_ARCH="powerpc64le"

# Add ld.bfd for relocation issue
# CRITICAL: Remove conda's -fno-plt which breaks PowerPC64LE!
# Conda's default flags include -fno-plt which disables PLT usage
# -fno-plt forces direct branches (R_PPC64_REL24) which truncate at ±16MB
# For PowerPC64LE large binaries, we NEED PLT for unlimited function call range
# Remove -fno-plt and add -mcmodel=medium for TOC-relative addressing
export CFLAGS="${CFLAGS//-fno-plt/} -fuse-ld=bfd -mcmodel=medium"
export CXXFLAGS="${CXXFLAGS//-fno-plt/} -fuse-ld=bfd -mcmodel=medium"
export LDFLAGS="${LDFLAGS} -fuse-ld=bfd"

# Ensure LD_LIBRARY_PATH includes BUILD_PREFIX/lib for libclang-cpp.so
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

zig="${BUILD_PREFIX}"/bin/zig

# Use stage 1 Zig for cross-compilation instead
  if [[ "1" == "1" ]]; then
    # STAGE 1: Build x86_64 Zig with PowerPC64LE patches for use as bootstrap compiler
    echo "=== STAGE 1: Building x86_64 Zig with PowerPC64LE support ==="
    stage1_build_dir="${SRC_DIR}/stage1-x86_64"
    (

      mkdir -p "${stage1_build_dir}"
      cp -r "${SRC_DIR}"/zig-source/* "${stage1_build_dir}"
      remove_failing_langref "${stage1_build_dir}"

      # Build native x86_64 Zig with patches applied (patches already applied during source extraction)
      # Need to build with LLVM support for proper cross-compilation
      # Save cross-compilation flags and clear them for native build
      SAVED_CC="${CC}"
      SAVED_CXX="${CXX}"
      SAVED_AR="${AR}"
      SAVED_CFLAGS="${CFLAGS}"
      SAVED_CXXFLAGS="${CXXFLAGS}"
      SAVED_LDFLAGS="${LDFLAGS}"
      SAVED_PATH="${PATH}"

      export CC="${CC_FOR_BUILD}"
      export CXX="${CXX_FOR_BUILD}"
      export AR="${AR_FOR_BUILD:-ar}"
      export CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${BUILD_PREFIX}/include"
      export CPPFLAGS="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2 -isystem ${BUILD_PREFIX}/include"
      export CXXFLAGS="-fvisibility-inlines-hidden -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${BUILD_PREFIX}/include"
      export LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined -Wl,-rpath,${BUILD_PREFIX}/lib -Wl,-rpath-link,${BUILD_PREFIX}/lib -L${BUILD_PREFIX}/lib"
      export LLVM_CONFIG="${BUILD_PREFIX}"/bin/llvm-config
 
      # single-threaded only in glibc 2.32
      EXTRA_CMAKE_ARGS+=(
        -DCMAKE_PREFIX_PATH="${BUILD_PREFIX}"/bin
        -DCMAKE_C_COMPILER="${CC_FOR_BUILD}"
        -DCMAKE_C_COMPILER="${CC_FOR_BUILD}"
        -DCMAKE_CXX_COMPILER="${CXX_FOR_BUILD}"
        -DZIG_SHARED_LLVM=ON
        -DZIG_USE_LLVM_CONFIG=ON
        -DZIG_TARGET_TRIPLE=x86_64-linux-gnu
        -DZIG_TARGET_MCPU=native
        -DZIG_SYSTEM_LIBCXX=stdc++
        -DZIG_SINGLE_THREADED=OFF
      )

      # For some reason using the defined CMAKE_ARGS makes the build fail
      USE_CMAKE_ARGS=0

      # When using installed c++ libs, zig needs libzigcpp.a
      configure_cmake_zigcpp "${stage1_build_dir}" "${cmake_install_dir}" "" "linux-64"
      perl -pi -e "s#$PREFIX/lib#$BUILD_PREFIX/lib#g; s#\\\$PREFIX/lib#\\\$BUILD_PREFIX/lib#g" "${stage1_build_dir}"/config.h
 
      cd "${stage1_build_dir}"
      "${BUILD_PREFIX}/bin/zig" build \
        --prefix "${stage1_build_dir}" \
        --search-prefix "${BUILD_PREFIX}" \
        --search-prefix "${BUILD_PREFIX}/lib" \
        --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
        -Dconfig_h="${stage1_build_dir}"/config.h \
        -Dcpu=native \
        -Denable-llvm \
        -Doptimize=Debug \
        -Dsingle-threaded=false \
        -Dskip-debug=true \
        -Dskip-release-fast=true \
        -Dtarget=x86_64-linux-gnu \
        -Duse-zig-libcxx=false \
        -Dversion-string="${PKG_VERSION}"
        # --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
        # --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib" \
      cd -

      # Restore cross-compilation flags for Stage 2
      export CC="${SAVED_CC}"
      export CXX="${SAVED_CXX}"
      export AR="${SAVED_AR}"
      export CFLAGS="${SAVED_CFLAGS}"
      export CXXFLAGS="${SAVED_CXXFLAGS}"
      export LDFLAGS="${SAVED_LDFLAGS}"

      rm -rf "${cmake_install_dir}"/*

      # Set LD_LIBRARY_PATH to find libclang-cpp.so and other shared libraries
      export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
    )
    zig="${stage1_build_dir}/bin/zig"
    "${zig}" version
  fi

EXTRA_CMAKE_ARGS+=(
  -DZIG_SHARED_LLVM=ON
  -DZIG_USE_LLVM_CONFIG=OFF
  -DZIG_TARGET_TRIPLE="${SYSROOT_ARCH}"-linux-gnu
  -DZIG_TARGET_MCPU=baseline
  -DZIG_SYSTEM_LIBCXX=stdc++
  -DZIG_SINGLE_THREADED=OFF
)

# For some reason using the defined CMAKE_ARGS makes the build fail
USE_CMAKE_ARGS=0

# Zig searches for libm.so/libc.so in incorrect paths (libm.so with hard-coded /usr/lib64/libmvec_nonshared.a)
modify_libc_libm_for_zig "${BUILD_PREFIX}"

# Create GCC 14 + glibc 2.28 compatibility library with stub implementations of __libc_csu_init/fini
create_gcc14_glibc28_compat_lib

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}" "" "linux-ppc64le"

# Build LLD libraries locally with -mcmodel=medium for PowerPC64LE
# This solves R_PPC64_REL24 relocation truncation errors that occur when linking
# large binaries (libzigcpp.a 50MB + liblldELF.a 11MB) with conda's pre-built LLD
echo "Building LLD libraries with -mcmodel=medium for PowerPC64LE..."
LLD_BUILD_DIR="${SRC_DIR}/lld-ppc64le-build"
build_lld_ppc64le_mcmodel "${SRC_DIR}/lld-source" "${LLD_BUILD_DIR}" "linux-ppc64le"

# Fix config.h to use shared LLVM linkage (ensures libstdc++.so instead of libstdc++.a)
# CMake sets ZIG_LLVM_LINK_MODE to "static" even with -DZIG_SHARED_LLVM=ON during cross-compilation
perl -pi -e 's/#define ZIG_LLVM_LINK_MODE "static"/#define ZIG_LLVM_LINK_MODE "shared"/g' "${cmake_build_dir}/config.h"

# Clear the static library list when using shared linkage - the build system will use -lLLVM instead
echo "Before LLVM config:"
grep ZIG_LLVM_LIBRARIES "${cmake_build_dir}/config.h"
perl -pi -e 's|#define ZIG_LLVM_LIBRARIES ".*"|#define ZIG_LLVM_LIBRARIES "'${PREFIX}'/lib/libLLVM-20.so;-lz;-lzstd"|g' "${cmake_build_dir}/config.h"
echo "After LLVM config:"
grep ZIG_LLVM_LIBRARIES "${cmake_build_dir}/config.h"

# Replace conda's LLD libraries with our locally-built ones (compiled with -mcmodel=medium)
echo "Replacing conda LLD libraries with locally-built mcmodel=medium versions..."
echo "Before LLD config:"
grep ZIG_LLD_LIBRARIES "${cmake_build_dir}/config.h" || echo "ZIG_LLD_LIBRARIES not found"

# Build new LLD library list using our locally-built libraries
LLD_LIBS="${LLD_BUILD_DIR}/lib/liblldMinGW.a;${LLD_BUILD_DIR}/lib/liblldELF.a;${LLD_BUILD_DIR}/lib/liblldCOFF.a;${LLD_BUILD_DIR}/lib/liblldWasm.a;${LLD_BUILD_DIR}/lib/liblldMachO.a;${LLD_BUILD_DIR}/lib/liblldCommon.a"
perl -pi -e 's|#define ZIG_LLD_LIBRARIES ".*"|#define ZIG_LLD_LIBRARIES "'"${LLD_LIBS}"'"|g' "${cmake_build_dir}/config.h"

echo "After LLD config (using mcmodel=medium libraries):"
grep ZIG_LLD_LIBRARIES "${cmake_build_dir}/config.h"

# Determine GCC library directory (contains crtbegin.o, crtend.o)
GCC_LIB_DIR=$(dirname "$(find "${BUILD_PREFIX}"/lib/gcc/${SYSROOT_ARCH}-conda-linux-gnu -name "crtbeginS.o" | head -1)")

cat > "${zig_build_dir}"/libc_file << EOF
include_dir=${SYSROOT_PATH}/usr/include
sys_include_dir=${SYSROOT_PATH}/usr/include
crt_dir=${SYSROOT_PATH}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${GCC_LIB_DIR}
EOF

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
# For ppc64le, we need to force use of ld.bfd instead of lld due to relocation issues
EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${SYSROOT_PATH}/lib64
  --search-prefix "${PREFIX}"/lib
  --search-prefix "${SYSROOT_PATH}"/usr/lib
  --search-prefix "${SYSROOT_PATH}"/usr/lib64
  --search-prefix "${BUILD_PREFIX}"/lib/gcc/${SYSROOT_ARCH}-conda-linux-gnu/14.3.0
  --search-prefix "${BUILD_PREFIX}"/${SYSROOT_ARCH}-conda-linux-gnu/lib
  -Dconfig_h=${cmake_build_dir}/config.h
  -Denable-llvm
  -Doptimize=ReleaseSafe
  -Duse-llvm=true
  -Duse-zig-libcxx=false
  -Dsingle-threaded=false
  -Dstrip=false
  -Dtarget=${ZIG_ARCH}-linux-gnu
  -Dcpu=baseline
)

#  -Ddev=powerpc-linux
#  -Doptimize=Debug
#  --verbose-link
#  --verbose-llvm-ir=/tmp/llvm-ir-output.txt
#  --verbose
#  --verbose-cc

ln -sf "$(which qemu-ppc64le-static)" "${BUILD_PREFIX}/bin/qemu-ppc64le"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

remove_failing_langref "${zig_build_dir}"

# Create pthread_atfork stub for glibc 2.28 PowerPC64LE
# glibc 2.28 for ppc64le doesn't export pthread_atfork symbol
echo "=== Creating pthread_atfork stub for glibc 2.28 PowerPC64LE ==="
cat > "${SRC_DIR}/pthread_atfork_stub.c" << 'EOF'
// Weak stub for pthread_atfork when glibc 2.28 doesn't provide it
__attribute__((weak))
int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    // Stub implementation - returns success without doing anything
    // This is safe because we're not actually using fork() in the Zig compiler
    (void)prepare; (void)parent; (void)child;
    return 0;  // Success
}
EOF

${CC} -c "${SRC_DIR}/pthread_atfork_stub.c" -o "${SRC_DIR}/pthread_atfork_stub.o"

echo "=== STAGE 2: Building PowerPC64LE Zig using Stage 1 ==="
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
