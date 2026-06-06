# === BOOTSTRAP: compile zig-wrapper.c with the host CC ===
# zig_impl_<plat> only ships the <triplet>-zig binary; no pre-built wrappers.
# We compile the unified zig-wrapper.c (already present in recipe/building/)
# using the conda host CC, substituting compile-time placeholders, then copy
# the resulting binary under every suffix name expected by consumers.

# Locate all bootstrap zig binaries. Windows installs under Library/bin/ with .exe suffix.
# On linux cross-builds there may be multiple triplets (e.g. x86_64-conda-linux-gnu-zig
# AND powerpc64le-conda-linux-gnu-zig). Install wrappers for every triplet found.
if is_not_unix; then
    _zig_bins=( "${BUILD_PREFIX}/Library/bin/"*-zig.exe )
else
    _zig_bins=( "${BUILD_PREFIX}/bin/"*-zig )
fi
# Verify at least one executable was found
_found_any=0
for _b in "${_zig_bins[@]}"; do [[ -x "${_b}" ]] && { _found_any=1; break; }; done
if [[ "${_found_any}" -eq 0 ]]; then
    echo "ERROR: bootstrap zig binary not found"
    echo "  Searched: ${BUILD_PREFIX}/bin/*-zig and ${BUILD_PREFIX}/Library/bin/*-zig.exe"
    ls "${BUILD_PREFIX}/bin/" 2>/dev/null || true
    ls "${BUILD_PREFIX}/Library/bin/" 2>/dev/null || true
    exit 1
fi
unset _b _found_any

_bootstrap_recipe_dir="${RECIPE_DIR:-${SRC_DIR}/../recipe}"
_wrapper_src="${_bootstrap_recipe_dir}/building/zig-wrapper.c"
if [[ ! -f "${_wrapper_src}" ]]; then
    echo "ERROR: zig-wrapper.c not found at ${_wrapper_src}"
    exit 1
fi

_wrapper_objdir="${SRC_DIR}/_zig_wrapper_build"
mkdir -p "${_wrapper_objdir}"

# Platform-specific output directory and exe suffix
if is_not_unix; then
    _wrapper_bin_dir="${BUILD_PREFIX}/Library/bin"
    _exe_suffix=".exe"
else
    _wrapper_bin_dir="${BUILD_PREFIX}/bin"
    _exe_suffix=""
fi
mkdir -p "${_wrapper_bin_dir}"

