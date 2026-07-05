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
  dbg echo "=== zigcpp bundle ppc64le ==="
  if [[ -f "${output_so}" ]]; then
    return 0
  fi

  mkdir -p "${output_dir}"

  if [[ ! -f "${zigcpp_archive}" ]]; then
    echo "[zigcpp-bundle] FAILED: ${zigcpp_archive} not found — run configure_cmake_zigcpp first" >&2
    return 1
  fi

  echo "[zigcpp-bundle] Building ${output_so} from ${zigcpp_archive}"

  # cxx_compiler (ZIG_CXX) is the build-host zig-cxx wrapper; without an explicit
  # -target it falls back to its baked-in native x86_64 default, so ld.lld runs in
  # elf_x86_64 mode and rejects the target-arch (ppc64le) zigcpp_archive + ZIG_LLVM_ROOT
  # libs as "incompatible with elf_x86_64". Pass the ppc64le triple explicitly (same
  # idiom as the zig_build.sh wrapper compile) so the whole link targets ppc64le.
  # ppc64le routes this C++ link through the external GNU linker (collect2 /
  # powerpc64le-conda-linux-gnu-ld.real) instead of zig's self-hosted/LLD path
  # (unlike other arches). The C++ driver's implicit runtime link therefore
  # adds an explicit -lc++abi request that GNU ld hard-fails to resolve
  # ("cannot find -lc++abi") once the earlier "Removing static libraries" step
  # (remove_unneeded in recipe/llvm/building/_runtimes_build.sh /
  # remove-unneeded.sh) strips libc++abi.a from zig-llvm/lib.
  #
  # No standalone libc++abi.so ever exists to satisfy -lc++abi: the runtimes
  # build forces LIBCXXABI_ENABLE_SHARED=OFF / LIBCXXABI_ENABLE_STATIC=ON and
  # LIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON (see _runtimes_build.sh),
  # so libc++abi's object code is statically merged into libc++.so.1.0 on
  # every platform. post-install.sh's "Adding libc++ NEEDED entry via
  # patchelf" step documents and relies on this same fact (only libc++.so.1
  # is added as NEEDED, never a separate libc++abi.so) — the same reasoning
  # that lets libunwind (a genuine standalone .so) get folded into libc++'s
  # NEEDED entries there.
  #
  # Fix attempt #1 (did not work): -nostdlib++, intended to drop the
  # driver's implicit -lc++ -lc++abi pair so we could relink -lc++ alone.
  # CI (PR #109, 89ac4642) proved -nostdlib++ does not propagate through the
  # zig-cxx -> collect2/gcc chain on ppc64le: collect2/gcc specs re-append
  # -lc++abi regardless, and the link still fails with
  # "cannot find -lc++abi". -nostdlib++ -lc++ is kept below anyway (harmless:
  # if it is honored it dedups the default pair, and if it is ignored — as
  # observed — it is a no-op alongside the driver's own implicit -lc++).
  #
  # Fix attempt #2 (did not work either): synthesize a *zero-member* stub
  # archive via plain `ar rcs libc++abi.a` (no object files) and add its
  # directory to -L, on the theory that ld only needs *something* named
  # libc++abi.a to stop erroring. CI proved this ineffective too: the exact
  # same "cannot find -lc++abi: No such file or directory" recurred even
  # though the stub file existed on disk at the correct -L path.
  #
  # Fix attempt #3 (did not work either, PR #109 6eb9c230): compile a tiny
  # weak-symbol C object with cxx_compiler and `ar rcs` *that* into
  # libc++abi.a under a brand-new dedicated directory
  # (${output_dir}/.stub-libs), same convention as _mingw.sh's proven
  # _create_stub_lib_archive helper (a member-bearing archive, never an
  # empty one). CI proved this ineffective too: identical
  # "cannot find -lc++abi: No such file or directory" recurred. Since both
  # #2 and #3 used a *new*, dedicated -L directory and both failed
  # identically, the object-emptiness theory from #2 is now ruled out —
  # the common factor is the *directory*, not the archive contents. Leading
  # theory: a -L flag pointing at a directory the zig-cxx -> collect2/gcc
  # chain doesn't already know about does not survive translation into the
  # final `ld` invocation on this path (possibly because zig's own internal
  # C++ stdlib linking step adds -lc++abi using its own hardcoded/known
  # search dirs, not the full user -L list, when delegating to the external
  # GCC linker).
  #
  # Fix attempt #4 (current): stop using a brand-new -L directory entirely.
  # Place the same weak-symbol stub archive directly inside
  # ${ZIG_LLVM_ROOT}/lib — the *existing* -L directory already present on
  # this exact command line (`-L"${ZIG_LLVM_ROOT}/lib"`) and already proven
  # to resolve real libraries for this exact link (libLLVM-20.so,
  # libclang-cpp.so.20.1 are found from there). Reusing a directory the
  # link already reaches removes any doubt about custom -L propagation.
  # The stub is removed again immediately after the link (success or
  # failure) so it never ships in the installed package.
  local stub_libcxxabi="${ZIG_LLVM_ROOT}/lib/libc++abi.a"
  local _created_stub=0
  if [[ ! -f "${stub_libcxxabi}" ]]; then
    local stub_c="${output_dir}/.stub_libcxxabi.c"
    local stub_o="${output_dir}/.stub_libcxxabi.o"
    printf 'int __zig_libcxxabi_stub __attribute__((weak)) = 0;\n' > "${stub_c}"
    if ! "${cxx_compiler}" -c "${stub_c}" -o "${stub_o}" -fPIC \
        --target="${ZIG_TRIPLET}" 2>/dev/null; then
      echo "[zigcpp-bundle] FAILED: could not compile libc++abi.a stub object" >&2
      rm -f "${stub_c}" "${stub_o}"
      return 1
    fi
    if ! ar rcs "${stub_libcxxabi}" "${stub_o}"; then
      echo "[zigcpp-bundle] FAILED: could not create libc++abi.a stub archive" >&2
      rm -f "${stub_c}" "${stub_o}"
      return 1
    fi
    rm -f "${stub_c}" "${stub_o}"
    _created_stub=1
  fi

  if ! "${cxx_compiler}" -shared -fPIC \
    --target="${ZIG_TRIPLET}" \
    -Wl,--whole-archive \
    "${zigcpp_archive}" \
    -Wl,--no-whole-archive \
    -Wl,--export-dynamic \
    -Wl,-rpath,"${prefix}/lib" \
    -L"${prefix}/lib" \
    -L"${ZIG_LLVM_ROOT}/lib" \
    "${ZIG_LLVM_ROOT}/lib/libLLVM-20.so" \
    "${ZIG_LLVM_ROOT}/lib/libclang-cpp.so.20.1" \
    -nostdlib++ -lc++ \
    -lzstd -lxml2 -lz -lpthread \
    -o "${output_so}"; then
    [[ ${_created_stub} -eq 1 ]] && rm -f "${stub_libcxxabi}"
    echo "[zigcpp-bundle] FAILED: compiler error building ${output_so}" >&2
    return 1
  fi
  [[ ${_created_stub} -eq 1 ]] && rm -f "${stub_libcxxabi}"

  if [[ ! -f "${output_so}" ]]; then
    echo "[zigcpp-bundle] FAILED: ${output_so} not produced" >&2
    return 1
  fi

  echo "[zigcpp-bundle] OK: $(ls -lh "${output_so}" | awk '{print $5, $9}')"
}
