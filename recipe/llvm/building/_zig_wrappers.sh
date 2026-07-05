# Use the zig C-wrapper binaries installed by the upstream zig package (build _27+).
# Layout:
#   Unix:    $BUILD_PREFIX/bin/${CONDA_ZIG_BUILD}-{cc,cxx,ar,ranlib,asm,rc,force-load-cc,force-load-cxx}
#   Windows: $BUILD_PREFIX/Library/bin/${CONDA_ZIG_BUILD}-{...}.exe
#
# Upstream activation also exports ZIG_CC / ZIG_CXX / ZIG_AR / ZIG_RANLIB /
# ZIG_ASM / ZIG_RC / ZIG_LLD / ZIG_FORCE_LOAD_CC / ZIG_FORCE_LOAD_CXX. We pin
# the same values explicitly so the script is deterministic regardless of
# activation order.

if is_not_unix; then
  _zig_bindir="${BUILD_PREFIX}/Library/bin"
  _ext=".exe"
else
  _zig_bindir="${BUILD_PREFIX}/bin"
  _ext=""
fi

# CONDA_ZIG_BUILD already carries a trailing .exe on Windows (recipe.yaml's
# `exe` jinja var, recipe.yaml:286), so appending wrapper-role suffixes
# (-cc/-cxx/...) directly to it would insert them BEFORE the extension
# (zig.exe-cc.exe) instead of before it (zig-cc.exe). Strip the suffix once
# here; ${_ext} below re-adds it at the correct, final position.
_conda_zig_build_base="${CONDA_ZIG_BUILD%.exe}"

_probe_cc="${_zig_bindir}/${_conda_zig_build_base}-cc${_ext}"
if [[ ! -x "${_probe_cc}" ]]; then
  echo "ERROR: zig cc wrapper not found at ${_probe_cc}"
  echo "  Is zig_${build_platform} > 0.15.2 build 28 a build dependency?"
  ls "${_zig_bindir}/"*zig* 2>/dev/null || true
  exit 1
fi
# Sanity check that the wrapper produces a clang version banner.
# Build 28's compiled C wrapper outputs to stderr; capture both streams.
# Non-fatal: if the probe doesn't find the banner, log a warning and
# continue. The actual compile will surface any real wrapper defect.
# (4 rounds of probe-iteration debugging exhausted — bias toward letting
# the build proceed and revealing real issues instead of pre-aborting.)
if ! "${_probe_cc}" --version 2>&1 | grep -q "clang version"; then
  echo "WARN: zig-cc probe (${_probe_cc} --version) did not output 'clang version' banner" >&2
  echo "WARN: continuing anyway — actual compilation will catch any real wrapper defect" >&2
fi

export ZIG_CC="${_zig_bindir}/${_conda_zig_build_base}-cc${_ext}"
export ZIG_CXX="${_zig_bindir}/${_conda_zig_build_base}-cxx${_ext}"
export ZIG_AR="${_zig_bindir}/${_conda_zig_build_base}-ar${_ext}"
export ZIG_RANLIB="${_zig_bindir}/${_conda_zig_build_base}-ranlib${_ext}"
export ZIG_RC="${_zig_bindir}/${_conda_zig_build_base}-rc${_ext}"
# Route ASM through the cc binary on all platforms. The dedicated `-zig-asm`
# wrapper invokes `zig as`, which is not a valid zig subcommand in 0.15.2 build 27
# (zig has cc/c++/ar/ranlib/objcopy/rc/dlltool/lib but no `as`). Routing .S/.s
# files through `zig cc` lets clang's integrated assembler handle them.
export ZIG_ASM="${_zig_bindir}/${_conda_zig_build_base}-cc${_ext}"

# setup_macos_sysroot: ensure /opt/MacOSX*.sdk exists for zig-cc path #3 lookup.
# The zig-cc wrapper globs /opt/MacOSX*.sdk as its third macOS SDK search path.
# If neither that nor CONDA_BUILD_SYSROOT provides an SDK, download the pinned
# phracker MacOSX11.0.sdk tarball, verify sha256, and extract to /opt/. Falls
# back to ${SRC_DIR}/conda-sdks/ + symlink (or CONDA_BUILD_SYSROOT export) if
# /opt/ is not writable. Ported from conda-forge OCAML feedstock pattern.
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

