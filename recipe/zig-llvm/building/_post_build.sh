echo "=== Pre-install disk cleanup: removing build object files ==="
if [[ -f "${SRC_DIR}/.zig_local_iterate" ]]; then
  echo "  .zig_local_iterate sentinel present: preserving ${LLVM_BUILD} object files for incremental local rebuilds (ninja will reuse them on the next 'rattler-build debug run')"
else
  find "${LLVM_BUILD}" -name "*.o" -delete 2>/dev/null || true
  find "${LLVM_BUILD}" -name "*.obj" -delete 2>/dev/null || true
fi

echo "=== Installing LLVM ==="
cmake --install "${LLVM_BUILD}"

# Self-heal: the combined LLVM dylib can be silently dropped by the blanket
# cmake --install above — same failure class as the llvm-config gap already
# self-healed in remove_unneeded() (recipe/zig-llvm/building/remove-unneeded.sh,
# 2026-07-26 incident: neither llvm-config nor llvm-config.exe existed post-install).
# Undetected here it surfaces ~2h later on win-64 as zig's own zigcpp CMake
# configure failing with "llvm-config: error: libLLVM-21.dll is missing" /
# cmake/Findllvm.cmake reporting it "does not support linking as a shared
# library". build_lld_bundle (called below) also hard-depends on
# libLLVM-*.dll.a already being present in ${LLVM_INSTALL}/lib, so this check
# must run here — before that call — not inside remove_unneeded(). Resolve
# the actual filename via glob instead of hardcoding the LLVM major version
# (no LLVM-major shell variable is in scope; mirrors the glob-resolution
# idiom _lld_bundle.sh already uses for the same libLLVM-*.dll.a artifact).
# Windows-only: the .dll/.dll.a naming and the win-64 zigcpp failure mode
# this guards against only apply to that platform.
if [[ "${target_platform}" == win-* ]]; then
  _llvm_dll=$(ls "${LLVM_INSTALL}"/bin/libLLVM-*.dll 2>/dev/null | head -n1)
  _llvm_implib=$(ls "${LLVM_INSTALL}"/lib/libLLVM-*.dll.a 2>/dev/null | head -n1)
  if [[ -z "${_llvm_dll}" || ! -f "${_llvm_dll}" || -z "${_llvm_implib}" || ! -f "${_llvm_implib}" ]]; then
    echo "  WARNING: combined LLVM dylib missing from ${LLVM_INSTALL} after the main install; forcing an explicit rebuild" >&2
    cmake --build "${LLVM_BUILD}" --target LLVM -j"${CPU_COUNT}"
    cmake --install "${LLVM_BUILD}" --component LLVM
    _llvm_dll=$(ls "${LLVM_INSTALL}"/bin/libLLVM-*.dll 2>/dev/null | head -n1)
    _llvm_implib=$(ls "${LLVM_INSTALL}"/lib/libLLVM-*.dll.a 2>/dev/null | head -n1)
  fi
  if [[ -z "${_llvm_dll}" || ! -f "${_llvm_dll}" || -z "${_llvm_implib}" || ! -f "${_llvm_implib}" ]]; then
    echo "FATAL: combined LLVM dylib still missing at ${LLVM_INSTALL} after explicit rebuild" >&2
    exit 1
  fi
  echo "  OK: combined LLVM dylib present (${_llvm_dll}, ${_llvm_implib})"
fi

# Install tablegen tools (not installed by cmake --install, but needed for cross-compilation)
# These are host-arch binaries that run on the build machine to generate .inc files.
echo "=== Installing tablegen tools ==="
for _tbl in llvm-tblgen clang-tblgen llvm-min-tblgen; do
  if [[ -x "${LLVM_BUILD}/bin/${_tbl}" ]]; then
    cp -v "${LLVM_BUILD}/bin/${_tbl}" "${LLVM_INSTALL}/bin/"
  fi
done

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