for _zig_bin in "${_zig_bins[@]}"; do
    [[ -x "${_zig_bin}" ]] || continue
    echo "  Bootstrap zig: ${_zig_bin}"

    # Derive conda_triplet from binary name: strip trailing -zig (and .exe on Windows)
    _conda_triplet=$(basename "${_zig_bin}" .exe)
    _conda_triplet="${_conda_triplet%-zig}"
    echo "  Conda triplet: ${_conda_triplet}"

    # Translate conda triplet -> zig-canonical ZIG_TRIPLET that `zig -target` accepts.
    case "${_conda_triplet}" in
        *-apple-darwin*)
            _arch="${_conda_triplet%%-apple-darwin*}"
            _osver="${_conda_triplet##*-apple-darwin}"
            [[ "${_arch}" == "arm64" ]] && _arch="aarch64"
            _zig_triplet_for_bin="${_arch}-macos.${_osver}-none"
            unset _arch _osver
            ;;
        *-conda-*)
            _zig_triplet_for_bin="${_conda_triplet//-conda-/-}"
            ;;
        x86_64-w64-mingw32)
            _zig_triplet_for_bin="x86_64-windows-gnu"
            ;;
        i686-w64-mingw32)
            _zig_triplet_for_bin="i686-windows-gnu"
            ;;
        aarch64-w64-mingw32)
            _zig_triplet_for_bin="aarch64-windows-gnu"
            ;;
        *)
            _zig_triplet_for_bin="${_conda_triplet}"
            ;;
    esac

    # Wrapper's baked default -target (matches reference build.sh:388-393)
    case "${target_platform:-}" in
        win-64)    _wrapper_default_target="x86_64-windows-gnu" ;;
        win-arm64) _wrapper_default_target="aarch64-windows-gnu" ;;
        win-32)    _wrapper_default_target="x86-windows-gnu" ;;
        *)         _wrapper_default_target="${_zig_triplet_for_bin%%.[0-9]*}" ;;
    esac

    # Prefer bare zig; fall back to triplet-prefixed binary if zig_impl_* drops the symlink.
    if is_not_unix; then
        if [[ -e "${BUILD_PREFIX}/Library/bin/zig.exe" ]]; then
            _real_zig_path="${BUILD_PREFIX}/Library/bin/zig.exe"
        else
            _real_zig_path="${_zig_bin}"
        fi
    else
        if [[ -e "${BUILD_PREFIX}/bin/zig" ]]; then
            _real_zig_path="${BUILD_PREFIX}/bin/zig"
        else
            _real_zig_path="${_zig_bin}"
        fi
    fi

    # Windows: convert backslash to forward slash to avoid C string escape sequences.
    # On Windows, _real_zig_path may be a backslash path (e.g. D:\a\1\s\...). When
    # sed-substituted into #define ZIG_REAL_PATH "@ZIG_REAL_PATH@", the backslash
    # sequences (\a, \1, \r, \s, etc.) are interpreted as C escape sequences inside
    # the string literal. Forward slashes are accepted by both mingw and zig.
    if is_not_unix; then
        _real_zig_path="${_real_zig_path//\\//}"
    fi

    # Substitute compile-time placeholders into a per-triplet copy of the source
    _wrapper_c="${_wrapper_objdir}/${_conda_triplet}-zig-wrapper-substituted.c"
    sed -e "s|@ZIG_TARGET@|${_wrapper_default_target}|g" \
        -e "s|@ZIG_REAL_PATH@|${_real_zig_path}|g" \
        "${_wrapper_src}" > "${_wrapper_c}"

    # Compile primary wrapper binary using the host CC
    _primary_wrapper="${_wrapper_bin_dir}/${_conda_triplet}-zig-cc${_exe_suffix}"
    echo "  Compiling wrapper: ${_primary_wrapper}"
    # -I the source building/ dir so the quoted #include "wrapper_utils.h" in
    # zig-wrapper.c resolves (only the .c is staged into _wrapper_objdir; the
    # shared header stays in recipe/building/).
    "${_real_zig_path}" cc -O2 -I"${_bootstrap_recipe_dir}/building" \
        -o "${_primary_wrapper}" "${_wrapper_c}" \
        || { echo "ERROR: zig-wrapper.c compile failed for ${_conda_triplet}"; exit 1; }

    # Install ergonomic-name copies (8 suffix names; zig-cc already at _primary_wrapper)
    for _suffix in zig-cxx zig-ar zig-ranlib zig-asm zig-rc zig-lld zig-force-load-cc zig-force-load-cxx; do
        cp -f "${_primary_wrapper}" "${_wrapper_bin_dir}/${_conda_triplet}-${_suffix}${_exe_suffix}"
    done

    unset _zig_triplet_for_bin _wrapper_default_target _wrapper_c _primary_wrapper _suffix
    echo "  Wrappers installed for: ${_conda_triplet}"
done

unset _zig_bin _zig_bins _conda_triplet _wrapper_src _wrapper_objdir _bootstrap_recipe_dir

# Re-derive _conda_triplet for env-var exports: prefer the triplet matching
# CONDA_TOOLCHAIN_HOST (the build-host compiler), falling back to the first binary.
if is_not_unix; then
    _first_zig=$(ls "${BUILD_PREFIX}/Library/bin/"*-zig.exe 2>/dev/null | head -1 || true)
else
    _first_zig=$(ls "${BUILD_PREFIX}/bin/"*-zig 2>/dev/null | head -1 || true)
