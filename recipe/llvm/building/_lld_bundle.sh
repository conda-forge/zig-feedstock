function build_lld_bundle() {
  set -x  # DIAGNOSTIC: trace all commands to stderr
  # Bundle prebuilt liblld*.a archives into a platform-native shared library.
  #
  # Rationale: consumers (zig-zig) that link the individual lld static archives
  # must carry all six archives plus their transitive LLVM/zlib/zstd/xml2 deps
  # in the right order.  Bundling them into a single shared library (liblldZig)
  # resolves all intra-lld and lld→LLVM symbol references inside the bundle;
  # consumers link one -llldZig instead of six archives.
  #
  # Outputs:
  #   Linux:   ${LLVM_INSTALL}/lib/liblldZig.so
  #   macOS:   ${LLVM_INSTALL}/lib/liblldZig.dylib
  #   Windows: ${LLVM_INSTALL}/bin/liblldZig.dll
  #            ${LLVM_INSTALL}/lib/liblldZig.dll.a  (import lib)

  echo "=== Building liblldZig bundle for ${target_platform} ==="

  # No conda-forge zstd/xml2/z packages for riscv64/s390x — skip the bundle.
  # zig consumers on these platforms link the static .a archives directly.
  if [[ "${target_platform:-}" == "linux-riscv64" || "${target_platform:-}" == "linux-s390x" ]]; then
    echo "  Skipping liblldZig.so for ${target_platform} (no conda-forge zstd/xml2/z available)"
    return 0
  fi

  local _lld_lib="${LLVM_INSTALL}/lib"

  # Verify all six archives are present before attempting the link.
  local _missing=0
  for _a in liblldELF.a liblldCOFF.a liblldMachO.a liblldWasm.a liblldMinGW.a liblldCommon.a; do
    if [[ ! -f "${_lld_lib}/${_a}" ]]; then
      echo "  ERROR: ${_lld_lib}/${_a} not found" >&2
      _missing=$(( _missing + 1 ))
    fi
  done
  if [[ ${_missing} -ne 0 ]]; then
    echo "  ABORT: ${_missing} liblld*.a archive(s) missing from ${_lld_lib}" >&2
    return 1
  fi
  echo "  All 6 liblld*.a archives present in ${_lld_lib}"

  if is_linux; then
    local _out="${_lld_lib}/liblldZig.so"
    # Pass -target so zig-cc links for TARGET arch, not the build-host arch.
    # On native (linux-64) this is a no-op; on cross (aarch64, ppc64le, …) it
    # prevents ld.lld rejecting TARGET .a members as "incompatible with elf_x86_64".
    # Use ZIG_TRIPLET (the glibc-floored triple, e.g. aarch64-linux-gnu.2.17) so the
    # bundle's libc symbol versions match those required by the final self-hosted zig build.
    "${ZIG_CXX}" -target "${ZIG_TRIPLET}" -shared -fPIC \
      -Wl,--whole-archive \
        "${_lld_lib}/liblldELF.a" \
        "${_lld_lib}/liblldCOFF.a" \
        "${_lld_lib}/liblldMachO.a" \
        "${_lld_lib}/liblldWasm.a" \
        "${_lld_lib}/liblldMinGW.a" \
        "${_lld_lib}/liblldCommon.a" \
      -Wl,--no-whole-archive \
      -Wl,--export-dynamic \
      -Wl,-rpath,'$ORIGIN' \
      -L"${_lld_lib}" \
      -L"${PREFIX}/lib" \
      -L"${PREFIX}/lib/zig-zstd/lib" \
      -L"${PREFIX}/lib/zig-zlib/lib" \
      -L"${PREFIX}/lib/zig-libxml2/lib" \
      "${_lld_lib}/libLLVM-20.so" \
      -lzstd -lxml2 -lz -lpthread \
      -o "${_out}" || {
      echo "  FAILED: linker error building ${_out}" >&2
      return 1
    }
    if [[ ! -f "${_out}" ]]; then
      echo "  FAILED: ${_out} not produced" >&2
      return 1
    fi
    echo "  OK: $(ls -lh "${_out}" | awk '{print $5, $9}')"

  elif is_osx; then
    local _out="${_lld_lib}/liblldZig.dylib"
    # zig-force-load-cxx (ZIG_CXX on macOS) handles -Wl,-force_load by
    # extracting each archive to .o files before linking — no GNU
    # --whole-archive needed.
    "${ZIG_CXX}" -dynamiclib -Wl,-headerpad_max_install_names -fPIC \
      -Wl,-force_load,"${_lld_lib}/liblldELF.a" \
      -Wl,-force_load,"${_lld_lib}/liblldCOFF.a" \
      -Wl,-force_load,"${_lld_lib}/liblldMachO.a" \
      -Wl,-force_load,"${_lld_lib}/liblldWasm.a" \
      -Wl,-force_load,"${_lld_lib}/liblldMinGW.a" \
      -Wl,-force_load,"${_lld_lib}/liblldCommon.a" \
      -install_name "@loader_path/liblldZig.dylib" \
      -L"${_lld_lib}" \
      -L"${PREFIX}/lib" \
      -lLLVM \
      -lzstd -lxml2 -lz \
      -o "${_out}" || {
      echo "  FAILED: linker error building ${_out}" >&2
      return 1
    }
    if [[ ! -f "${_out}" ]]; then
      echo "  FAILED: ${_out} not produced" >&2
      return 1
    fi
    echo "  OK: $(ls -lh "${_out}" | awk '{print $5, $9}')"

  elif is_not_unix; then
    # DIAGNOSTIC: log environment before Windows build
    echo "DEBUG: target_platform=${target_platform:-unset} ZIG_CXX=${ZIG_CXX:-unset} LLVM_INSTALL=${LLVM_INSTALL:-unset} _lld_lib=${_lld_lib:-unset}" >&2
    local _out="${LLVM_INSTALL}/bin/liblldZig.dll"
    local _implib="${_lld_lib}/liblldZig.dll.a"
    # Pass -target so zig-cc links/compiles for the TARGET arch (aarch64-windows-gnu),
    # not the x86_64 build host.  Mirrors the is_linux branch above.  Without it, zig
    # defaults to the build-host triple and, on the VS2022 runner, auto-compiles its OWN
    # bundled libcxxabi (cxa_exception.cpp) against the native MSVC SDK — whose
    # vcruntime_typeinfo.h:137 `using ::type_info` collides with zig's bundled
    # cxxabi.h:30 `class type_info`.  Under aarch64-windows-gnu zig uses its bundled
    # MinGW/libc++ headers instead, so no MSVC header is pulled and the collision cannot
    # occur (and the produced DLL matches the aarch64 liblld*.a archives it bundles).
    # ZIG_TARGET_HOST = aarch64-windows-gnu here (recipe.yaml zig_target).
    # The -I shim keeps LLVM's patched libc++ headers ahead of zig's for any residual
    # inclusion; harmless once -target removes the MSVC path.
    local _cxxabi_idir="-I${PREFIX}/lib/zig-llvm/include/c++/v1"
    "${ZIG_CXX}" -target "${ZIG_TARGET_HOST}" ${_cxxabi_idir} -shared \
      -Wl,--whole-archive \
        "${_lld_lib}/liblldELF.a" \
        "${_lld_lib}/liblldCOFF.a" \
        "${_lld_lib}/liblldMachO.a" \
        "${_lld_lib}/liblldWasm.a" \
        "${_lld_lib}/liblldMinGW.a" \
        "${_lld_lib}/liblldCommon.a" \
      -Wl,--no-whole-archive \
      -Wl,--export-all-symbols \
      -Wl,--out-implib,"${_implib}" \
      -L"${_lld_lib}" \
      -L"${PREFIX}/Library/lib" \
      "${_lld_lib}/libLLVM-20.dll.a" -lz \
      -o "${_out}" || {
      echo "  FAILED: linker error building ${_out}" >&2
      return 1
    }
    if [[ ! -f "${_out}" ]]; then
      echo "  FAILED: ${_out} not produced" >&2
      return 1
    fi
    if [[ ! -f "${_implib}" ]]; then
      echo "  FAILED: import lib ${_implib} not produced" >&2
      return 1
    fi
    echo "  OK: $(ls -lh "${_out}" | awk '{print $5, $9}') + import lib $(ls -lh "${_implib}" | awk '{print $5, $9}')"

  else
    echo "  WARNING: unrecognised target_platform=${target_platform}, skipping lld bundle" >&2
  fi
  set +x  # DIAGNOSTIC: disable tracing
}
