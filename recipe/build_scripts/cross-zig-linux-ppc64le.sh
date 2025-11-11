#!/usr/bin/env bash
set -euxo pipefail

# --- Functions ---

source "${RECIPE_DIR}/build_scripts/_functions.sh"

# --- Main ---

export ZIG_GLOBAL_CACHE_DIR="${PWD}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${PWD}/zig-local-cache"

# Set up logging FIRST to capture all output
mkdir -p "${SRC_DIR}/build-logs"
LOG_FILE="${SRC_DIR}/build-logs/ppc64le-build-$(date +%Y%m%d-%H%M%S).log"
echo "Capturing all build output to ${LOG_FILE}" | tee "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

cmake_build_dir="${SRC_DIR}/build-release"
cmake_install_dir="${SRC_DIR}/cmake-built-install"
zig_build_dir="${SRC_DIR}/conda-zig-source"

mkdir -p "${cmake_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
mkdir -p "${zig_build_dir}" && cp -r "${SRC_DIR}"/zig-source/* "${zig_build_dir}"
mkdir -p "${cmake_install_dir}"
mkdir -p "${SRC_DIR}"/build-level-patches
cp -r "${RECIPE_DIR}"/patches/xxxx* "${SRC_DIR}"/build-level-patches

# STAGE 1: Build x86_64 Zig with PowerPC64LE patches for use as bootstrap compiler
echo "=== STAGE 1: Building x86_64 Zig with PowerPC64LE support ==="
stage1_build_dir="${SRC_DIR}/stage1-x86_64"
stage1_zig="${stage1_build_dir}/bin/zig"
(

  mkdir -p "${stage1_build_dir}"
  cp -r "${SRC_DIR}"/zig-source/* "${stage1_build_dir}"
  remove_failing_langref "${stage1_build_dir}"

  # Build native x86_64 Zig with patches applied (patches already applied during source extraction)
  # Need to build with LLVM support for proper cross-compilation
  # Save cross-compilation flags and clear them for native build
  SAVED_CFLAGS="${CFLAGS}"
  SAVED_CXXFLAGS="${CXXFLAGS}"
  SAVED_LDFLAGS="${LDFLAGS}"
  SAVED_PATH="${PATH}"

  export CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem $BUILD_PREFIX/include"
  export CPPFLAGS="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2 -isystem $BUILD_PREFIX/include"
  export CXXFLAGS="-fvisibility-inlines-hidden -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem $BUILD_PREFIX/include"
  export LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined -Wl,-rpath,$BUILD_PREFIX/lib -Wl,-rpath-link,$BUILD_PREFIX/lib -L$BUILD_PREFIX/lib"

  EXTRA_CMAKE_ARGS+=(
    -DCMAKE_PREFIX_PATH="${BUILD_PREFIX}"/bin
    -DCMAKE_C_COMPILER="${CC_FOR_BUILD}"
    -DCMAKE_C_COMPILER="${CC_FOR_BUILD}"
    -DCMAKE_CXX_COMPILER="${CXX_FOR_BUILD}"
    -DZIG_SHARED_LLVM=ON
    -DZIG_USE_LLVM_CONFIG=ON
    -DZIG_TARGET_TRIPLE=x86_64-linux-gnu
    -DZIG_TARGET_MCPU=baseline
    -DZIG_SYSTEM_LIBCXX=stdc++
  )
  #  "-DZIG_SINGLE_THREADED=ON"

  # For some reason using the defined CMAKE_ARGS makes the build fail
  USE_CMAKE_ARGS=0

  # When using installed c++ libs, zig needs libzigcpp.a
  configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"
  
  cd "${stage1_build_dir}"
  "${BUILD_PREFIX}/bin/zig" build \
    --prefix "${stage1_build_dir}" \
    --search-prefix "${BUILD_PREFIX}" \
    --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
    -Dconfig_h=${cmake_build_dir}/config.h \
    -Doptimize=ReleaseFast \
    -Dskip-release-fast=true \
    -Denable-llvm \
    -Dtarget=x86_64-linux-gnu \
    -Dversion-string="${PKG_VERSION}"
    # --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib64" \
    # --search-prefix "${BUILD_PREFIX}/x86_64-conda-linux-gnu/sysroot/usr/lib" \
  cd -

  # Restore cross-compilation flags for Stage 2
  export CFLAGS="${SAVED_CFLAGS}"
  export CXXFLAGS="${SAVED_CXXFLAGS}"
  export LDFLAGS="${SAVED_LDFLAGS}"

  rm -rf "${cmake_build_dir}"/* "${cmake_install_dir}"/* && cp -r "${SRC_DIR}"/zig-source/* "${cmake_build_dir}"
  
  echo "Stage 1 Zig built at: ${stage1_zig}"
  "${stage1_zig}" version
)

# Now set up PowerPC64LE cross-compilation environment for Stage 2
SYSROOT_ARCH="powerpc64le"
SYSROOT_PATH="${BUILD_PREFIX}/${SYSROOT_ARCH}-conda-linux-gnu/sysroot"
TARGET_INTERPRETER="${SYSROOT_PATH}/lib64/ld-2.28.so"
ZIG_ARCH="powerpc64le"

# Add ld.bfd for relocation issue
export CFLAGS="${CFLAGS} -fuse-ld=bfd"
export CXXFLAGS="${CXXFLAGS} -fuse-ld=bfd"
export LDFLAGS="${LDFLAGS} -fuse-ld=bfd"

echo "Stage 1 Zig built at: ${stage1_zig}"
"${stage1_zig}" version

# Use stage 1 Zig for cross-compilation
zig="${stage1_zig}"

EXTRA_CMAKE_ARGS+=(
  "-DZIG_SHARED_LLVM=ON"
  "-DZIG_USE_LLVM_CONFIG=OFF"
  "-DZIG_TARGET_TRIPLE=${SYSROOT_ARCH}-linux-gnu"
  "-DZIG_TARGET_MCPU=baseline"
  "-DZIG_SYSTEM_LIBCXX=stdc++"
)
#  "-DZIG_SINGLE_THREADED=ON"

# For some reason using the defined CMAKE_ARGS makes the build fail
USE_CMAKE_ARGS=0

# When using installed c++ libs, zig needs libzigcpp.a
configure_cmake_zigcpp "${cmake_build_dir}" "${cmake_install_dir}"

cat > "${zig_build_dir}"/libc_file << EOF
include_dir=${SYSROOT_PATH}/usr/include
sys_include_dir=${SYSROOT_PATH}/usr/include
crt_dir=${SYSROOT_PATH}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

# Zig needs the config.h to correctly (?) find the conda installed llvm, etc
# For ppc64le, we need to force use of ld.bfd instead of lld due to relocation issues
EXTRA_ZIG_ARGS+=(
  -fqemu
  --libc "${zig_build_dir}"/libc_file
  --libc-runtimes ${SYSROOT_PATH}/lib64
  -Dconfig_h=${cmake_build_dir}/config.h
  -Dstatic-llvm
  -Duse-zig-libcxx=false
  -Dtarget=${ZIG_ARCH}-linux-gnu
  -Dcpu=baseline
)
#  "-Dstrip"

ln -sf "$(which qemu-ppc64le-static)" "${BUILD_PREFIX}/bin/qemu-ppc64le"
export QEMU_LD_PREFIX="${SYSROOT_PATH}"
export QEMU_SET_ENV="LD_LIBRARY_PATH=${SYSROOT_PATH}/lib64:${LD_LIBRARY_PATH:-}"

remove_failing_langref "${zig_build_dir}"

echo "=== STAGE 2: Building PowerPC64LE Zig using Stage 1 ==="
build_zig_with_zig "${SRC_DIR}/conda-zig-source" "${zig}" "${PREFIX}"
