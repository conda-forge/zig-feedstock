function build_lld_bundle_ppc64le() {
  # Bundle prebuilt liblld*.a archives into a shared library for ppc64le.
  #
  # Rationale: conda-shipped liblld{ELF,COFF,MachO,Wasm,MinGW,Common}.a were
  # built without -mlongcall.  Their static-init code calls into LLVM shared
  # library helpers via R_PPC64_REL24 direct branches (+/-32MB limit), but the
  # combined zig2 image pushes the archives far outside that window, causing:
  #   R_PPC64_REL24 relocation truncated to fit: ...
  #
  # Bundling the archives into a single .so gives each one its own address
  # space; intra-.so calls are resolved by the dynamic linker within that
  # compact region, and the REL24 overflow disappears.
  #
  # The resulting libzig-lld-bundle.so is linked into zig2 in place of the
  # static archives via -DZIG_LLD_BUNDLE_SO=... (CMakeLists.txt patch 0006).

  local cxx_compiler="${1}"
  local prefix="${2}"
  local output_dir="${3}"
  local output_so="${output_dir}/libzig-lld-bundle.so"

  # Idempotency guard: skip rebuild if output .so already exists
  # (called from the zig build path; second call no-ops)
  if [[ -f "${output_so}" ]]; then
    dbg echo "build_lld_bundle_ppc64le: skipping rebuild — ${output_so} already present"
    return 0
  fi

  mkdir -p "${output_dir}"

  echo "[lld-bundle] Building ${output_so} from \${PREFIX}/lib/zig-llvm/lib/liblld*.a"

  # LLD static archives and libLLVM both install under ${prefix}/lib/zig-llvm/lib
  # (the LLVM_INSTALL convention used throughout recipe/zig-llvm/), NOT bare
  # ${prefix}/lib -- confirmed via live CI: CMake's own find_package(LLD) finds
  # them at $PREFIX/lib/zig-llvm/lib/liblldELF.a etc, but this function was
  # still pointing at the bare prefix, causing "file not found" on ppc64le.
  local llvm_lib="${prefix}/lib/zig-llvm/lib"
  "${cxx_compiler}" -shared -fPIC \
    -Wl,--whole-archive \
    "${llvm_lib}/liblldELF.a" \
    "${llvm_lib}/liblldCOFF.a" \
    "${llvm_lib}/liblldMachO.a" \
    "${llvm_lib}/liblldWasm.a" \
    "${llvm_lib}/liblldMinGW.a" \
    "${llvm_lib}/liblldCommon.a" \
    -Wl,--no-whole-archive \
    -Wl,--export-dynamic \
    -Wl,-rpath,"${llvm_lib}" \
    -L"${prefix}/lib" \
    "${llvm_lib}/libLLVM-21.so" \
    -lzstd -lxml2 -lz -lpthread \
    -o "${output_so}" || {
    echo "[lld-bundle] FAILED: compiler error building ${output_so}" >&2
    return 1
  }

  if [[ ! -f "${output_so}" ]]; then
    echo "[lld-bundle] FAILED: ${output_so} not produced" >&2
    return 1
  fi

  echo "[lld-bundle] OK: $(ls -lh "${output_so}" | awk '{print $5, $9}')"
}
