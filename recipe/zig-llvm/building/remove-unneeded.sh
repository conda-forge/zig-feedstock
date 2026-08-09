function remove_unneeded() {
  if [[ -f "${SRC_DIR}/.zig_local_iterate" ]]; then
    echo "  .zig_local_iterate sentinel present: skipping .a/tool/share pruning in ${LLVM_INSTALL} to keep a complete, self-consistent install for incremental local rebuilds (llvm-config wrapper setup below still runs unconditionally)"
  else
    # Remove static libraries - zig only needs shared libs (saves ~500MB)
    # Keep .dll.a import libraries on Windows (needed to link against DLLs)
    # liblld*.a are bundled into liblldZig.so/.dylib/.dll by build_lld_bundle
    # and are no longer needed as standalone archives — EXCEPT on linux-riscv64
    # and linux-s390x where liblldZig.so is not built (no shared zstd/xml2/z
    # available from conda-forge for those arches).  On those platforms keep the
    # six individual liblld*.a archives so zig-zig can link them statically.
    if [[ "${target_platform}" == win-* ]]; then
      # Windows: zig's zigcpp links lld via the import-lib/bundle path, not the raw
      # liblld*.a static archives, so drop them now (kept .dll.a import libs).
      find "${LLVM_INSTALL}/lib" -name "*.a" ! -name "*.dll.a" -type f -delete
      echo "  Removed .a files from ${LLVM_INSTALL}/lib (kept .dll.a import libs; liblld*.a folded into liblldZig bundle)"
    else
      # Unix: KEEP liblld*.a here. zig's own find_package(LLD) static-links them into
      # zigcpp during build-zig.sh (build_zig_with_zig), which runs as a separate later
      # script (recipe/build.sh:150). A deferred cleanup in build-zig.sh removes them
      # once the self-build has consumed them. linux-riscv64/linux-s390x have no
      # liblldZig bundle and keep the archives permanently for static linking, so they
      # are excluded from that later cleanup too. Non-lld static archives are still
      # dropped here.
      find "${LLVM_INSTALL}/lib" -name "*.a" ! -name "*.dll.a" ! -name "liblld*.a" -type f -delete
      echo "  Removed non-lld .a files from ${LLVM_INSTALL}/lib (kept .dll.a import libs; kept liblld*.a for zig self-build + deferred cleanup)"
    fi

    # Explicitly remove C++ runtime static archives (libc++, libc++abi, libc++experimental,
    # libunwind). These are installed by the runtimes build and must not ship — zig consumers
    # must link against the shared dylib/so, not a static copy. Use rm -f (idempotent).
    _cxx_static_removed=0
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
    # llvm-dlltool is a symlink to llvm-ar — resolve it to a standalone copy before deleting llvm-ar
    if [[ -L "${LLVM_INSTALL}/bin/llvm-dlltool" ]]; then
      _target="$(readlink -f "${LLVM_INSTALL}/bin/llvm-dlltool")"
      rm "${LLVM_INSTALL}/bin/llvm-dlltool"
      cp "${_target}" "${LLVM_INSTALL}/bin/llvm-dlltool"
    fi
    find "${LLVM_INSTALL}/bin" \( -type f -o -type l \) ! \( -name "llvm-config*" -o -name "*-tblgen" -o -name "*-tblgen.exe" -o -name "llvm-dlltool*" -o -name "*.dll" \) -delete

    # Remove share/ directory (clang-format helpers, cmake modules we don't need)
    rm -rf "${LLVM_INSTALL}/share"
    echo "  Removed ${LLVM_INSTALL}/share"
  fi

  # Self-heal: llvm-config can be absent from ${LLVM_INSTALL}/bin at this point
  # (observed: PR #123, win_64_cross_target_platform_win-64, 2026-07-26 — neither
  # llvm-config nor llvm-config.exe existed here, so the rename below silently
  # failed via `mv: cannot stat`, leaving a broken wrapper with no real binary to
  # invoke, which surfaces much later as zig's own cmake/Findllvm.cmake reporting
  # "unable to find llvm-config"; the exact upstream/ninja-graph cause was not
  # conclusively identified). Force an explicit targeted (re)build+install against
  # the already-configured tree before assuming the binary exists — mirrors the
  # same cmake --build --target llvm-config / cmake --install --component
  # llvm-config pattern _native_llvm_config.sh already uses for its build-arch
  # bootstrap tree.
  if [[ ! -f "${LLVM_INSTALL}/bin/llvm-config" && ! -f "${LLVM_INSTALL}/bin/llvm-config.exe" ]]; then
    echo "  WARNING: llvm-config missing from ${LLVM_INSTALL}/bin after the main LLVM build; forcing an explicit rebuild" >&2
    cmake --build "${LLVM_BUILD}" --target llvm-config -j"${CPU_COUNT}"
    cmake --install "${LLVM_BUILD}" --component llvm-config
  fi
  if [[ ! -f "${LLVM_INSTALL}/bin/llvm-config" && ! -f "${LLVM_INSTALL}/bin/llvm-config.exe" ]]; then
    echo "FATAL: llvm-config still missing at ${LLVM_INSTALL}/bin after explicit rebuild" >&2
    return 1
  fi

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

  # Windows: do NOT create the flag-filtering wrapper under the bare
  # "llvm-config" name. zig's own cmake/Findllvm.cmake does
  # find_program(LLVM_CONFIG_EXE NAMES ... llvm-config) and CMake's search
  # tries each candidate NAME AS-IS *before* NAME+".exe" -- so if a bare
  # "llvm-config" file exists here, find_program resolves to IT even though a
  # working "llvm-config.exe" also exists. The bare file is a "#!/bin/sh"
  # script; native CreateProcess (used by execute_process(COMMAND
  # ${LLVM_CONFIG_EXE} --version ...)) cannot run a shebang script and fails to
  # launch, so OUTPUT_VARIABLE comes back EMPTY -- surfacing ~90min later as
  # "expected LLVM 21.x but found  using .../llvm-config" (PR #123 win-64 CI,
  # win_64_cross_target_platform_win-64, 2026-08-01; the still-present
  # llvm-config.bat launcher added for the prior "unable to find llvm-config"
  # bug is never reached because find_program never gets that far). Ship the
  # real binary directly as "llvm-config.exe" instead, so find_program's
  # NAME+".exe" candidate is what actually gets used and CreateProcess can run
  # it. The ld-flag filtering below (-Bsymbolic-functions/--disable-new-dtags)
  # targets GNU-ld-only flags that do not appear in a windows-gnu llvm-config's
  # --ldflags/--system-libs output, so skipping it here is safe.
  if [[ "${target_platform}" == win-* ]]; then
    cp "${LLVM_INSTALL}/bin/llvm-config.real.exe" "${LLVM_INSTALL}/bin/llvm-config.exe"
    echo "  Windows: copied llvm-config.real.exe -> llvm-config.exe (unwrapped, native-executable for cmake find_program)"

    # Secondary access point (not used by find_program, kept for any explicit
    # caller of the .bat name / for parity with the old idiom): direct native
    # exec, no bash hop through the now-removed bare wrapper script.
    cat > "${LLVM_INSTALL}/bin/llvm-config.bat" << BAT_EOF
@echo off
"%~dp0llvm-config.real.exe" %*
exit /b %ERRORLEVEL%
BAT_EOF
    chmod +x "${LLVM_INSTALL}/bin/llvm-config.bat"
    echo "  Windows: created llvm-config.bat launcher (direct native exec) at ${LLVM_INSTALL}/bin"
  else
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
  fi
}
