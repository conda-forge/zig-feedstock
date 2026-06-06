#!/usr/bin/env bash
# Build LLVM with zig cc for zig-llvmdev package
# This produces LLVM/Clang/LLD shared libraries with libc++ ABI
# compatible with zig-cc-built zigcpp
# BUILD_SCRIPT_VERSION=2026-04-27b

set -euxo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source ${RECIPE_DIR}/llvm/building/post-install.sh
source ${RECIPE_DIR}/llvm/building/remove-unneeded.sh
source ${RECIPE_DIR}/llvm/building/strip_atexit_from_implib.sh
source ${RECIPE_DIR}/llvm/building/_lld_bundle.sh

source ${RECIPE_DIR}/llvm/building/_env.sh
source ${RECIPE_DIR}/llvm/building/_cross_compile.sh
source ${RECIPE_DIR}/llvm/building/_zig_wrappers.sh
source ${RECIPE_DIR}/llvm/building/_cmake_flags.sh

# --------------------------------------------------------------------
# Workaround: zig-zstd / zig-zlib / zig-libxml2 ship cmake config files
# (zstdConfig.cmake etc.) that declare INTERFACE_INCLUDE_DIRECTORIES
# pointing at $PREFIX/lib/zig-<pkg>/include. The packages create the
# parent dir but not always the include subdir. CMake validates
# imported-target include paths at configure time and aborts with
# 'Imported target zstd::libzstd_shared includes non-existent path'
# if the directory is missing.
#
# We ensure the dir exists AND drop a .keep file so the directory is
# non-empty (prevents any later cleanup from removing it). The mkdir
# is unconditional — idempotent and cheap. If headers are truly
# needed, missing-header errors will surface at compile time; if not,
# the empty-but-present dir is harmless.
# --------------------------------------------------------------------
for _zigdep in zig-zstd zig-zlib zig-libxml2; do
    if [[ -d "${PREFIX}/lib/${_zigdep}" ]]; then
        mkdir -p "${PREFIX}/lib/${_zigdep}/include"
        : > "${PREFIX}/lib/${_zigdep}/include/.keep"
        echo "  workaround: ensured ${PREFIX}/lib/${_zigdep}/include (with .keep)"
    else
        echo "  workaround: parent ${PREFIX}/lib/${_zigdep} not found, skipping"
    fi
done
unset _zigdep

source ${RECIPE_DIR}/llvm/building/_runtimes_build.sh
source ${RECIPE_DIR}/llvm/building/_llvm_build.sh
source ${RECIPE_DIR}/llvm/building/_post_build.sh
