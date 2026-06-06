fix_lld_cmake_deps() {
  # The lld static archives (liblldELF.a, etc.) directly reference zlib/zstd
  # symbols for section compression (lld/ELF/OutputSections.cpp). LLVM's cmake
  # declares these only transitively through LLVMSupport, so consumers that
  # link the .a files by path (e.g. zig) miss the dependency. Fix by appending
  # -lz/-lzstd to all lld cmake targets' INTERFACE_LINK_LIBRARIES.
  local lld_config="${LLVM_INSTALL}/lib/cmake/lld/LLDConfig.cmake"
  if [[ ! -f "${lld_config}" ]]; then
    echo "  WARNING: LLDConfig.cmake not found at ${lld_config}, skipping"
    return
  fi

  echo "=== Fixing LLD cmake target dependencies (zlib/zstd) ==="
  local _extra_libs="-lz"
  if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
    _extra_libs="-lz;-lzstd"
  fi

  {
    echo ""
    echo "# zig-llvm fixup: lld static archives directly reference zlib/zstd symbols"
    echo "# (lld/ELF/OutputSections.cpp compression). Ensure consumers link them."
    echo "foreach(_lld_target lldELF lldCOFF lldMachO lldWasm lldMinGW lldCommon)"
    echo "  if(TARGET lld::\${_lld_target})"
    echo "    set_property(TARGET lld::\${_lld_target} APPEND PROPERTY"
    echo "      INTERFACE_LINK_LIBRARIES \"${_extra_libs}\")"
    echo "  endif()"
    echo "endforeach()"
  } >> "${lld_config}"

  echo "  Appended ${_extra_libs} to ${lld_config}"
}

