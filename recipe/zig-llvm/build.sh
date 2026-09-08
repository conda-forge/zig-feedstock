source "${LLVM_RECIPE_DIR}"/building/_env.sh

source "${LLVM_RECIPE_DIR}"/building/post-install.sh
source "${LLVM_RECIPE_DIR}"/building/remove-unneeded.sh
source "${LLVM_RECIPE_DIR}"/building/strip_atexit_from_implib.sh
source "${LLVM_RECIPE_DIR}"/building/_lld_bundle.sh

source "${LLVM_RECIPE_DIR}"/building/_cross_compile.sh
source "${LLVM_RECIPE_DIR}"/building/_zig_wrappers.sh
source "${LLVM_RECIPE_DIR}"/building/_cmake_flags.sh

for _zigdep in zig-zstd zig-zlib zig-libxml2; do
    if [[ -d "${PREFIX}/lib/${_zigdep}" ]]; then
        mkdir -p "${PREFIX}/lib/${_zigdep}/include"
        : > "${PREFIX}/lib/${_zigdep}/include/.keep"
    else
        echo "  workaround: parent ${PREFIX}/lib/${_zigdep} not found, skipping"
    fi
done
unset _zigdep

# Build a self-sufficient BUILD-arch llvm-config from THIS build's LLVM source. Defined
# here but NOT called yet: _runtimes_build.sh (PART 1, native build-arch libc++, sourced
# next) must complete first, because build_native_llvm_config's zig-cxx configure step
# needs a runnable build-arch libc++ already staged (else it dyld-fails resolving
# @rpath/libc++.1.dylib on unix cross, e.g. osx-64). The native libc++ build itself does
# NOT consume LLVM_CONFIG_PATH; only the later target runtimes build
# (_runtimes_target.sh, PART 2) does, via the LLVM_CONFIG_PATH this function stages.
# Replaces reliance on the zig_impl_${build_platform} build-dep for llvm-config on unix
# cross lanes.
source "${LLVM_RECIPE_DIR}"/building/_native_llvm_config.sh

source "${LLVM_RECIPE_DIR}"/building/_runtimes_build.sh

# native build-arch libc++ is now staged (above); llvm-config can link+run against it.
# Fail fast: an unchecked failure here otherwise rides ~90min to build-zig.sh's llvm-config FATAL.
build_native_llvm_config || exit 1

source "${LLVM_RECIPE_DIR}"/building/_runtimes_target.sh
source "${LLVM_RECIPE_DIR}"/building/_llvm_build.sh
source "${LLVM_RECIPE_DIR}"/building/_post_build.sh
