mkdir build
cd build

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
    CMAKE_ARGS="$CMAKE_ARGS -DZIG_USE_LLVM_CONFIG=OFF"
fi

cmake -GNinja $CMAKE_ARGS $SRC_DIR/zig-source
     
ninja install