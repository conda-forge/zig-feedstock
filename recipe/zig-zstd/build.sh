#!/usr/bin/env bash
# Build zstd with zig cc for zig toolchain
set -euxo pipefail

echo "=== Building zig-zstd with zig cc ==="

# Clear conda compiler flags - zig handles everything
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

mkdir -p build
cd build

# zstd CMake is in build/cmake subdirectory
cmake ../build/cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}/lib/zig-zstd" \
    -DCMAKE_C_COMPILER="${ZIG_CC}" \
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
    -DCMAKE_AR="${ZIG_AR}" \
    -DCMAKE_RANLIB="${ZIG_RANLIB}" \
    -DZSTD_BUILD_SHARED=ON \
    -DZSTD_BUILD_STATIC=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_BUILD_CONTRIB=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=ON \
    -G Ninja

cmake --build . -j"${CPU_COUNT}"

# Manual install - cmake --install expects static lib which we didn't build
mkdir -p "${PREFIX}/lib/zig-zstd/lib"
cp -P lib/libzstd.so* "${PREFIX}/lib/zig-zstd/lib/"
# cmake --install .