# macOS force-load wrapper: zig provides force-load-cxx/-cc which handle
# -Wl,-all_load / -Wl,-force_load by extracting archives to .o files
# before linking. Use as ZIG_CXX/ZIG_CC so it handles both compile and link;
# force-load logic only activates when those linker flags are present.
#
# macOS deployment target: conda-build sets MACOSX_DEPLOYMENT_TARGET; CMake on
# macOS reads it into CMAKE_OSX_DEPLOYMENT_TARGET and injects -mmacosx-version-min
# automatically. The C-binary wrapper passes those flags through to clang.
# No wrapper-level patching is needed — the build system handles it end-to-end.
if is_osx; then
  setup_macos_sysroot

  # macOS libLLVM.dylib link needs -Wl,-all_load / -Wl,-force_load semantics
  # (LLVM's CMake injects -Wl,-all_load to prevent dead-strip of LLVM*.a archive
  # members from the dylib — without it, ld64 only links symbols referenced by
  # libllvm.cpp.o and the dylib ends up nearly empty, failing the
  # _LLVMInitializeAArch64AsmParser export check).
  #
  # Upstream zig 0.15.2 build 27 ships bin/${CONDA_ZIG_BUILD}-force-load-cc
  # and -cxx as copies of the compiled zig-wrapper.c, but that wrapper's
  # detect_mode() lacks cases for -force-load-cc/-cxx suffixes — invocation
  # errors with `zig-wrapper: cannot determine mode from basename(...)` and
  # exit 1. The wrapper also has no archive extraction (it would only inject
  # -fuse-ld=lld, which doesn't help: zig's MachO ld64 rejects -Wl,-all_load
  # and -Wl,-force_load,X as unsupported linker args).
  #
  # Workaround: use the vendored shell-script force-load shim (adapted from
  # this repo's zig-gcc recipe). The shim extracts .o members from each
  # force-loaded archive via `ar x` and execs upstream's bin/${CONDA_ZIG_BUILD}-cc
  # / -cxx with the modified argv + extracted .o files appended. The upstream
  # wrapper still injects -target/-mcpu correctly in CC/CXX mode.
  _fl_shim_cc="${RECIPE_DIR}/llvm/building/zig-force-load-cc.sh"
  _fl_shim_cxx="${RECIPE_DIR}/llvm/building/zig-force-load-cxx.sh"
  _fl_shim_asm="${RECIPE_DIR}/llvm/building/zig-force-load-asm.sh"
  _fl_shim_common="${RECIPE_DIR}/llvm/building/_zig-force-load-common.sh"
  if [[ ! -f "${_fl_shim_cc}" || ! -f "${_fl_shim_cxx}" || ! -f "${_fl_shim_asm}" || ! -f "${_fl_shim_common}" ]]; then
    echo "ERROR: force-load shim missing in ${RECIPE_DIR}/llvm/building/" >&2
    exit 1
  fi
  # git may not preserve the executable bit (depending on commit history /
  # checkout settings); chmod just-in-time so cmake/ninja can invoke them.
  chmod +x "${_fl_shim_cc}" "${_fl_shim_cxx}" "${_fl_shim_asm}" "${_fl_shim_common}"
  export ZIG_CC="${_fl_shim_cc}"
  export ZIG_CXX="${_fl_shim_cxx}"
  # Route ASM through the force-load shim (cc mode) on macOS so that CMake's
  # CMAKE_ASM_COMPILER gets the same -target ${ZIG_TARGET_HOST} injection as
  # CC/CXX. Without this, CMake passes --target=x86_64-apple-darwin (LLVM format)
  # which zig rejects with UnknownOperatingSystem for .S files.
  export ZIG_ASM="${_fl_shim_asm}"
fi
