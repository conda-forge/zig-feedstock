#!/usr/bin/env bash
# Build xml2 with zig cc for zig toolchain
set -euxo pipefail

echo "=== Building zig-xml2 with zig cc ==="

# Clear conda compiler flags - zig handles everything
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

mkdir -p build
cd build

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${PREFIX}/lib/zig-zlib;${PREFIX}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}/lib/zig-libxml2" \
    -DCMAKE_C_COMPILER="${ZIG_CC}" \
    -DCMAKE_AR="${ZIG_AR}" \
    -DCMAKE_RANLIB="${ZIG_RANLIB}" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBXML2_WITH_ICONV=OFF \
    -DLIBXML2_WITH_xml2=ON \
    -G Ninja

# Build only the shared library target, not tests
cmake --build . -j"${CPU_COUNT}"

# Manual install - cmake --install expects static lib which we didn't build
mkdir -p "${PREFIX}/lib/zig-libxml2/lib"
cp -P libxml2.so* "${PREFIX}/lib/zig-libxml2/lib/"
