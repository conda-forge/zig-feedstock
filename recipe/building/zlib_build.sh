#!/usr/bin/env bash
# Build zlib with zig cc for zig toolchain
set -euxo pipefail

echo "=== Building zig-zlib with zig cc ==="

# Clear conda compiler flags - zig handles everything
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

mkdir -p build
cd build

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}/lib/zig-zlib" \
    -DCMAKE_C_COMPILER="${ZIG_CC}" \
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
    -DCMAKE_C_COMPILER_TARGET="${ZIG_TRIPLET}" \
    -DCMAKE_CXX_COMPILER_TARGET="${ZIG_TRIPLET}" \
    -DCMAKE_ASM_COMPILER="${ZIG_ASM}" \
    -DCMAKE_ASM_COMPILER_TARGET="${ZIG_TRIPLET}" \
    -DCMAKE_AR="${ZIG_AR}" \
    -DCMAKE_RANLIB="${ZIG_RANLIB}" \
    -DBUILD_SHARED_LIBS=ON \
    -DZLIB_BUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF\
    -G Ninja

# Build only the shared library target, not tests
cmake --build . -j"${CPU_COUNT}" --target zlib

# Manual install - cmake --install expects static lib which we didn't build
mkdir -p "${PREFIX}/lib/zig-zlib/lib"
cp -P libz.so* "${PREFIX}/lib/zig-zlib/lib/"
