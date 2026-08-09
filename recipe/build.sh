#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

source "${RECIPE_DIR}/building/_bash_check.sh"

export build_platform="${build_platform:-${target_platform}}"

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  EXE=""
else
  EXE=".exe"
fi

# Native Windows tools (cmake.exe, ninja.exe) spawn the compiler via a raw
# Win32 CreateProcess and cannot interpret a "#!/usr/bin/env bash" shebang
# (unlike MSYS2 bash itself, which special-cases shebang execution). Writing
# the wrapper logic to a bare bash script and pointing CMAKE_*_COMPILER at a
# thin .bat launcher works because CreateProcess auto-invokes cmd.exe for
# .bat/.cmd targets, which then calls bash on the real script. Unix keeps
# executing the bash script directly (EXE="" there, no launcher needed).
# Without this split, the FIRST real (non-skipped) compiler invocation from
# ninja fails with "ninja: fatal: CreateProcess: This version of %1 is not
# compatible with the version of Windows you're running." (PR #123, win-64
# cross_target_platform_win-64 CI, 2026-07-24: libunwind.cpp compile inside
# the LLVM runtimes build was the first non-"skipped" CXX invocation).
if [[ -n "${EXE}" ]]; then
  WRAPPER_SCRIPT_EXT=".sh"
  WRAPPER_LAUNCH_EXT=".bat"
else
  WRAPPER_SCRIPT_EXT=""
  WRAPPER_LAUNCH_EXT=""
fi

# rattler-build does not pre-create BUILD_PREFIX/bin on the win-64 lane
# (Windows tooling lives in Library/bin); the wrapper writes below need it.
mkdir -p "${BUILD_PREFIX}/bin"

# On Windows the zig_impl build dep installs the real zig binaries under
# Library/bin (conda Windows convention), but the cc/cxx wrappers written below
# exec a same-directory sibling ${BUILD_PREFIX}/bin/<build-triplet>-zig${EXE}. On
# native win-64 nothing stages that binary into bin/, so the wrapper dies with
# "x86_64-w64-mingw32-zig.exe: No such file or directory" (exit 127). Copy the
# real binary in. cp (not ln -s): native Windows zig does not follow MSYS2 Unix
# symlinks (see _runtimes_build.sh:443). Only-if-absent so any lane that already
# staged it is left untouched.
if [[ -n "${EXE}" ]]; then
  _real_zig_src="${BUILD_PREFIX}/Library/bin/${CONDA_TOOLCHAIN_BUILD}-zig${EXE}"
  _real_zig_dst="${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-zig${EXE}"
  if [[ ! -f "${_real_zig_dst}" && -f "${_real_zig_src}" ]]; then
    cp "${_real_zig_src}" "${_real_zig_dst}"
    echo "  staged build-arch zig into BUILD_PREFIX/bin: ${_real_zig_dst}"
  fi
fi

# The staged build-arch zig above is a bare copy in BUILD_PREFIX/bin with no
# adjacent lib/zig, so zig's default self-location (../lib/zig relative to the
# exe) fails with "unable to find zig installation directory ...: FileNotFound".
# Point it at the real stdlib shipped by the zig_impl build dep at
# Library/lib/zig (sibling of the real Library/bin/<triple>-zig.exe). Windows-only
# (EXE non-empty): on Unix the wrapper execs the in-place zig which finds its own
# ../lib/zig. Exported here so every cc/cxx wrapper invocation and CMake/ninja
# child spawned by this build.sh inherits it. Fail loudly if the stdlib is not
# where expected rather than surfacing later as a cryptic self-location error.
if [[ -n "${EXE}" ]]; then
  export ZIG_LIB_DIR="${BUILD_PREFIX}/Library/lib/zig"
  if [[ ! -d "${ZIG_LIB_DIR}" ]]; then
    echo "FATAL: expected zig stdlib at ${ZIG_LIB_DIR} (needed because the" \
         "build-arch zig.exe is copied into bin/ without an adjacent lib/zig)" >&2
    exit 1
  fi
  echo "  exported ZIG_LIB_DIR=${ZIG_LIB_DIR} for the staged build-arch zig"
