# _runtimes_target.sh -- TARGET-arch LLVM runtimes build (part 2 of the old _runtimes_build.sh).
# Split out so the NATIVE build-arch libc++ (part 1, _runtimes_build.sh) can be built + staged
# BEFORE build_native_llvm_config. Sourced from build.sh AFTER build_native_llvm_config.
# The libunwind CXX_SUPPORTS_* compensating overrides must also fire when conda
# reports cross-compilation even if the bash is_cross string-compare is false
# (build==host==target self-cross lane); mirrors the convention already used
# in _cmake_flags.sh:157.
if is_cross || [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  _RUNTIMES_CMAKE+=(
    -DCMAKE_C_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    -DCMAKE_CXX_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    -DCMAKE_ASM_COMPILER_TARGET="${ZIG_LLVM_TRIPLET}"
    "-DCMAKE_ASM_FLAGS=--target=${ZIG_LLVM_TRIPLET}"
    # Skip cmake's ABI detection — it runs in EXECUTABLE mode and fails for cross-builds,
    # leaving cmake architecturally blind and poisoning all check_cxx_compiler_flag probes.
    # Without this, libunwind's CXX_SUPPORTS_FUNWIND_TABLES_FLAG probe fails and the
    # configure aborts at libunwind/src/CMakeLists.txt:107.
    -DCMAKE_C_ABI_COMPILED=TRUE
    -DCMAKE_CXX_ABI_COMPILED=TRUE
  )
fi

echo "  Building runtimes: ${_RUNTIMES_LIST}..."
mkdir -p "${SRC_DIR}/conda-runtimes-build"

# zig wrapper needs build-arch libc++.so.1 on the loader path for the compiler check.
if is_linux; then
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/zig-llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Configure and build LLVM runtimes.
cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
  "${_RUNTIMES_CMAKE[@]}" \
  -DLLVM_ENABLE_RUNTIMES="${_RUNTIMES_LIST}" \
  "${_RUNTIMES_FLAGS[@]}" \
  -G Ninja \
  || {
    _main_configure_rc=$?
    echo "===== zig-feedstock DIAGNOSTIC: main-pass cmake configure FAILED (rc=${_main_configure_rc}), dumping probe logs ====="
    find "${SRC_DIR}/conda-runtimes-build" -name CMakeError.log -exec sh -c 'echo "----- {} -----"; cat "{}"' \; 2>/dev/null || true
    find "${SRC_DIR}/conda-runtimes-build" -name CMakeOutput.log -exec sh -c 'echo "----- {} -----"; cat "{}"' \; 2>/dev/null || true
    find "${SRC_DIR}/conda-runtimes-build" \( -path '*CMakeFiles*CompilerId*' -o -path '*CMakeFiles*CMakeError*' \) 2>/dev/null | head -40 || true
    echo "FATAL: main-pass libc++ cmake configure failed"
    exit "${_main_configure_rc}"
  }
export ZIG_STRIP_DEPLIBS=1
cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}"
cmake --install "${SRC_DIR}/conda-runtimes-build"
unset ZIG_STRIP_DEPLIBS

# Disk recovery: Phase 1 runtimes build dir (~1-2GB) is no longer needed
# after install. Removing it before Phase 2 prevents ENOSPC on linux-64
# (cross-target LLVM peaks at 15-20GB during Phase 2 compile). Local
# iteration (.zig_local_iterate sentinel) skips this to preserve incremental
# build state -- requires extra free disk locally as a result (Phase 1 dir +
# Phase 2's peak, layered instead of sequential; budget 20-30GB+ free).
if [[ -f "${SRC_DIR}/.zig_local_iterate" ]]; then
  echo "  .zig_local_iterate sentinel present: preserving conda-runtimes-build for incremental local rebuilds (requires extra free disk)"
else
  echo "=== Removing Phase 1 runtimes build dir (disk recovery) ==="
  rm -rf "${SRC_DIR}/conda-runtimes-build"
fi

