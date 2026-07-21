#!/usr/bin/env bash
# Build a BUILD-arch (host-runnable) llvm-config from THIS build's LLVM source, so
# cross zig_impl builds are self-sufficient and do NOT borrow llvm-config from a
# previously-published zig_impl_${build_platform} build-dep (recipe.yaml:347). That
# dep is stale across the LLVM 20->21 bump (wrong --version / --libnames) and absent
# at lib/zig-llvm/bin for osx-64's pre-layout dep -> build-zig.sh FATAL.
#
# Invariant (remove-unneeded.sh): the shipped llvm-config wrapper does NOT rewrite
# paths; llvm-config derives include/lib purely from its binary LOCATION. A binary at
# <P>/lib/zig-llvm/bin/llvm-config reports <P>/lib/zig-llvm/{include,lib}. We stage the
# native binary at ${BUILD_PREFIX}/lib/zig-llvm/bin; the existing BUILD_PREFIX->PREFIX
# config.h rewrite (build-zig.sh) repoints to the shipped target tree at link time.

# Single source of truth for the LLVM backend list (kept identical to the target
# build in _llvm_build.sh). Sets _llvm_targets / _llvm_exp_targets.
compute_llvm_targets() {
  _llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX;BPF;Hexagon;Lanai;MSP430;VE;XCore;LoongArch;Mips;Sparc"
  _llvm_exp_targets="SPIRV"
  if [[ "${ZIG_TRIPLET}" == aarch64-* ]] && is_not_unix; then
    _llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly"
    _llvm_exp_targets=""
    echo "  win-arm64: pruned LLVM_TARGETS_TO_BUILD (dropped AVR, AMDGPU, NVPTX) to fit PE/COFF 65535 export limit"
  elif [[ "${ZIG_TRIPLET}" == x86_64-windows-gnu* ]] && is_not_unix; then
    # win-64 is NOT PE/COFF export-limited (that constraint was win-arm64
    # specific). This prune is a pure build-time tradeoff: the full 19-backend
    # + SPIRV LLVM build times out win-64's 360-min Azure Pipelines budget.
    # Reuses win-arm64's same 7-backend subset so both windows lanes match;
    # the cost is win-64-built zig loses AMDGPU/AVR/NVPTX/BPF/Hexagon/Lanai/
    # MSP430/VE/XCore/LoongArch/Mips/Sparc/SPIRV as cross-compilation targets.
    _llvm_targets="X86;AArch64;ARM;PowerPC;RISCV;SystemZ;WebAssembly"
    _llvm_exp_targets=""
    echo "  win-64: pruned LLVM_TARGETS_TO_BUILD (same subset as win-arm64) to fit 360-min Azure Pipelines timeout"
  fi
}