fi

# Adding shell helpers
for tool in cc cxx ar ranlib; do
  # ar/ranlib are llvm-ar/llvm-ranlib and reject -target (they parse "-target"
  # as operation chars -> "unknown option g"); only cc/cxx take a target.
  case "${tool}" in
    cc|cxx) _zig_tgt="-target ${ZIG_TARGET_HOST}" ;;
    *)      _zig_tgt="" ;;
  esac
  cat > "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-zig-${tool}${WRAPPER_SCRIPT_EXT}" << WRAPPER_EOF
#!/usr/bin/env bash
_self_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# Strip Clang-emitted linker flags that zig's self-hosted linker path
# panics on (index out of bounds, len 0): --dependency-file (a ninja
# incremental-relink depfile, meaningless for a one-shot conda build) and
# --color-diagnostics (cosmetic). Mirrors the pre-filter in
# scripts/_zig-cc-common.sh so this build-time toolchain matches the
# shipped consumer wrapper; extended to the -Wl, comma form the LLVM
# runtimes CMake emits.
_zig_args=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -Wl,--color-diagnostics|--color-diagnostics|-Wl,--dependency-file=*|--dependency-file=*)
      shift; continue ;;
    -fno-partial-inlining|-fno-ipa-cp-clone)
      # GCC-only IPA flags (ppc64le R_PPC64_REL24 mitigation CFLAGS from
      # build-zig.sh); zig's Clang frontend rejects them outright with
      # "Unknown Clang option: '-fno-partial-inlining'".
      shift; continue ;;
    -Xlinker)
      case "\${2:-}" in
        --color-diagnostics|--dependency-file=*) shift 2; continue ;;
      esac
      _zig_args+=("\$1"); shift; continue ;;
  esac
  _zig_args+=("\$1"); shift
done
_zig_out_obj=""
_zig_has_c=0
_zig_prev=""
for _a in "\${_zig_args[@]}"; do
  [[ "\${_a}" == "-c" ]] && _zig_has_c=1
  [[ "\${_zig_prev}" == "-o" ]] && _zig_out_obj="\${_a}"
  _zig_prev="\${_a}"
done
"\${_self_dir}/${CONDA_TOOLCHAIN_BUILD}-zig${EXE}" ${tool/xx/++} ${_zig_tgt} "\${_zig_args[@]}"
_zig_rc=\$?
if [[ \${_zig_rc} -eq 0 && "\${ZIG_STRIP_DEPLIBS:-0}" == "1" && \${_zig_has_c} -eq 1 && "\${_zig_out_obj}" == *.o ]]; then
  # Strip SHT_LLVM_DEPENDENT_LIBRARIES (.deplibs) records that zig's clang
  # frontend auto-embeds but lld cannot resolve for the conda glibc sysroot
  # (see _runtimes_build.sh). The explicit -lpthread/-lrt on the link already
  # cover the same deps; -Wl,--no-dependent-libraries does NOT reach lld
  # (zig's -Wl, translator drops it) and -fno-autolink does not suppress the
  # section either -- objcopy is the only proven lever. llvm-objcopy is not
  # yet built at this point (this wrapper runs before _llvm_build.sh); fall
  # back to GNU objcopy from the base image. Never fail the compile.
  _objcopy_bin="\$(command -v llvm-objcopy 2>/dev/null || command -v objcopy 2>/dev/null || true)"
  if [[ -n "\${_objcopy_bin}" ]]; then
    "\${_objcopy_bin}" --remove-section=.deplibs "\${_zig_out_obj}" 2>/dev/null || true
  else
    echo "  WARNING: ZIG_STRIP_DEPLIBS=1 but no objcopy found; leaving .deplibs in \${_zig_out_obj}" >&2
  fi
