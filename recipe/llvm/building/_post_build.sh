echo "=== Pre-install disk cleanup: removing build object files ==="
echo "  Disk before .o cleanup:"
df -h "${SRC_DIR}" || true
find "${LLVM_BUILD}" -name "*.o" -delete 2>/dev/null || true
find "${LLVM_BUILD}" -name "*.obj" -delete 2>/dev/null || true
echo "  Disk after .o cleanup:"
df -h "${SRC_DIR}" || true

echo "=== Installing LLVM ==="
cmake --install "${LLVM_BUILD}"

# Install tablegen tools (not installed by cmake --install, but needed for cross-compilation)
# These are host-arch binaries that run on the build machine to generate .inc files.
echo "=== Installing tablegen tools ==="
for _tbl in llvm-tblgen clang-tblgen llvm-min-tblgen; do
  if [[ -x "${LLVM_BUILD}/bin/${_tbl}" ]]; then
    cp -v "${LLVM_BUILD}/bin/${_tbl}" "${LLVM_INSTALL}/bin/"
  fi
done

if [[ "${ZIG_LLVM_SKIP_BUILD:-}" == "0" ]]; then
  echo "=== Populating the cache ==="
  mkdir -p ${RECIPE_DIR}/cache && rm -rf ${RECIPE_DIR}/cache/*
  cp -r ${PREFIX}/lib/zig-llvm/* ${RECIPE_DIR}/cache/
fi

build_lld_bundle
remove_unneeded
post_install
fix_lld_cmake_deps

# Verify llvm-config --system-libs includes zlib/zstd (native builds only)
if ! is_cross; then
  echo "=== Verifying llvm-config --system-libs ==="
  # Use the real binary, not the wrapper (wrapper only filters ld flags, not libs)
  _real_config="${LLVM_INSTALL}/bin/llvm-config.real"
  [[ -f "${_real_config}.exe" ]] && _real_config="${_real_config}.exe"
  if [[ -x "${_real_config}" ]]; then
    _system_libs=$("${_real_config}" --system-libs 2>/dev/null || true)
    echo "  system-libs: ${_system_libs}"
    if ! echo "${_system_libs}" | grep -q '\-lz'; then
      echo "  WARNING: llvm-config --system-libs missing -lz (LLVM_ENABLE_ZLIB=ON)"
    fi
    if is_unix && ! echo "${_system_libs}" | grep -q '\-lzstd'; then
      echo "  WARNING: llvm-config --system-libs missing -lzstd (LLVM_ENABLE_ZSTD=ON)"
    fi
  else
    dbg "llvm-config.real not executable, skipping system-libs verification"
  fi
fi

echo "=== zig-llvm build complete ==="

# Create a marker file for zig build to find this LLVM
echo "${LLVM_INSTALL}" > "$(dirname "${LLVM_INSTALL}")/zig-llvm-path.txt"

