#!/usr/bin/env bash

set -ex

mkdir -p build
cd build

if [[ "$(uname -s)" == "Darwin" ]]; then
  EXTRA_CMAKE_ARGS="$EXTRA_CMAKE_ARGS -DZIG_STATIC_LLVM=ON"
fi

cmake \
  -DCMAKE_INSTALL_PREFIX=${PREFIX} \
  -DCMAKE_PREFIX_PATH=${PREFIX} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=${CC} \
  -DCMAKE_CXX_COMPILER=${CXX} \
  -DCMAKE_CXX_FLAGS="-fuse-ld=lld" \
  ${EXTRA_CMAKE_ARGS} \
  ..

cmake --build .
cmake --install . -v