post_install() {
  set +x
  
  if [[ "${target_platform}" == linux-* ]]; then
    echo "=== Fixing NEEDED entries in shared libraries ==="
    # CMake sometimes records build-tree relative paths (e.g. lib/libLLVM.so.20.1)
    # instead of bare sonames in NEEDED entries. Fix all .so files unconditionally
    # so the package is always correct regardless of CMake/linker behaviour.
    find "${LLVM_INSTALL}/lib" -name '*.so*' -not -type l | while read -r lib; do
      while read -r needed; do
        if [[ "${needed}" == */* ]]; then
          bare=$(basename "${needed}")
          echo "  Fixing NEEDED in $(basename ${lib}): ${needed} -> ${bare}"
          patchelf --replace-needed "${needed}" "${bare}" "${lib}"
        fi
      done < <(readelf -d "${lib}" 2>/dev/null | grep NEEDED | grep -oP '(?<=\[).*(?=\])' || true)
    done

    echo "=== Adding libc++ NEEDED entry via patchelf ==="
    # libc++abi is statically merged into libc++ on all platforms, so only
    # libc++.so.1 needs to be in NEEDED (no separate libc++abi.so).
    for _lib in "${LLVM_INSTALL}/lib/libLLVM"*.so.* "${LLVM_INSTALL}/lib/libclang-cpp"*.so.*; do
      [[ -L "${_lib}" ]] && continue  # skip symlinks
      [[ ! -f "${_lib}" ]] && continue
      echo "  Patching $(basename ${_lib}):"
      if ! readelf -d "${_lib}" | grep NEEDED | grep -q 'libc++\.so'; then
        patchelf --add-needed libc++.so.1 "${_lib}"
        echo "    added NEEDED libc++.so.1"
      else
        echo "    already has libc++.so.1"
      fi
      echo "    NEEDED entries:"
      readelf -d "${_lib}" | grep NEEDED || true
    done

    echo "=== Quick check: libc++ symbol binding ==="
    _fail=0
    for _lib in "${LLVM_INSTALL}/lib/libLLVM"*.so.* "${LLVM_INSTALL}/lib/libclang-cpp"*.so.*; do
      [[ -L "${_lib}" ]] && continue
      [[ ! -f "${_lib}" ]] && continue
      _bind=$(nm -a "${_lib}" 2>/dev/null | grep 'generic_category' | head -1 || true)
      echo "  $(basename ${_lib}): ${_bind:-not found}"
      if echo "${_bind}" | grep -q '^[0-9a-f]* t '; then
        echo "  FAIL: LOCAL_DEFINED — static libc++ merged in"
        _fail=1
      fi
    done
    if [[ ${_fail} -ne 0 ]]; then
      echo "ERROR: libLLVM/libclang-cpp have private libc++ copies."
      echo "       zig will fail: 'LLVM and Clang have separate copies of libc++'"
      echo "       The -nostdlib++ wrapper or link flags are not preventing static merge."
      exit 1
    fi
    echo "  OK: no local generic_category — no static libc++ merge"
  fi

  if [[ "${target_platform}" == osx-* ]]; then
    # llvm-config.real links against @rpath/libz.1.dylib, but the rpath only
    # includes $PREFIX/lib/zig-llvm/lib/ where our LLVM libs live.  zlib is in
    # $PREFIX/lib/ (conda zlib package).  Add it as an additional rpath.
    echo "=== Fixing rpaths for macOS binaries ==="
    local _conda_lib
    if [[ -n "${PREFIX:-}" ]]; then
      _conda_lib="${PREFIX}/lib"
    else
      _conda_lib="${LLVM_INSTALL}/../../../lib"
    fi
    for _bin in "${LLVM_INSTALL}/bin/llvm-config.real" "${LLVM_INSTALL}/bin/llvm-config.real.exe"; do
      if [[ -f "${_bin}" ]]; then
        echo "  Adding rpath ${_conda_lib} to $(basename "${_bin}")"
        install_name_tool -add_rpath "${_conda_lib}" "${_bin}" 2>/dev/null || true
      fi
    done
    # Also fix tblgen tools that may have the same issue
    for _bin in "${LLVM_INSTALL}/bin/"*-tblgen; do
      if [[ -f "${_bin}" ]] && [[ ! -L "${_bin}" ]]; then
        echo "  Adding rpath ${_conda_lib} to $(basename "${_bin}")"
        install_name_tool -add_rpath "${_conda_lib}" "${_bin}" 2>/dev/null || true
      fi
    done

    # ----------------------------------------------------------------
    # Step 2: Rewrite @rpath/<lib> -> @loader_path/<lib> in all dylibs
    # ----------------------------------------------------------------
    # The recipe sets binary_relocation: false to prevent rattler-build's
    # relinker from rewriting our @loader_path back to @rpath. But we
    # must also patch the existing @rpath/* references the zig-cc linker
    # embedded at build time, otherwise dyld can't find e.g.
    # @rpath/libunwind.1.dylib when libc++.1.0.dylib is loaded from a
    # process whose LC_RPATH doesn't include our private lib dir.
    #
    # Strategy: for every dylib in LLVM_INSTALL/lib/, iterate its
    # LC_LOAD_DYLIB entries; if a referenced dylib's basename also
    # exists in the same dir, rewrite the reference to @loader_path/<basename>.
    # Also set LC_ID_DYLIB to @loader_path/<basename> so consumers
    # outside this dir can locate it via their own LC_RPATH.
    echo "  osx: Step 2 — @rpath -> @loader_path in ${LLVM_INSTALL}/lib/"
    _rewrite_count=0
    for _dylib in "${LLVM_INSTALL}/lib/"*.dylib; do
        [[ -f "${_dylib}" ]] || continue
        _dylib_basename=$(basename "${_dylib}")
        # Set install name to @loader_path/<basename>
        install_name_tool -id "@loader_path/${_dylib_basename}" "${_dylib}" 2>/dev/null || true
        # Rewrite each LC_LOAD_DYLIB entry
        while IFS= read -r _dep; do
            [[ -z "${_dep}" ]] && continue
            _dep_basename=$(basename "${_dep}")
            # Skip self-reference
            [[ "${_dep_basename}" == "${_dylib_basename}" ]] && continue
            # Determine the rewrite target based on where the dep actually lives.
            # - dylibs in ${LLVM_INSTALL}/lib/ → @loader_path/<basename>
            # - external deps in ${PREFIX}/lib/ → @loader_path/../../<basename>
            #   (from $PREFIX/lib/zig-llvm/lib/, ../../ resolves to $PREFIX/lib/)
            if [[ -f "${LLVM_INSTALL}/lib/${_dep_basename}" ]]; then
                _new_dep="@loader_path/${_dep_basename}"
            elif [[ -f "${PREFIX}/lib/${_dep_basename}" ]]; then
                _new_dep="@loader_path/../../${_dep_basename}"
            else
                # Dep not found in either expected location — leave @rpath as-is
                # so the failure surfaces in Step 4 verification with a clear name.
                continue
            fi
            # Skip if already rewritten to the target
            [[ "${_dep}" == "${_new_dep}" ]] && continue
            install_name_tool -change "${_dep}" "${_new_dep}" "${_dylib}" 2>/dev/null || true
            _rewrite_count=$((_rewrite_count + 1))
        done < <(otool -L "${_dylib}" | awk 'NR>1 {print $1}')
    done
    echo "  osx: Step 2 done — ${_rewrite_count} dylib refs rewritten to @loader_path"

    # ----------------------------------------------------------------
    # Step 3: Strip non-prefix LC_RPATH entries from all dylibs
    # ----------------------------------------------------------------
    # rattler-build strips rpaths not in its allowlist; we strip them
    # ourselves first so the build is deterministic regardless of
    # rattler-build's behavior on binary_relocation: false.
    echo "  osx: Step 3 — stripping non-prefix LC_RPATH from dylibs"
    for _dylib in "${LLVM_INSTALL}/lib/"*.dylib; do
        [[ -f "${_dylib}" ]] || continue
        while IFS= read -r _rpath; do
            [[ -z "${_rpath}" ]] && continue
            # Keep @loader_path-anchored rpaths; strip everything else
            [[ "${_rpath}" == @loader_path* ]] && continue
            install_name_tool -delete_rpath "${_rpath}" "${_dylib}" 2>/dev/null || true
        done < <(otool -l "${_dylib}" | awk '/LC_RPATH/{f=1;next} f && /path /{print $2; f=0}')
    done

    # ----------------------------------------------------------------
    # Step 4: Verify no @rpath survives in any dylib in LLVM_INSTALL/lib
    # ----------------------------------------------------------------
    echo "  osx: Step 4 — verifying no @rpath survives"
    _surviving_rpath=0
    for _dylib in "${LLVM_INSTALL}/lib/"*.dylib; do
        [[ -f "${_dylib}" ]] || continue
        if otool -L "${_dylib}" | awk 'NR>1 {print $1}' | grep -q '^@rpath/'; then
            echo "    FAIL: @rpath survives in ${_dylib}:"
            otool -L "${_dylib}" | awk 'NR>1 {print "      "$1}' | grep '^      @rpath/' || true
            _surviving_rpath=$((_surviving_rpath + 1))
        fi
    done
    if (( _surviving_rpath > 0 )); then
        echo "  osx: Step 4 FAILED — ${_surviving_rpath} dylibs still have @rpath references"
        exit 1
    fi
    echo "  osx: Step 4 PASSED — all @rpath refs rewritten to @loader_path"
  fi

  if [[ "${target_platform}" == linux-* ]]; then
    # llvm-config.real and tblgen tools link against libunwind.so.1 from
    # the zig-llvm runtimes. LLVM's llvm_setup_rpath() sets BUILD_WITH_INSTALL_RPATH
    # which may not embed the correct RPATH for the installed location.
    # Use $ORIGIN-relative RPATH so it works in any prefix (build, test, install).
    # Binaries are in lib/zig-llvm/bin/, libs in lib/zig-llvm/lib/.
    echo "=== Fixing RPATH for Linux binaries ==="
    for _bin in "${LLVM_INSTALL}/bin/"*; do
      if [[ -f "${_bin}" ]] && [[ ! -L "${_bin}" ]] && file "${_bin}" | grep -q 'ELF'; then
        echo "  Setting RPATH on $(basename "${_bin}")"
        patchelf --set-rpath '$ORIGIN/../lib' "${_bin}" 2>/dev/null || true
      fi
    done
    echo "=== Fixing RPATH for Linux shared libraries ==="
    for _lib in "${LLVM_INSTALL}/lib/"*.so*; do
      if [[ -f "${_lib}" ]] && [[ ! -L "${_lib}" ]]; then
        echo "  Setting RPATH on $(basename "${_lib}")"
        patchelf --set-rpath '$ORIGIN:$ORIGIN/../..' "${_lib}" 2>/dev/null || true
      fi
    done
  fi

  if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
    echo "=== Stripping debug info from shared libraries ==="
    find "${LLVM_INSTALL}/lib" \( -name '*.so*' -o -name '*.dylib' \) -not -type l | while read -r lib; do
      echo "  Stripping: $(basename "${lib}")"
      llvm-strip --strip-debug "${lib}" 2>/dev/null || strip --strip-debug "${lib}" 2>/dev/null || true
    done
  fi
  set -x
}