build_native_llvm_config() {
  # Unix cross, plus native osx. Windows cross has its own native-tool path
  # (_llvm_build.sh NATIVE + llvm-tools build-dep). Native linux gets a runnable
  # target-arch llvm-config from its own install and does not need this. Native osx
  # does NOT: its build-time llvm-min-tblgen dyld-fails loading libc++.1.dylib
  # (PR #123, osx-64 native) because nothing else stages a build-arch libc++ tree for
  # it, so it is routed through the same self-sufficient llvm-config path as cross.
  is_unix || return 0
  is_cross || is_osx || return 0

  local _stage="${BUILD_PREFIX}/lib/zig-llvm"
  local _bin="${_stage}/bin/llvm-config"

  echo "=== Building BUILD-arch llvm-config (self-sufficient; no zig_impl build-dep) ==="

  # Build-arch host-runnable zig wrappers (recipe/build.sh); ${CONDA_ZIG_BUILD} ==
  # ${CONDA_TOOLCHAIN_BUILD}-zig. Invoked without -target -> build-host objects.
  local _ncc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
  local _ncxx="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
  if [[ ! -x "${_ncc}" || ! -x "${_ncxx}" ]]; then
    echo "FATAL: build-arch zig wrappers not found (${_ncc} / ${_ncxx})" >&2
    return 1
  fi

  compute_llvm_targets

  local _nb="${SRC_DIR}/conda-llvm-native-config"
  if [[ -f "${SRC_DIR}/.zig_local_iterate" ]]; then
    mkdir -p "${_nb}"
  else
    rm -rf "${_nb}" && mkdir -p "${_nb}"
  fi

  # Without an explicit -target, zig-cc's clang driver auto-detects whichever single
  # conda gcc happens to be on BUILD_PREFIX (e.g. gcc_impl_linux-ppc64le on a
  # linux-64 -> linux-ppc64le cross build) and uses ITS sysroot for what must be a
  # build-host (x86_64) compile -- fails with "gnu/stubs-32.h not found" (PR #123,
  # linux-ppc64le cross lane). Force the build-host target explicitly, mirroring
  # the working pattern in _runtimes_build.sh's native-libc++ cmake call.
  local _native_cfg_target=()
  if is_linux; then
    _native_cfg_target=(
      -DCMAKE_C_COMPILER_TARGET="${ZIG_TARGET_BUILD}.2.17"
      -DCMAKE_CXX_COMPILER_TARGET="${ZIG_TARGET_BUILD}.2.17"
      -DCMAKE_ASM_COMPILER_TARGET="${ZIG_TARGET_BUILD}.2.17"
    )
  fi

  # zlib/zstd/xml2 OFF: the conda copies in BUILD_PREFIX are TARGET-arch and cannot
  # link into a host binary; build-zig.sh already appends -lzstd -lxml2 -lz for the
  # target link. Same backend list as the target build so --components/--libnames match.
  #
  # LLVM_LINK_LLVM_DYLIB=ON (added PR #123, round 5): mirrors the target build's own
  # flag (_llvm_build.sh:54). build-zig.sh always configures zigcpp with
  # ZIG_SHARED_LLVM=ON on unix, so zig's cmake/Findllvm.cmake gates every candidate
  # llvm-config with `llvm-config --libs --link-shared` before accepting it.
  # llvm-config's own gate (llvm-config.cpp: `BuiltDyLib = !!LLVM_ENABLE_DYLIB`, itself
  # `@LLVM_BUILD_LLVM_DYLIB@` from BuildVariables.inc.in) only even PERFORMS the
  # shared-library existence probe when the binary was itself configured with
  # LLVM_LINK_LLVM_DYLIB=ON — without this flag `DyLibExists` stays hardcoded false
  # and `--libs --link-shared` unconditionally reports the dylib "missing" once the
  # caller (Findllvm.cmake) explicitly forces LinkModeShared. This is one half of a
  # two-part fix: build-zig.sh separately stages the actual libLLVM shared-library
  # file(s) (already built by _llvm_build.sh into ${PREFIX}/lib/zig-llvm/lib earlier
  # in this same script) into this minimal native tree's ${BUILD_PREFIX}/lib/zig-llvm/lib
  # so the existence probe this flag now enables actually finds a file. Setting the
  # flag here does NOT force building the LLVM dylib target itself — we still build
  # only `--target llvm-config` below — it only changes what the generated llvm-config
  # binary reports about its own (would-be) configuration.
  cmake -S "${LLVM_SRC}" -B "${_nb}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${_ncc}" \
    -DCMAKE_CXX_COMPILER="${_ncxx}" \
    "${_native_cfg_target[@]}" \
    -DCMAKE_INSTALL_PREFIX="${_stage}" \
    -DCMAKE_INSTALL_INCLUDEDIR=include \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_BINDIR=bin \
    -DLLVM_TARGETS_TO_BUILD="${_llvm_targets}" \
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="${_llvm_exp_targets}" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}" \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_BUILD_TOOLS=ON \
    -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON

  # llvm-min-tblgen (built in-tree at ${_nb}/bin) is EXECUTED by this same ninja
  # invocation to generate tablegen codegen headers (e.g. AArch64TargetParserDef.inc,
  # ARMTargetParserDef.inc, PPCGenTargetFeatures.inc, RISCVTargetParserDef.inc) and
  # links against the build-arch libc++.so.1 built by _runtimes_build.sh's NATIVE
  # (build-arch) libc++ step, which runs before this call (recipe/zig-llvm/build.sh
  # sources _runtimes_build.sh, then calls build_native_llvm_config). That step
  # early-stages libc++.so.1/libunwind.so.1 into ${_stage}/lib (see
  # _runtimes_build.sh's "Early stage" section), so it is already present here.
  # Mirrors the identical LD_LIBRARY_PATH bridge used for host llvm-tblgen in the
  # TARGET LLVM build (_llvm_build.sh, is_linux branch, ~line 728).
  export LD_LIBRARY_PATH="${_stage}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  # macOS dyld does NOT honor LD_LIBRARY_PATH the way the Linux loader does, so the
  # export above is a no-op here. LLVM's Apple CMake bakes
  # CMAKE_BUILD_WITH_INSTALL_RPATH=ON / CMAKE_INSTALL_RPATH="@loader_path/../lib"
  # for its own targets, so llvm-min-tblgen (at ${_nb}/bin) resolves libc++ via
  # ${_nb}/bin/../lib = ${_nb}/lib -- NOT via ${_stage}/lib (the zig-llvm probe dir,
  # a different, unrelated rpath convention) and not via DYLD_LIBRARY_PATH either
  # (confirmed PR #123 osx-64 native: dyld only ever tried
  # ".../conda-llvm-native-config/bin/../lib/libc++.1.dylib"). Stage the build-arch
  # libc++/libunwind dylibs there directly so @loader_path/../lib finds them.
  if is_osx; then
    mkdir -p "${_nb}/lib"
    for _f in "${SRC_DIR}/native-libcxx-install/lib/"libc++* "${SRC_DIR}/native-libcxx-install/lib/"libunwind*; do
      [[ -f "${_f}" ]] && cp -f "${_f}" "${_nb}/lib/"
    done
    echo "  osx: staged build-arch libc++/libunwind to ${_nb}/lib for llvm-min-tblgen @loader_path/../lib rpath"
  fi

  cmake --build "${_nb}" --target llvm-config -j"${CPU_COUNT}" || return 1
  cmake --install "${_nb}" --component llvm-config || return 1
  # Headers + cmake exports: the runtimes build (sourced before the target LLVM build)
  # points LLVM_CONFIG_PATH here and expects a real, self-consistent LLVM tree.
  cmake --install "${_nb}" --component llvm-headers || true
  cmake --install "${_nb}" --component cmake-exports || true

  if [[ ! -x "${_bin}" ]]; then
    echo "FATAL: native llvm-config not produced at ${_bin}" >&2
    return 1
  fi
  echo "  native llvm-config staged: $("${_bin}" --version 2>&1 | head -1) at ${_bin}"
}
