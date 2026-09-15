# Native bootstrap zig, built from our patched source (no 0003 GCC redirect).
# Only invoked when ZIG_BOOTSTRAP_NATIVE_REBUILD=1 (operator switch, off by
# default). See recipe.yaml's bootstrap_native_rebuild and build.sh's gate.

source "${RECIPE_DIR}/building/_common.sh"
source "${RECIPE_DIR}/building/_zig_diag.sh"

# build_native_bootstrap_zig <source_dir> <build_zig>
# Builds a NATIVE (build-platform) zig using <build_zig>, from <source_dir>.
# Installs to a work-area dir (never PREFIX). Sets NATIVE_BOOTSTRAP_ZIG on
# success; exits non-zero if the binary is not produced.
function build_native_bootstrap_zig() {
  local source_dir=$1
  local build_zig=$2
  local install_dir="${SRC_DIR}/zig-native-bootstrap"

  echo "=== STAGE A: native bootstrap zig (build_platform=${build_platform}, no 0003 redirect) ==="
  echo "[native-bootstrap] source=${source_dir} build_zig=${build_zig} install=${install_dir}"

  mkdir -p "${install_dir}"

  # No -Dtarget: build is native-native so zig compiles its glue with the
  # pinned native CC/CXX below, keeping its C++ ABI matched to conda's libstdc++-built LLVM archives.

  # Resolve a build-arch (not cross) gcc toolchain: prefer the triplet-prefixed
  # binaries from a build_platform-native gcc_impl/binutils_impl, else PATH gcc.
  local native_cc="" native_cxx="" native_ar="" native_ranlib=""
  if [[ -n "${BUILD:-}" && -x "${BUILD_PREFIX}/bin/${BUILD}-gcc" && -x "${BUILD_PREFIX}/bin/${BUILD}-g++" ]]; then
    native_cc="${BUILD_PREFIX}/bin/${BUILD}-gcc"
    native_cxx="${BUILD_PREFIX}/bin/${BUILD}-g++"
    native_ar="${BUILD_PREFIX}/bin/${BUILD}-ar"
    native_ranlib="${BUILD_PREFIX}/bin/${BUILD}-ranlib"
  elif command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1; then
    native_cc="$(command -v gcc)"
    native_cxx="$(command -v g++)"
    native_ar="$(command -v ar)"
    native_ranlib="$(command -v ranlib)"
  else
    echo "ERROR: no build-arch gcc/g++ toolchain found (looked for \${BUILD_PREFIX}/bin/\${BUILD}-gcc and plain gcc/g++ on PATH)" >&2
    exit 1
  fi
  echo "[native-bootstrap] build-arch toolchain: CC=${native_cc} CXX=${native_cxx}"

  # conda's cross-toolchain sysroot is nested under BUILD_PREFIX/<build-triplet>/sysroot,
  # not directly under BUILD_PREFIX, so zig's libc probe misses it without help.
  local native_sysroot=""
  native_sysroot="$("${native_cc}" -print-sysroot 2>/dev/null || true)"
  if [[ -z "${native_sysroot}" || ! -d "${native_sysroot}" ]]; then
    native_sysroot="${BUILD_PREFIX}/${BUILD:-}/sysroot"
  fi
  if [[ ! -d "${native_sysroot}" ]]; then
    echo "[native-bootstrap] WARNING: could not resolve an existing native sysroot (tried '${native_cc} -print-sysroot' and \${BUILD_PREFIX}/\${BUILD}/sysroot); proceeding without a second --search-prefix" >&2
    native_sysroot=""
  fi
  echo "[native-bootstrap] sysroot: ${native_sysroot}"

  # static-llvm=true forces build.zig's cmake_cfg to null, so zig compiles
  # src/zig_llvm.cpp itself against its bundled libc++ headers and fails to
  # link conda's libstdc++-ABI LLVM archives (198 undefined std::__1:: syms).
  # Pre-build libzigcpp.a here with the native gcc (matching Phase 1's
  # configure_cmake_zigcpp), then point zig at it via -Dconfig_h so it
  # reuses the archive instead of recompiling zig_llvm.cpp itself.
  local native_cmake_build_dir="${SRC_DIR}/build-native-bootstrap"
  local native_cmake_install_dir="${native_cmake_build_dir}/unused-install"
  local native_config_h="${native_cmake_build_dir}/config.h"
  local native_libzigcpp="${native_cmake_build_dir}/zigcpp/libzigcpp.a"

  echo "[native-bootstrap] clang/lld artifacts by prefix (diagnostic only):"
  for _p in "${BUILD_PREFIX}" "${PREFIX}"; do
    for _pat in libclang-cpp.so liblldELF.a liblldCommon.a libxml2.so libz.so llvm-config; do
      _hit=$(ls -1 "${_p}"/lib/"${_pat}"* "${_p}"/bin/"${_pat}" 2>/dev/null | head -1) || true
      echo "  ${_p##*/}: ${_pat} -> ${_hit:-MISSING}"
    done
  done
  unset _p _pat _hit

  mkdir -p "${native_cmake_build_dir}"

  # Not configure_cmake_zigcpp: that helper reads the global cmake_source_dir,
  # which build.sh only sets after Stage A runs. Invoke cmake directly instead,
  # against this function's own source_dir and a private build dir (never
  # Phase 1's build-release) so the two cmake builds cannot clobber each other.
  local _prev_cc_set=0 _prev_cxx_set=0 _prev_cc_val="" _prev_cxx_val=""
  if [[ -n "${CC+x}" ]]; then _prev_cc_set=1; _prev_cc_val="${CC}"; fi
  if [[ -n "${CXX+x}" ]]; then _prev_cxx_set=1; _prev_cxx_val="${CXX}"; fi
  export CC="${native_cc}"
  export CXX="${native_cxx}"

  local native_cmake_args=(-D ZIG_USE_LLVM_CONFIG=ON)
  is_unix && native_cmake_args+=(-D ZIG_SHARED_LLVM=ON)

  local cmake_rc=0
  (
    cd "${native_cmake_build_dir}" &&
    # Same target-arch flag scrub as the zig build step below; cmake configure/build
    # otherwise inherit ambient CFLAGS/CXXFLAGS/CPPFLAGS from the cross activation.
    env -u LD -u NM -u STRIP -u OBJCOPY -u OBJDUMP -u READELF \
        -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u DEBUG_CFLAGS -u DEBUG_CXXFLAGS \
        -u CONDA_BUILD_SYSROOT -u CMAKE_ARGS -u HOST -u BUILD \
        -u CMAKE_PREFIX_PATH -u CMAKE_FIND_ROOT_PATH -u CMAKE_TOOLCHAIN_FILE \
        -u CMAKE_LIBRARY_PATH -u CMAKE_INCLUDE_PATH -u CMAKE_PROGRAM_PATH \
        CC="${native_cc}" CXX="${native_cxx}" AR="${native_ar}" RANLIB="${native_ranlib}" \
        cmake "${source_dir}" \
      -D CMAKE_INSTALL_PREFIX="${native_cmake_install_dir}" \
      -D CMAKE_PREFIX_PATH="${BUILD_PREFIX}" \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZIG_TARGET_MCPU=baseline \
      "${native_cmake_args[@]}" \
      -G Ninja &&
    env -u LD -u NM -u STRIP -u OBJCOPY -u OBJDUMP -u READELF \
        -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u DEBUG_CFLAGS -u DEBUG_CXXFLAGS \
        -u CONDA_BUILD_SYSROOT -u CMAKE_ARGS -u HOST -u BUILD \
        -u CMAKE_PREFIX_PATH -u CMAKE_FIND_ROOT_PATH -u CMAKE_TOOLCHAIN_FILE \
        -u CMAKE_LIBRARY_PATH -u CMAKE_INCLUDE_PATH -u CMAKE_PROGRAM_PATH \
        CC="${native_cc}" CXX="${native_cxx}" AR="${native_ar}" RANLIB="${native_ranlib}" \
        cmake --build . --target zigcpp -- -j"${CPU_COUNT}" ${NINJA_FLAGS:-}
  ) || cmake_rc=$?

  if [[ "${_prev_cc_set}" == "1" ]]; then export CC="${_prev_cc_val}"; else unset CC; fi
  if [[ "${_prev_cxx_set}" == "1" ]]; then export CXX="${_prev_cxx_val}"; else unset CXX; fi

  if [[ ${cmake_rc} -ne 0 ]]; then
    echo "ERROR: Stage A zigcpp cmake build failed (rc=${cmake_rc})" >&2
    exit 1
  fi
  if [[ ! -f "${native_libzigcpp}" ]]; then
    echo "ERROR: Stage A zigcpp build did not produce ${native_libzigcpp}" >&2
    exit 1
  fi
  if [[ ! -f "${native_config_h}" ]]; then
    echo "ERROR: Stage A cmake did not produce ${native_config_h}" >&2
    exit 1
  fi

  # abs mode must land after the cmake probe and before zig build: build-arch gcc
  # re-prepends --sysroot onto absolute paths, so restrict the rewrite to ${BUILD}.
  if is_linux; then
    echo "[native-bootstrap] rewriting sysroot ld scripts before zig build (abs mode)"
    source "${RECIPE_DIR}/building/_sysroot_fix.sh"
    local _prev_mode_set=0
    local _prev_mode_val=""
    if [[ -n "${ZIG_SYSROOT_MODE+x}" ]]; then
      _prev_mode_set=1
      _prev_mode_val="${ZIG_SYSROOT_MODE}"
    fi
    export ZIG_SYSROOT_MODE=abs
    if [[ -n "${BUILD:-}" ]]; then
      fix_sysroot_libc_scripts "${BUILD_PREFIX}" "${BUILD}"
    else
      echo "[native-bootstrap] WARNING: BUILD unset, rewriting all sysroots (abs)"
      fix_sysroot_libc_scripts "${BUILD_PREFIX}"
    fi
    if [[ "${_prev_mode_set}" == "1" ]]; then
      export ZIG_SYSROOT_MODE="${_prev_mode_val}"
    else
      unset ZIG_SYSROOT_MODE
    fi
  fi

  local native_args=(
    --prefix "${install_dir}"
    --search-prefix "${BUILD_PREFIX}"
    --maxrss 7800000000
    -Dconfig_h="${native_config_h}"
    -Dcpu=baseline
    -Denable-llvm
    -Doptimize=ReleaseSafe
    -Dstatic-llvm=false
    -Dstrip=true
    -Duse-zig-libcxx=false
    -Dno-langref
    -Dversion-string="${PKG_VERSION}"
  )
  if [[ -n "${native_sysroot}" ]]; then
    native_args+=(--search-prefix "${native_sysroot}")
  fi

  local rc=0
  (
    cd "${source_dir}" &&
    # Pin CC/CXX/AR/RANLIB to a build-arch gcc so zig's glue links libstdc++
    # matching conda's LLVM/Clang archives; still strip target-arch flags/sysroot.
    env -u LD -u NM -u STRIP -u OBJCOPY -u OBJDUMP -u READELF \
        -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u DEBUG_CFLAGS -u DEBUG_CXXFLAGS \
        -u CONDA_BUILD_SYSROOT -u CMAKE_ARGS -u HOST -u BUILD \
        -u CMAKE_PREFIX_PATH -u CMAKE_FIND_ROOT_PATH -u CMAKE_TOOLCHAIN_FILE \
        -u CMAKE_LIBRARY_PATH -u CMAKE_INCLUDE_PATH -u CMAKE_PROGRAM_PATH \
        CC="${native_cc}" CXX="${native_cxx}" AR="${native_ar}" RANLIB="${native_ranlib}" \
        ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-native-bootstrap-global-cache" \
        ZIG_LOCAL_CACHE_DIR="${SRC_DIR}/zig-native-bootstrap-local-cache" \
        "${build_zig}" build "${native_args[@]}"
  ) || rc=$?

  if [[ ${rc} -ne 0 ]]; then
    echo "ERROR: native bootstrap zig build failed (rc=${rc})" >&2
    exit 1
  fi

  NATIVE_BOOTSTRAP_ZIG="${install_dir}/bin/zig"
  if [[ ! -x "${NATIVE_BOOTSTRAP_ZIG}" ]]; then
    echo "ERROR: native bootstrap zig binary not produced at ${NATIVE_BOOTSTRAP_ZIG}" >&2
    exit 1
  fi

  echo "=== STAGE A complete: native bootstrap zig at ${NATIVE_BOOTSTRAP_ZIG} ==="
  export NATIVE_BOOTSTRAP_ZIG
}
