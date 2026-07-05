function create_zig_linux_libc_file() {
  local output_file=$1

  if [[ -z "${output_file}" ]]; then
    echo "ERROR: create_zig_libc_file requires: output_file" >&2
    return 1
  fi

  dbg echo "=== cross libc file ==="

  # CONDA_BUILD_SYSROOT is normally exported by the conda-forge compiler
  # ACTIVATION script. This recipe depends on gcc_impl/binutils_impl (the
  # _impl packages) directly rather than compiler('c'), so that activation
  # never runs and CONDA_BUILD_SYSROOT is unset -- even though the target
  # sysroot FILES are installed (via stdlib('c') -> sysroot_linux-<arch>) at
  # ${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot (the same path _cross_compile.sh
  # hardcodes for the ld.bfd wrapper). Derive it here so the libc-file paths
  # below aren't blank. Defaulted (:=) so it's a no-op when a real activation
  # already set it. CONDA_TRIPLET is the TARGET triplet (e.g.
  # powerpc64le-conda-linux-gnu), which is the sysroot we want.
  : "${CONDA_BUILD_SYSROOT:=${BUILD_PREFIX}/${CONDA_TRIPLET}/sysroot}"

  # Find GCC library directory (contains crtbegin.o, crtend.o)
  # Rewrite sysroot path: replace $BUILD_PREFIX with $BUILD_PREFIX/lib/gcc to reach the gcc multilib subdir.
  local gcc_lib_dir="${CONDA_BUILD_SYSROOT//${BUILD_PREFIX}/${BUILD_PREFIX}\/lib\/gcc}"
  echo "DIAG _cross.sh: create_zig_linux_libc_file gcc_lib_dir[after_rewrite]=[${gcc_lib_dir}]" >&2
  gcc_lib_dir=${gcc_lib_dir//\/sysroot/}
  echo "DIAG _cross.sh: create_zig_linux_libc_file gcc_lib_dir[after_strip_sysroot]=[${gcc_lib_dir}]" >&2
  gcc_lib_dir=$(find "${gcc_lib_dir}" -name "crtbeginS.o" 2>/dev/null | head -1 || true)
  echo "DIAG _cross.sh: create_zig_linux_libc_file gcc_lib_dir[after_find]=[${gcc_lib_dir}]" >&2
  [[ -n "${gcc_lib_dir}" ]] && gcc_lib_dir=$(dirname "${gcc_lib_dir}")
  echo "DIAG _cross.sh: create_zig_linux_libc_file gcc_lib_dir[after_dirname]=[${gcc_lib_dir}]" >&2

  if [[ -z "${gcc_lib_dir}" ]] || [[ ! -d "${gcc_lib_dir}" ]]; then
    echo "WARNING: Could not find GCC library directory for ${CONDA_BUILD_SYSROOT}" >&2
    gcc_lib_dir=""
    echo "DIAG _cross.sh: create_zig_linux_libc_file gcc_lib_dir[after_validate_cleared]=[${gcc_lib_dir}]" >&2
    echo "DIAG _cross.sh: gcc_dir empty/invalid — searching real crtbeginS.o locations under BUILD_PREFIX" >&2
    find "${BUILD_PREFIX}/lib/gcc" -name "crtbeginS.o" 2>/dev/null >&2 || echo "DIAG _cross.sh: none under ${BUILD_PREFIX}/lib/gcc" >&2
    find "${BUILD_PREFIX}" -name 'crtbegin*.o' 2>/dev/null | head -20 >&2 || true

    # No real GCC install was found (this recipe intentionally builds without
    # one -- see the comment above). GCC's own private, compiler-provided
    # freestanding headers (stddef.h and friends) are therefore ABSENT from
    # this sysroot: glibc itself never ships stddef.h, only the compiler
    # does. Zig's wrapper self-compile (zig_build.sh's native build-exe
    # branch, --libc + -I "${CONDA_BUILD_SYSROOT}/usr/include") chases
    # <stdio.h> -> <stddef.h> via #include_next past zig's own vendored
    # (correct, clang-builtin) stddef.h at "${PREFIX}/lib/zig/include"
    # (populated earlier in zig_build.sh, before this function ever runs in
    # the native/wrapper call path), landing on
    # "${CONDA_BUILD_SYSROOT}/usr/include" -- the last stop zig's --libc/-I
    # machinery appends -- where it 404s ("cannot open file
    # .../sysroot/usr/include/stddef.h"), aborting the whole wrapper compile.
    # Backfill the missing compiler-provided header from zig's own vendored
    # copy so the #include_next chain resolves. Guarded (only if the sysroot
    # copy is missing and zig's own copy is present) so this is a no-op
    # anywhere a real GCC's private headers already cover it, and a no-op on
    # the earlier is_cross call sites (~line 262-503 in zig_build.sh) where
    # ${PREFIX}/lib/zig/include may not be populated yet.
    if [[ ! -e "${CONDA_BUILD_SYSROOT}/usr/include/stddef.h" ]] && [[ -e "${PREFIX}/lib/zig/include/stddef.h" ]]; then
      ln -sf "${PREFIX}/lib/zig/include/stddef.h" "${CONDA_BUILD_SYSROOT}/usr/include/stddef.h"
      echo "DIAG _cross.sh: backfilled missing sysroot stddef.h from zig/include (no real gcc install found)" >&2
    fi
  fi

  # Create libc configuration file
  cat > "${output_file}" << EOF
include_dir=${CONDA_BUILD_SYSROOT}/usr/include
sys_include_dir=${CONDA_BUILD_SYSROOT}/usr/include
crt_dir=${CONDA_BUILD_SYSROOT}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_lib_dir}
EOF

  echo "DIAG _cross.sh: PROBE CONDA_BUILD_SYSROOT=[${CONDA_BUILD_SYSROOT}]" >&2
  if [[ -e "${CONDA_BUILD_SYSROOT}/usr/include/stdio.h" ]]; then
    echo "DIAG _cross.sh: PROBE sysroot stdio.h PRESENT at ${CONDA_BUILD_SYSROOT}/usr/include/stdio.h" >&2
  else
    echo "DIAG _cross.sh: PROBE sysroot stdio.h MISSING at ${CONDA_BUILD_SYSROOT}/usr/include/stdio.h" >&2
  fi
  echo "DIAG _cross.sh: PROBE listing ${CONDA_BUILD_SYSROOT}/usr/include (first 20):" >&2
  ls -1 "${CONDA_BUILD_SYSROOT}/usr/include" 2>/dev/null | head -20 >&2 || echo "DIAG _cross.sh: PROBE sysroot include dir ABSENT" >&2
  echo "DIAG _cross.sh: PROBE vendored generic-glibc stdio.h:" >&2
  ls -1 "${PREFIX}/lib/zig/libc/include/generic-glibc/stdio.h" 2>/dev/null >&2 || echo "DIAG _cross.sh: PROBE vendored generic-glibc stdio.h ABSENT" >&2

  # riscv64 lp64d: the vendored glibc ${sysroot}/usr/lib/libc.so is a GNU-ld
  # linker script. Round-2 diagnosis (learn_e3181ed4f358) assumed its GROUP()
  # entries were already RELATIVE (../../lib64/lp64d/libc.so.6) and only
  # patched that form. In practice, at the point this function runs (BEFORE
  # zig_build.sh's later, unconditional `fix_sysroot_libc_scripts` call in
  # _sysroot_fix.sh), the entries are still in their ORIGINAL, ABSOLUTE form
  # as shipped by the sysroot package (e.g. /lib64/lp64d/libc.so.6,
  # /usr/lib64/lp64d/libc_nonshared.a, /lib/ld-linux-riscv64-lp64d.so.1) --
  # the relative-with-".." form only appears LATER because
  # fix_sysroot_libc_scripts (zig_build.sh's "Always-linux: sysroot ld-script
  # rewrite" step, which is unconditional for is_linux and runs AFTER this
  # function in the cross-build call order) rewrites absolute "/lib64/..."
  # paths into sysroot-relative "../../lib64/..." paths for a different
  # purpose (native linux-64 libpthread.so). That relative form is what LLD
  # then fails to resolve: "unable to find ../../lib64/lp64d/libc.so.6"
  # (PR #109). The original relative-only sed here was therefore a no-op on
  # the (still-absolute) file at this point, and the "rewrote to bare
  # filenames" diag message was a false positive (no "../" present yet, so
  # the post-check trivially passed).
  #
  # Fix: match BOTH the absolute form (leading "/", optionally "/usr/") AND
  # the relative form (one or more leading "../", optionally followed by
  # "usr/") and strip the whole directory prefix down to a bare filename so
  # LLD resolves it via -L search (the -L lib64/lp64d + -L lib flags are
  # added in zig_build.sh's native _wrapper_cmd) regardless of which form is
  # present when this runs, and so that fix_sysroot_libc_scripts' later
  # absolute->relative rewrite becomes a no-op (its patterns only match
  # " /lib64/" style substrings, which no longer exist once the entry is
  # bare). Guarded to riscv64 (already-red lane) so it cannot affect any
  # other arch.
  if [[ "${CONDA_TRIPLET}" == riscv64-* ]]; then
    local _libc_ld="${CONDA_BUILD_SYSROOT}/usr/lib/libc.so"
    if [[ -f "${_libc_ld}" ]] && grep -q 'GROUP' "${_libc_ld}" 2>/dev/null; then
      # NOTE: the static-lib entry (libc_nonshared.a) may be prefixed with
      # either 'usr/lib64/lp64d/' or plain 'lib64/lp64d/' depending on
      # absolute-vs-relative form, unlike the shared-lib / dynamic-linker
      # entries. The optional (usr/)? below is required to actually match
      # and strip that entry in both forms -- without it this substitution
      # silently no-ops on libc_nonshared.a while still firing on the other
      # tokens. (\.\./)* is zero-or-more (not one-or-more) and /? is an
      # optional bare leading slash so the same pattern strips both the
      # absolute (/lib64/lp64d/..., /usr/lib64/lp64d/...) and relative
      # (../../lib64/lp64d/..., ../usr/lib64/lp64d/...) forms.
      sed -i -E '/GROUP/{ s#(\.\./)*/?(usr/)?lib64/lp64d/##g; s#(\.\./)*/?lib/##g; }' "${_libc_ld}"
      local _group_line
      _group_line=$(grep 'GROUP' "${_libc_ld}" || true)
      # A fully-bare GROUP() has no directory separators left in its entries:
      # neither a "../" relative prefix nor a leftover absolute "/lib..."
      # prefix. Use plain glob matching (not regex) to avoid escaping
      # ambiguity: flag either a space or "(" immediately followed by "/"
      # (leftover absolute path) or by "../" (leftover relative path).
      if [[ "${_group_line}" == *' /'* || "${_group_line}" == *'(/'* \
            || "${_group_line}" == *' ../'* || "${_group_line}" == *'(../'* ]]; then
        echo "DIAG _cross.sh: riscv64 libc.so GROUP() STILL contains a path prefix after rewrite: ${_group_line}" >&2
      else
        echo "DIAG _cross.sh: riscv64 rewrote libc.so GROUP() to bare filenames: ${_group_line}" >&2
      fi
    fi
  fi

  :
}
