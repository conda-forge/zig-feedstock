# CMake Configuration and Build Helpers for Zig Compilation
#
# NOTE: the full-cmake compiler-build path (cmake_build / cmake_host_build /
# apply_cmake_patches / cmake_build_install / _zig_compute_triple_from_uname)
# was removed once riscv64 stopped needing CMAKE_BUILD=1 fallback (all
# platforms build via build_zig_with_zig). configure_cmake / configure_cmake_zigcpp
# (the zigcpp shim cmake build, used on every platform) live in _build.sh and
# are unaffected.

source "${RECIPE_DIR}/building/_common.sh"
