mkdir build
cd build

cmake $CMAKE_ARGS -GNinja $SRC_DIR/zig-source

ninja install