fi
exit \${_zig_rc}
WRAPPER_EOF
  chmod +x "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-zig-${tool}${WRAPPER_SCRIPT_EXT}"
  # Windows only: thin .bat launcher so native CreateProcess callers (cmake,
  # ninja) can invoke the bash wrapper above (see WRAPPER_LAUNCH_EXT note near
  # the top of this file). CMAKE_*_COMPILER is pointed at this .bat below.
  if [[ -n "${WRAPPER_LAUNCH_EXT}" ]]; then
    cat > "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-zig-${tool}${WRAPPER_LAUNCH_EXT}" << BAT_EOF
@echo off
bash "%~dp0${CONDA_TOOLCHAIN_HOST}-zig-${tool}${WRAPPER_SCRIPT_EXT}" %*
exit /b %ERRORLEVEL%
BAT_EOF
    chmod +x "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-zig-${tool}${WRAPPER_LAUNCH_EXT}"
  fi
done

# Build-arch (native) cc/cxx wrappers for host-tool runtimes (e.g. the native
# libc++ that llvm-tblgen links against). Only needed when cross-compiling: the
# host wrappers above target the HOST arch, but host tools run on the BUILD arch.
# The raw build-arch zig is ${CONDA_TOOLCHAIN_BUILD}-zig (from the
# zig_impl_${build_platform} dep); invoked WITHOUT -target it emits build-arch
# objects. _runtimes_build.sh references these as ${CONDA_ZIG_BUILD}-cc/-cxx.
# When BUILD==HOST (native / self-cross) the host wrapper already carries this
# name, so skip.
if [[ "${CONDA_TOOLCHAIN_BUILD}" != "${CONDA_TOOLCHAIN_HOST}" ]]; then
  for tool in cc cxx; do
    cat > "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-zig-${tool}${WRAPPER_SCRIPT_EXT}" << WRAPPER_EOF
#!/usr/bin/env bash
_self_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# Same Clang linker-flag pre-filter as the host wrapper above (zig's linker
# path panics on --dependency-file / --color-diagnostics).
_zig_args=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -Wl,--color-diagnostics|--color-diagnostics|-Wl,--dependency-file=*|--dependency-file=*)
      shift; continue ;;
    -fno-partial-inlining|-fno-ipa-cp-clone)
      # GCC-only IPA flags (ppc64le R_PPC64_REL24 mitigation CFLAGS from
      # build-zig.sh); zig's Clang frontend rejects them outright with
      # "Unknown Clang option: '-fno-partial-inlining'".
      shift; continue ;;
    -Xlinker)
      case "\${2:-}" in
        --color-diagnostics|--dependency-file=*) shift 2; continue ;;
      esac
      _zig_args+=("\$1"); shift; continue ;;
  esac
  _zig_args+=("\$1"); shift
done
_zig_out_obj=""
_zig_has_c=0
_zig_prev=""
for _a in "\${_zig_args[@]}"; do
  [[ "\${_a}" == "-c" ]] && _zig_has_c=1
  [[ "\${_zig_prev}" == "-o" ]] && _zig_out_obj="\${_a}"
  _zig_prev="\${_a}"
done
"\${_self_dir}/${CONDA_TOOLCHAIN_BUILD}-zig${EXE}" ${tool/xx/++} "\${_zig_args[@]}"
_zig_rc=\$?
if [[ \${_zig_rc} -eq 0 && "\${ZIG_STRIP_DEPLIBS:-0}" == "1" && \${_zig_has_c} -eq 1 && "\${_zig_out_obj}" == *.o ]]; then
  # See the host wrapper above: strip the .deplibs section zig's clang
  # frontend embeds but lld cannot resolve; explicit -l flags already cover
  # the real deps. Never fail the compile if objcopy is unavailable.
  _objcopy_bin="\$(command -v llvm-objcopy 2>/dev/null || command -v objcopy 2>/dev/null || true)"
  if [[ -n "\${_objcopy_bin}" ]]; then
    "\${_objcopy_bin}" --remove-section=.deplibs "\${_zig_out_obj}" 2>/dev/null || true
  else
    echo "  WARNING: ZIG_STRIP_DEPLIBS=1 but no objcopy found; leaving .deplibs in \${_zig_out_obj}" >&2
  fi