fi
_conda_triplet=$(basename "${_first_zig}" .exe)
_conda_triplet="${_conda_triplet%-zig}"
if [[ -n "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
    _host_zig="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-zig"
    is_not_unix && _host_zig="${BUILD_PREFIX}/Library/bin/${CONDA_TOOLCHAIN_HOST}-zig.exe"
    if [[ -x "${_host_zig}" ]]; then
        _conda_triplet="${CONDA_TOOLCHAIN_HOST}"
    fi
fi
unset _first_zig _host_zig
echo "  Active triplet for ZIG_CC/CXX exports: ${_conda_triplet}"

# Export ZIG_CC etc. pointing at the compiled binaries
export ZIG_WRAPPERS="${_wrapper_bin_dir}"
export ZIG_CC="${_wrapper_bin_dir}/${_conda_triplet}-zig-cc${_exe_suffix}"
export ZIG_CXX="${_wrapper_bin_dir}/${_conda_triplet}-zig-cxx${_exe_suffix}"
export ZIG_AR="${_wrapper_bin_dir}/${_conda_triplet}-zig-ar${_exe_suffix}"
export ZIG_RANLIB="${_wrapper_bin_dir}/${_conda_triplet}-zig-ranlib${_exe_suffix}"
export ZIG_ASM="${_wrapper_bin_dir}/${_conda_triplet}-zig-asm${_exe_suffix}"
export ZIG_RC="${_wrapper_bin_dir}/${_conda_triplet}-zig-rc${_exe_suffix}"
if [[ -x "${_wrapper_bin_dir}/${_conda_triplet}-zig-lld${_exe_suffix}" ]]; then
  export ZIG_LLD="${_wrapper_bin_dir}/${_conda_triplet}-zig-lld${_exe_suffix}"
fi

for _v in ZIG_CC ZIG_CXX ZIG_AR ZIG_RANLIB ZIG_ASM; do
  _path="${!_v}"
  if [[ ! -x "${_path}" ]]; then
    echo "ERROR: expected wrapper ${_v}=${_path} not executable after compile"
    ls "${_wrapper_bin_dir}/" 2>/dev/null || true
    exit 1
  fi
done
echo "  Wrappers installed: ${_wrapper_bin_dir}"

# ZIG_FORCE_LOAD_CC / ZIG_FORCE_LOAD_CXX: compiled binaries (same binary, different suffix name)
if [[ -x "${_wrapper_bin_dir}/${_conda_triplet}-zig-force-load-cc${_exe_suffix}" ]]; then
  export ZIG_FORCE_LOAD_CC="${_wrapper_bin_dir}/${_conda_triplet}-zig-force-load-cc${_exe_suffix}"
fi
if [[ -x "${_wrapper_bin_dir}/${_conda_triplet}-zig-force-load-cxx${_exe_suffix}" ]]; then
  export ZIG_FORCE_LOAD_CXX="${_wrapper_bin_dir}/${_conda_triplet}-zig-force-load-cxx${_exe_suffix}"
fi

unset _conda_triplet _wrapper_bin_dir _exe_suffix _v _path
# === END BOOTSTRAP ===

# setup_macos_sysroot: ensure /opt/MacOSX*.sdk exists for zig-cc path #3 lookup.
# The zig-cc wrapper (_zig-cc-common.sh) globs /opt/MacOSX*.sdk as its third
# macOS SDK search path. If neither that nor CONDA_BUILD_SYSROOT provides an
# SDK, download the pinned phracker MacOSX11.0.sdk tarball, verify sha256, and
# extract to /opt/. Falls back to ${SRC_DIR}/conda-sdks/ + symlink (or
# CONDA_BUILD_SYSROOT export) if /opt/ is not writable.
# Ported from conda-forge OCAML feedstock pattern (known-working).
setup_macos_sysroot() {
  local _sdk_primary="/opt"
  local _sdk_fallback="${SRC_DIR}/conda-sdks"
  local _sdk_url="https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX11.0.sdk.tar.xz"
  local _sdk_sha="d3feee3ef9c6016b526e1901013f264467bb927865a03422a9cb925991cc9783"
  local _sdk_name="MacOSX11.0.sdk"
  local _sdk_tarball="${_sdk_name}.tar.xz"

  # Path #3: /opt/MacOSX*.sdk glob — early-exit if already present
  for _existing in /opt/MacOSX*.sdk; do
    if [[ -d "${_existing}" ]]; then
      echo "  macOS SDK already present at path #3: ${_existing}"
      return 0
    fi
  done

  # CONDA_BUILD_SYSROOT (set by conda-build on native macOS via Xcode)
  if [[ -d "${CONDA_BUILD_SYSROOT:-}" ]]; then
    echo "  macOS SDK via CONDA_BUILD_SYSROOT: ${CONDA_BUILD_SYSROOT}"
    return 0
  fi

  echo "  Downloading macOS SDK (${_sdk_name})..."

  local _sdk_dir
  if mkdir -p "${_sdk_primary}" 2>/dev/null && [[ -w "${_sdk_primary}" ]]; then
    _sdk_dir="${_sdk_primary}"
    echo "  Extracting to ${_sdk_dir}/ (path #3 glob will find it)"
  else
    _sdk_dir="${_sdk_fallback}"
    mkdir -p "${_sdk_dir}"
    echo "  /opt/ not writable, extracting to ${_sdk_dir}/"
  fi

  curl -L --output "${_sdk_dir}/${_sdk_tarball}" "${_sdk_url}"
  echo "${_sdk_sha}  ${_sdk_dir}/${_sdk_tarball}" | shasum -a 256 -c

  echo "  Extracting ${_sdk_name}..."
  python3 << PYEOF
import lzma, tarfile
tarball = "${_sdk_dir}/${_sdk_tarball}"
outdir = "${_sdk_dir}"
with lzma.open(tarball, 'rb') as f:
    with tarfile.open(fileobj=f, mode='r:') as tar:
        tar.extractall(path=outdir, filter='data')
print(f"Extracted to {outdir}")
PYEOF
  if [[ $? -ne 0 ]]; then
    echo "ERROR: macOS SDK extraction failed"
    return 1
  fi

  local _sdk_path="${_sdk_dir}/${_sdk_name}"
  if [[ ! -d "${_sdk_path}" ]]; then
    echo "ERROR: SDK directory not found after extraction: ${_sdk_path}"
    return 1
  fi

  # Fallback path: try symlink into /opt/ for path #3 glob;
  # if symlink fails (no permission), export CONDA_BUILD_SYSROOT instead.
  if [[ "${_sdk_dir}" != "${_sdk_primary}" ]]; then
    if ln -sf "${_sdk_path}" "${_sdk_primary}/${_sdk_name}" 2>/dev/null; then
      echo "  Symlinked: ${_sdk_primary}/${_sdk_name} -> ${_sdk_path}"
    else
      echo "  Symlink to /opt/ failed — exporting CONDA_BUILD_SYSROOT=${_sdk_path}"
      export CONDA_BUILD_SYSROOT="${_sdk_path}"
    fi
  fi

  echo "  macOS SDK ready: ${_sdk_path}"
}

# macOS force-load wrapper: deployment target is baked at compile time into the
# wrapper binary via @ZIG_TARGET@. ZIG_FORCE_LOAD_CXX (compiled binary) handles
# -Wl,-all_load/-Wl,-force_load by extracting archives to .o files in c++ mode.
# Set ZIG_CXX to the force-load variant so CMake uses it for both compile+link.
if is_osx; then
    setup_macos_sysroot

    if [[ -n "${ZIG_FORCE_LOAD_CXX:-}" && -x "${ZIG_FORCE_LOAD_CXX}" ]]; then
        export ZIG_CXX="${ZIG_FORCE_LOAD_CXX}"
    else
        echo "ERROR: ZIG_FORCE_LOAD_CXX not available in environment"
        exit 1
    fi
fi
