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

  mkdir -p "${output_dir}"

  dbg echo "[lld-bundle] Building ${output_so} from \${PREFIX}/lib/liblld*.a"
  echo "[lld-bundle] Building ${output_so} from \${PREFIX}/lib/liblld*.a"

  "${cxx_compiler}" -shared -fPIC \
    -Wl,--whole-archive \
    "${prefix}/lib/liblldELF.a" \
    "${prefix}/lib/liblldCOFF.a" \
    "${prefix}/lib/liblldMachO.a" \
    "${prefix}/lib/liblldWasm.a" \
    "${prefix}/lib/liblldMinGW.a" \
    "${prefix}/lib/liblldCommon.a" \
    -Wl,--no-whole-archive \
    -Wl,--export-dynamic \
    -Wl,-rpath,"${prefix}/lib" \
    -L"${prefix}/lib" \
    "${prefix}/lib/libLLVM-20.so" \
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