fi
exit \${_zig_rc}
WRAPPER_EOF
    chmod +x "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-zig-${tool}${WRAPPER_SCRIPT_EXT}"
    # Windows only: matching .bat launcher (see note above the host-wrapper loop).
    if [[ -n "${WRAPPER_LAUNCH_EXT}" ]]; then
      cat > "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-zig-${tool}${WRAPPER_LAUNCH_EXT}" << BAT_EOF
@echo off
bash "%~dp0${CONDA_TOOLCHAIN_BUILD}-zig-${tool}${WRAPPER_SCRIPT_EXT}" %*
exit /b %ERRORLEVEL%
BAT_EOF
      chmod +x "${BUILD_PREFIX}/bin/${CONDA_TOOLCHAIN_BUILD}-zig-${tool}${WRAPPER_LAUNCH_EXT}"
    fi
  done
fi

export ZIG_CC="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-cc"${WRAPPER_LAUNCH_EXT}"
export ZIG_CXX="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-cxx"${WRAPPER_LAUNCH_EXT}"
export ZIG_AR="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-ar"${WRAPPER_LAUNCH_EXT}"
export ZIG_RANLIB="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-ranlib"${WRAPPER_LAUNCH_EXT}"
export ZIG_RC="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-rc"${WRAPPER_LAUNCH_EXT}"
# Forward-slash sibling of ZIG_RC for embedding in CMake -C initial-cache
# scripts: BUILD_PREFIX is a native backslash path on Windows, and CMake's
# script parser treats backslashes as string escapes (see
# zig-llvm/building/_llvm_build.sh's RC-compiler CMINIT block). Mirrors
# activate.bat's ZIG_RC_CMAKE (%_wrapper_dir:\=/%) substitution.
export ZIG_RC_CMAKE="${ZIG_RC//\\//}"
export ZIG_ASM="${BUILD_PREFIX}"/bin/"${CONDA_TOOLCHAIN_HOST}"-zig-cc"${WRAPPER_LAUNCH_EXT}"

# PR #123 win-64: the generated wrapper chain on Windows is
#   ninja -> <triplet>-zig-<tool>.bat -> bash -> <triplet>-zig-<tool>.sh -> zig.exe
# and the bash hop raises "Argument list too long" on the libclang-cpp.dll link
# (~1500 archives) BEFORE zig.exe ever starts. The overflow is upstream of
# anything CMake controls, which is why -DCMAKE_NINJA_FORCE_RESPONSE_FILE=ON had
# no effect and why the env block (189 vars / 20944 B, far under the 32767 cap)
# was a red herring.
#
# The zig package already ships compiled C shims built for exactly this role
# (recipe/building/zig-cc-nonunix.c -> Library/bin/<triplet>-zig-{cc,cxx}.exe via
# install_zig_activation.py). zig-llvm/building/_cross_compile.sh already invokes
# that same path for the native host compiler, so it is proven in this build.
# Pointing the compile/link drivers there lets ninja spawn a native binary
# directly, with no bash in the middle and a full 32767-char command line.
#
# Nothing is lost by skipping the bash wrapper here: its only extra behaviour is
# the ZIG_STRIP_DEPLIBS objcopy step, and .deplibs is SHT_LLVM_DEPENDENT_LIBRARIES
# -- an ELF-only section, described above as a conda glibc-sysroot workaround. It
# is a no-op on COFF/PE objects. The C shim otherwise carries a superset of the
# bash wrapper's filtering (R1-R9 via _translate.inc, plus -Wl,-e entry rewrite,
# MSVC /MANIFEST* drops and LLD auto-promotion).
#
# Self-verifying: the shim resolves zig via CONDA_PREFIX, which is not guaranteed
# to point at BUILD_PREFIX during the build, so probe it and fall back to the
# .bat chain rather than hard-failing.
if [[ -n "${WRAPPER_LAUNCH_EXT}" ]]; then
  _nu_cc="${BUILD_PREFIX}/Library/bin/${CONDA_TOOLCHAIN_HOST}-zig-cc.exe"
  _nu_cxx="${BUILD_PREFIX}/Library/bin/${CONDA_TOOLCHAIN_HOST}-zig-cxx.exe"
  if [[ -f "${_nu_cc}" && -f "${_nu_cxx}" ]] && "${_nu_cc}" --version 2>&1 | grep -q "clang version"; then
    export ZIG_CC="${_nu_cc}"
    export ZIG_CXX="${_nu_cxx}"
    export ZIG_ASM="${_nu_cc}"
    echo "  win: ZIG_CC/ZIG_CXX/ZIG_ASM -> compiled nonunix shims (no bash hop, avoids argv overflow)"
  else
    echo "  WARNING: compiled nonunix shims unusable; keeping the .bat -> bash wrapper chain" >&2
    echo "    tried: ${_nu_cc}" >&2
    echo "    the libclang-cpp.dll link may fail with 'Argument list too long'" >&2
  fi
  unset _nu_cc _nu_cxx