echo "  libc++ runtimes installed to ${LLVM_INSTALL}/lib"


# === zig _14 libc++ probe: make shared libc++ visible at BUILD_PREFIX ===
# zig _14's libcxx_shared.zig probes for shared libc++ relative to zig_lib_dir:
#   <zig_lib_dir>/../../lib/zig-llvm/lib/libc++{.so.1,.1.dylib,.dll.a}
# zig_lib_dir is $BUILD_PREFIX/lib/zig/ (Linux/macOS) or $BUILD_PREFIX/Library/lib/zig/ (Windows).
# Phase 1 installs libc++ to $PREFIX/lib/zig-llvm/lib/ — different from BUILD_PREFIX.
# Symlink so zig _14 finds it during Phase 2 AND when downstream packages build.
if is_not_unix; then
  _probe_dir="${BUILD_PREFIX}/Library/lib/zig-llvm/lib"
else
  _probe_dir="${BUILD_PREFIX}/lib/zig-llvm/lib"
fi
mkdir -p "${_probe_dir}"
# Stage BUILD-arch libc++/libunwind into the zig probe dir. On cross builds
# ${LLVM_INSTALL}/lib is TARGET-arch and unusable by host tools or the build-arch
# zig probe, so copy the build-arch runtimes produced by the NATIVE build above.
# On native builds the main runtimes install IS build-arch, so copy from
# ${LLVM_INSTALL}/lib directly.
if is_cross; then
  _probe_src="${SRC_DIR}/native-libcxx-install/lib"
else
  _probe_src="${LLVM_INSTALL}/lib"
fi
echo "  Creating zig _14 libc++ probe copies at ${_probe_dir} (from ${_probe_src})"
for _libcxx in "${_probe_src}/"libc++* "${_probe_src}/"libunwind*; do
  [[ -f "${_libcxx}" ]] || continue
  _name=$(basename "${_libcxx}")
  _dest="${_probe_dir}/${_name}"
  # On native builds ${LLVM_INSTALL}/lib and ${_probe_dir} can be the same
  # directory ($PREFIX/lib/zig-llvm/lib); skip the copy-onto-itself that cp
  # refuses with "are the same file".
  if [[ -e "${_dest}" ]] && [[ "${_libcxx}" -ef "${_dest}" ]]; then
    echo "    ${_name} already at ${_dest} (same file, skipping)"
    continue
  fi
  # cp not ln -sf: Windows native zig may not follow MSYS2 Unix symlinks for libc++.dll.a
  cp -f "${_libcxx}" "${_dest}"
  echo "    ${_name} ($(wc -c < "${_dest}") bytes)"
done

# Verify build-arch libc++ is present at the probe path before Phase 2 LLVM build.
# zig's libcxx_shared.zig probes ${_probe_dir}/libc++.so.1 (or equivalent on other
# platforms); if absent, zig falls back to its bundled static libc++.a from zig-cache,
# causing static merge of libc++ into every .so we build (failing the post-install
# LOCAL_DEFINED check).
# Platform-aware probe filename (matches what zig's libcxx_shared.zig actually probes for):
# Linux → libc++.so.1, macOS → libc++.1.dylib, Windows → libc++.dll.a
if is_not_unix; then
  _probe_file="${_probe_dir}/libc++.dll.a"
elif is_osx; then
  _probe_file="${_probe_dir}/libc++.1.dylib"
else
  _probe_file="${_probe_dir}/libc++.so.1"
fi
if [[ ! -f "${_probe_file}" ]]; then
  echo "FATAL: ${_probe_file} is missing."
  echo "       zig will fall back to bundled static libc++.a, causing static merge"
  echo "       into every shared library built (post-install LOCAL_DEFINED check will fail)."
  echo "       The build-arch libc++ staged above (NATIVE build on cross, main install"
  echo "       on native) failed to populate ${_probe_dir}; check the NATIVE runtimes"
  echo "       build and the probe-copy loop above."
  exit 1
fi
echo "=== libc++ probe path verified: ${_probe_file} present ==="

