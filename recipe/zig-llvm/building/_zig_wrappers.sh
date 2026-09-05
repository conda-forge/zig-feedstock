# Use the zig C-wrapper binaries installed by the upstream zig package (build _27+).
# Layout:
#   Unix:    $BUILD_PREFIX/bin/${CONDA_BUILD_ZIG}-{cc,cxx,ar,ranlib,asm,rc,force-load-cc,force-load-cxx}
#   Windows: $BUILD_PREFIX/Library/bin/${CONDA_BUILD_ZIG}-{...}.exe
#
# We pin ZIG_CC / ZIG_CXX / ZIG_AR / ZIG_RANLIB / ZIG_RC / ZIG_ASM explicitly
# below so the script is deterministic regardless of activation order.
# ZIG_LLD / ZIG_FORCE_LOAD_CC / ZIG_FORCE_LOAD_CXX are left to upstream
# activation and are not re-pinned here.

if is_not_unix; then
  _zig_bindir="${BUILD_PREFIX}/Library/bin"
  _ext=".exe"
else
  _zig_bindir="${BUILD_PREFIX}/bin"
  _ext=""
fi

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
fi

# ---------------------------------------------------------------------------
# Build-arch zig C wrappers.
#
# zig_impl_<platform> -- our only zig build dep (recipe.yaml:434) -- ships ONLY
# the bare `${CONDA_ZIG_BUILD}` binary.  The `<triplet>-zig-cc` / `-cxx`
# wrappers live in the zig_<platform> ACTIVATION output, which this build
# environment cannot depend on: that output run-requires zig_impl_<platform>,
# so naming it here would be a same-recipe cycle.
#
# So compile the canonical wrapper source ourselves.  recipe/building/zig-cc-unix.c
# is the single source of truth for flag translation and -- since its STEP 10b --
# for the macOS force-load handling that the old recipe/scripts/*.sh shims used
# to provide.  Those shims no longer exist, so this replaces them everywhere.
#
# NAMING IS LOAD-BEARING: mode_from_argv0() (zig-cc-unix.c:684-708) strips
# WRAPPER_PREFIX off basename(argv[0]) and string-compares the remainder against
# "zig-cc" / "zig-cxx" / "zig-asm".  With WRAPPER_PREFIX="${CONDA_TOOLCHAIN_BUILD}-"
# each file must be named "${CONDA_ZIG_BUILD}-<mode>".  A differently-named copy
# resolves to MODE_UNKNOWN, or silently to the wrong mode.
# ---------------------------------------------------------------------------
_zig_bootstrap="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"
if [[ ! -x "${_zig_bootstrap}" ]]; then
  # Conda on Windows installs executables under Library/bin and they carry .exe
  # (cf. _runtimes_build.sh:196, and the same probe in recipe/build.sh).
  _zig_bootstrap="${BUILD_PREFIX}/Library/bin/${CONDA_ZIG_BUILD}.exe"
fi
if [[ ! -x "${_zig_bootstrap}" ]]; then
  echo "FATAL: bootstrap zig not found at ${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD} nor ${BUILD_PREFIX}/Library/bin/${CONDA_ZIG_BUILD}.exe" >&2
  exit 1
fi

_wrap_src="${RECIPE_DIR}/building/zig-cc-unix.c"
if [[ ! -f "${_wrap_src}" ]]; then
  echo "FATAL: wrapper source missing: ${_wrap_src}" >&2
  exit 1
fi

# Bake the BUILD-arch triple, not the target one: these wrappers compile
# host-runnable objects (llvm-config, tblgen).  ZIG_TARGET_BUILD is the
# zig-format build triple (recipe.yaml:397).
_wrap_target="${ZIG_TARGET_BUILD}"
if [[ -z "${_wrap_target}" || "${_wrap_target}" == "native" ]]; then
  # STEP 10 (zig-cc-unix.c:377-387) sets inject_target=!has_target and then
  # injects `-target ${ZIG_TARGET}` verbatim, with NO special case for
  # "native".  Baking an unusable value here would make every later wrapper
  # invocation fail obscurely, so refuse loudly now instead.
  echo "FATAL: ZIG_TARGET_BUILD is unusable ('${ZIG_TARGET_BUILD}')" >&2
  exit 1
fi
case "${_wrap_target}" in
  # glibc floor, matching the existing precedent at _native_llvm_config.sh:78-80
  # and _cross_compile.sh:83 ("${ZIG_TARGET_BUILD}.2.17").
  *-linux-gnu) _wrap_target="${_wrap_target}.2.17" ;;
esac
_wrap_arch="${_wrap_target%%-*}"

_wrap_tmp="$(mktemp -d)"
sed -e "s|@ZIG_BIN@|${_zig_bootstrap}|g" \
    -e "s|@ZIG_TARGET@|${_wrap_target}|g" \
    -e "s|@ZIG_TARGET_ARCH@|${_wrap_arch}|g" \
    -e "s|@WRAPPER_PREFIX@|${CONDA_TOOLCHAIN_BUILD}-|g" \
    "${_wrap_src}" > "${_wrap_tmp}/zig-cc-unix.c"

_wrap_cc="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cc"
echo "=== building build-arch zig wrappers (-target ${_wrap_target}) ==="
"${_zig_bootstrap}" cc -O2 -target "${_wrap_target}" -I"${RECIPE_DIR}/building" \
  -o "${_wrap_cc}" "${_wrap_tmp}/zig-cc-unix.c" || {
  echo "FATAL: failed to compile ${_wrap_src}" >&2
  rm -rf "${_wrap_tmp}"
  exit 1
}
rm -rf "${_wrap_tmp}"

# One binary, many names -- dispatch is by basename only.
for _wrap_n in cxx asm ar ranlib force-load-cc force-load-cxx; do
  cp -f "${_wrap_cc}" "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-${_wrap_n}"
done
chmod +x "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-cc \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-cxx \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-asm \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-ar \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-ranlib \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-force-load-cc \
         "${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}"-force-load-cxx

export ZIG_CC="${_wrap_cc}"
export ZIG_CXX="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-cxx"
export ZIG_ASM="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-asm"
# Consumed unguarded as -DCMAKE_AR / -DCMAKE_RANLIB by _runtimes_build.sh:15-16
# AND _llvm_build.sh:204,208.  Left unset, cmake emits an EMPTY archiver, so the
# archive rule runs `"" qc lib/foo.a ...` and /bin/sh reports exit 127
# "Permission denied" -- shared libs still link (they go through the compiler),
# only STATIC archives fail, which is why the resulting install error names a
# different missing file from run to run.
export ZIG_AR="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-ar"
export ZIG_RANLIB="${BUILD_PREFIX}/bin/${CONDA_ZIG_BUILD}-ranlib"

unset _wrap_src _wrap_tmp _wrap_target _wrap_arch _wrap_n