fi

# Sanity-check the wrapper exists with a clear, actionable error before
# relying on it below (ported from package-incubator/recipes/zig-llvm's
# _zig_wrappers.sh probe; lives here rather than in this feedstock's own
# _zig_wrappers.sh because these exports are relocated to this monolithic
# build.sh dispatcher instead).
# Extension-aware: on Windows/MSYS the launcher is a .bat file, and chmod
# does not confer real POSIX executable-bit semantics there (test -x is
# governed by NTFS ACL/mount options, not chmod) -- so fall back to plain
# existence (-f) when WRAPPER_LAUNCH_EXT is set. On Unix (no extension) the
# chmod'd executable bit is real and meaningful, so keep -x.
if [[ -n "${WRAPPER_LAUNCH_EXT}" ]]; then
  _zig_cc_ok=0; [[ -f "${ZIG_CC}" ]] && _zig_cc_ok=1
else
  _zig_cc_ok=0; [[ -x "${ZIG_CC}" ]] && _zig_cc_ok=1
fi
if [[ "${_zig_cc_ok}" != "1" ]]; then
  echo "ERROR: zig cc wrapper not found at ${ZIG_CC}"
  echo "  Is the host zig toolchain for ${CONDA_TOOLCHAIN_HOST} a build dependency?"
  exit 1
fi
# Sanity check that the wrapper produces a clang version banner. Non-fatal:
# if the probe doesn't find the banner, log a warning and continue — the
# actual compile will surface any real wrapper defect.
_zig_cc_version_out=$("${ZIG_CC}" --version 2>&1)
echo "${_zig_cc_version_out}"
if ! echo "${_zig_cc_version_out}" | grep -q "clang version"; then
  echo "WARN: zig-cc probe (${ZIG_CC} --version) did not output 'clang version' banner" >&2
  echo "WARN: continuing anyway — actual compilation will catch any real wrapper defect" >&2
fi

# === Master dispatch: build.sh is called for both the LLVM/zig staging output
if [[ "${target_platform}" == "linux-riscv64" || "${target_platform}" == "linux-s390x" ]]; then
  ( cd "${SRC_DIR}/libxml2-source" && "${RECIPE_DIR}"/zig-libxml2/build.sh )
  ( cd "${SRC_DIR}/zlib-source"    && "${RECIPE_DIR}"/zig-zlib/build.sh    )
  ( cd "${SRC_DIR}/zstd-source"    && "${RECIPE_DIR}"/zig-zstd/build.sh    )
fi

export CC="${ZIG_CC}"
export CXX="${ZIG_CXX}"
export AR="${ZIG_AR}"
export RANLIB="${ZIG_RANLIB}"
export LLVM_RECIPE_DIR="${RECIPE_DIR}/zig-llvm"

"${LLVM_RECIPE_DIR}"/build.sh

"${RECIPE_DIR}"/building/build-zig.sh
