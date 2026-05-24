function build_zigcpp_bundle_ppc64le() {
  # Bundle prebuilt libzigcpp.a into a shared library for ppc64le.
  #
  # Rationale: libzigcpp.a (built from zig_clang_cc1_main.cpp.o and friends)
  # references LLVM/Clang symbols via R_PPC64_REL24 direct branches (+/-32MB
  # limit).  When linked into the large zig2 binary the accumulated .text size
  # pushes callers far outside that window, causing:
  #   R_PPC64_REL24 relocation truncated to fit: <symbol> against `...AliasSetTracker...'
  #
  # Bundling libzigcpp.a into a single .so gives it its own compact address
  # space; intra-.so calls are resolved by the dynamic linker within that
  # region, and the REL24 overflow disappears.
  #
  # The resulting libzig-zigcpp-bundle.so is linked into zig2 in place of the
  # static archive via -DZIG_ZIGCPP_BUNDLE_SO=... (CMakeLists.txt patch 0007).
  # REL24 mitigation: convert libzigcpp.a to shared to isolate its address space.

  local cxx_compiler="${1}"
  local prefix="${2}"
  local output_dir="${3}"
  local build_dir="${4:-${SRC_DIR}/build-release}"
  local output_so="${output_dir}/libzig-zigcpp-bundle.so"
  local zigcpp_archive="${build_dir}/zigcpp/libzigcpp.a"

  # Idempotency guard: skip rebuild if output .so already exists
  # (build.sh and cmake_build both call this; second call no-ops)
  if [[ -f "${output_so}" ]]; then
    dbg echo "build_zigcpp_bundle_ppc64le: skipping rebuild — ${output_so} already present"
    return 0
  fi

  mkdir -p "${output_dir}"

  if [[ ! -f "${zigcpp_archive}" ]]; then
    echo "[zigcpp-bundle] FAILED: ${zigcpp_archive} not found — run configure_cmake_zigcpp first" >&2
    return 1
  fi

  echo "[zigcpp-bundle] Building ${output_so} from ${zigcpp_archive}"

  "${cxx_compiler}" -shared -fPIC \
    -Wl,--whole-archive \
    "${zigcpp_archive}" \
    -Wl,--no-whole-archive \
    -Wl,--export-dynamic \
    -Wl,-rpath,"${prefix}/lib" \
    -L"${prefix}/lib" \
    "${prefix}/lib/libLLVM-21.so" \
    "${prefix}/lib/libclang-cpp.so.21.1" \
    -lzstd -lxml2 -lz -lpthread \
    -o "${output_so}" || {
    echo "[zigcpp-bundle] FAILED: compiler error building ${output_so}" >&2
    return 1
  }

  if [[ ! -f "${output_so}" ]]; then
    echo "[zigcpp-bundle] FAILED: ${output_so} not produced" >&2
    return 1
  fi

  echo "[zigcpp-bundle] OK: $(ls -lh "${output_so}" | awk '{print $5, $9}')"
}
