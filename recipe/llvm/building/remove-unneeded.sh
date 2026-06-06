function remove_unneeded() {
  # Remove static libraries - zig only needs shared libs (saves ~500MB)
  # Keep .dll.a import libraries on Windows (needed to link against DLLs)
  # liblld*.a are bundled into liblldZig.so/.dylib/.dll by build_lld_bundle
  # and are no longer needed as standalone archives.
  echo "=== Removing static libraries ==="
  find "${LLVM_INSTALL}/lib" -name "*.a" ! -name "*.dll.a" -type f -delete
  echo "  Removed .a files from ${LLVM_INSTALL}/lib (kept .dll.a import libs; liblld*.a replaced by liblldZig bundle)"

  # Explicitly remove C++ runtime static archives (libc++, libc++abi, libc++experimental,
  # libunwind). These are installed by the runtimes build and must not ship — zig consumers
  # must link against the shared dylib/so, not a static copy. Use rm -f (idempotent).
  _cxx_static_removed=0
  for _f in \
      "${LLVM_INSTALL}/lib/libc++.a" \
      "${LLVM_INSTALL}/lib/libc++abi.a" \
      "${LLVM_INSTALL}/lib/libc++experimental.a" \
      "${LLVM_INSTALL}/lib/libunwind.a"; do
    if [[ -f "${_f}" ]]; then
      rm -f "${_f}"
      (( _cxx_static_removed++ )) || true
    fi
  done
  # Glob-catch any remaining libc++*.a / libunwind*.a variants
  for _f in "${LLVM_INSTALL}/lib/libc++"*.a "${LLVM_INSTALL}/lib/libunwind"*.a; do
    [[ "${_f}" == *.dll.a ]] && continue
    if [[ -f "${_f}" ]]; then
      rm -f "${_f}"
      (( _cxx_static_removed++ )) || true
    fi
  done
  echo "  Removed ${_cxx_static_removed} C++ runtime static archive(s) from ${LLVM_INSTALL}/lib"

  # Remove all tools except llvm-config (other tools come from conda-forge llvm-tools)
  # Many LLVM tools are symlinks, so delete both files and symlinks
  # On Windows, keep DLLs in bin/ (cmake installs .dll runtime there)
  echo "=== Removing tools except llvm-config ==="
  # llvm-dlltool is a symlink to llvm-ar — resolve it to a standalone copy before deleting llvm-ar
  if [[ -L "${LLVM_INSTALL}/bin/llvm-dlltool" ]]; then
    _target="$(readlink -f "${LLVM_INSTALL}/bin/llvm-dlltool")"
    rm "${LLVM_INSTALL}/bin/llvm-dlltool"
    cp "${_target}" "${LLVM_INSTALL}/bin/llvm-dlltool"
  fi
  find "${LLVM_INSTALL}/bin" \( -type f -o -type l \) ! \( -name "llvm-config*" -o -name "*-tblgen" -o -name "*-tblgen.exe" -o -name "llvm-dlltool*" -o -name "*.dll" \) -delete
  ls "${LLVM_INSTALL}/bin/"
  echo "  Kept llvm-config, llvm-dlltool, tblgen (and DLLs on Windows) in ${LLVM_INSTALL}/bin"

  # Remove share/ directory (clang-format helpers, cmake modules we don't need)
  echo "=== Removing share/ directory ==="
  rm -rf "${LLVM_INSTALL}/share"
  echo "  Removed ${LLVM_INSTALL}/share"

  # Remove C API headers (zig uses C++ API, not C bindings)
  # echo "=== Removing C API headers ==="
  # rm -rf "${LLVM_INSTALL}/include/llvm-c"
  # rm -rf "${LLVM_INSTALL}/include/clang-c"
  # echo "  Removed llvm-c/ and clang-c/ headers"

  # Remove Clang builtin headers (zig bundles its own libc headers)
  # echo "=== Removing Clang builtin headers ==="
  # rm -rf "${LLVM_INSTALL}/lib/clang"
  # echo "  Removed lib/clang/"

  # Create llvm-config wrapper that filters out flags unsupported by zig's linker
  # zig build calls llvm-config --ldflags and passes results directly to its linker
  # Flags like -Bsymbolic-functions are GNU ld specific and not supported by lld/zig linker
  echo "=== Creating llvm-config wrapper to filter unsupported linker flags ==="
  # Rename the real binary: ensure .exe on Windows (cross-compile may omit it)
  if [[ -f "${LLVM_INSTALL}/bin/llvm-config.exe" ]]; then
    mv "${LLVM_INSTALL}/bin/llvm-config.exe" "${LLVM_INSTALL}/bin/llvm-config.real.exe"
  elif [[ "${target_platform}" == win-* ]]; then
    # Cross-compiled PE binary without .exe — add extension
    mv "${LLVM_INSTALL}/bin/llvm-config" "${LLVM_INSTALL}/bin/llvm-config.real.exe"
  else
    mv "${LLVM_INSTALL}/bin/llvm-config" "${LLVM_INSTALL}/bin/llvm-config.real"
  fi
  cat > "${LLVM_INSTALL}/bin/llvm-config" << 'WRAPPER_EOF'
#!/bin/sh
# Wrapper for llvm-config that filters out flags unsupported by zig's linker
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Ensure llvm-config.real can find libunwind.so.1 and libc++.so from zig-llvm runtimes
export LD_LIBRARY_PATH="${SCRIPT_DIR}/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Find llvm-config.real: try .exe first (Windows), then without
if [ -f "${SCRIPT_DIR}/llvm-config.real.exe" ]; then
  REAL_CONFIG="${SCRIPT_DIR}/llvm-config.real.exe"
else
  REAL_CONFIG="${SCRIPT_DIR}/llvm-config.real"
fi

# Run the real llvm-config — propagate exit code on failure
output="$("${REAL_CONFIG}" "$@" 2>&1)"
rc=$?
if [ $rc -ne 0 ]; then
  echo "llvm-config wrapper: ${REAL_CONFIG} failed (rc=$rc)" >&2
  echo "${output}" >&2
  exit 1
fi

# Filter output for --ldflags and --system-libs which may contain unsupported flags
for arg in "$@"; do
  case "$arg" in
    --ldflags|--system-libs|--libs|--link-static|--link-shared)
      # Filter out GNU ld specific flags that zig's linker doesn't support
      output=$(echo "$output" | sed \
        -e 's/-Wl,-Bsymbolic-functions//g' \
        -e 's/-Bsymbolic-functions//g' \
        -e 's/-Wl,-Bsymbolic//g' \
        -e 's/-Bsymbolic//g' \
        -e 's/-Wl,--disable-new-dtags//g' \
        -e 's/  */ /g' \
        -e 's/^ *//' \
        -e 's/ *$//')
      break
      ;;
  esac
done

echo "$output"
WRAPPER_EOF
  chmod +x "${LLVM_INSTALL}/bin/llvm-config"
  echo "  Created wrapper: ${LLVM_INSTALL}/bin/llvm-config"
}
