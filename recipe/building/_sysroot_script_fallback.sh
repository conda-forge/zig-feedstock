function prepare_sysroot_script_fallback() {
  # Failover workaround for bootstrap zig 0.17 LdScript regression on ppc64le.
  #
  # The bootstrap zig binary downloaded from ziglang.org/builds/ has a compiled-in
  # src/link/LdScript.zig parser that only recognises elf64-x86-64 and
  # elf64-littleaarch64.  When cross-compiling to ppc64le it reads the conda
  # sysroot's text-format linker scripts (libc.so, libpthread.so, …) which
  # contain "OUTPUT_FORMAT(elf64-powerpcle)" and raises error.UnknownCpuArch,
  # aborting the build before our patched final binary is produced.
  #
  # Without OUTPUT_FORMAT the parser skips the arch-dispatch entirely and
  # follows the GROUP directive straight to the real ELF .so.6 binary, where
  # zig handles ppc64le natively.  Stripping that single line from each text
  # script is therefore safe and sufficient.
  #
  # Trigger: "failed to parse shared library: UnknownCpuArch" in the zig build log.
  # Scope:   ppc64le cross-builds with a glibc sysroot using text linker scripts.
  # Removal: When upstream zig restores ppc64le to its LdScript arch table this
  #          failover can be deleted.
  #
  # Args:
  #   $1 - Source sysroot path (e.g. $CONDA_BUILD_SYSROOT)
  #
  # Exports:
  #   ZIG_SYSROOT_FALLBACK_DIR — path to the patched mirror; callers substitute
  #                              this for the original sysroot in -L / --libc-runtimes

  local src_sysroot="${1}"

  if [[ -z "${src_sysroot}" ]]; then
    echo "[sysroot_script_fallback] ERROR: source sysroot path required as \$1" >&2
    return 1
  fi

  if [[ ! -d "${src_sysroot}" ]]; then
    echo "[sysroot_script_fallback] ERROR: sysroot directory not found: ${src_sysroot}" >&2
    return 1
  fi

  local fallback_dir="${SRC_DIR}/sysroot-fallback"

  echo "[sysroot_script_fallback] Mirroring sysroot to ${fallback_dir} ..."
  rm -rf "${fallback_dir}"
  cp -a "${src_sysroot}/." "${fallback_dir}/"

  echo "[sysroot_script_fallback] Stripping OUTPUT_FORMAT(...) from text linker scripts ..."

  # Diagnostic: dump what's actually under usr/lib (and lib, lib64) in the fallback
  echo "[sysroot_script_fallback] === Fallback sysroot layout ==="
  local SYSROOT_DST="${fallback_dir}"
  for _dir in usr/lib usr/lib64 lib lib64; do
    local _full="${SYSROOT_DST}/${_dir}"
    if [[ -d "${_full}" ]]; then
      echo "[sysroot_script_fallback]   ${_dir}/ exists"
      ls -la "${_full}" 2>/dev/null | head -25 | sed 's/^/[sysroot_script_fallback]     | /'
    elif [[ -L "${_full}" ]]; then
      echo "[sysroot_script_fallback]   ${_dir}/ is a SYMLINK -> $(readlink "${_full}" 2>/dev/null)"
    else
      echo "[sysroot_script_fallback]   ${_dir}/ ABSENT"
    fi
  done
  echo "[sysroot_script_fallback] === End layout ==="

  # Single broad find pass: follow symlinks (-L), no maxdepth, both file and symlink types
  local _so_paths=()
  while IFS= read -r -d '' f; do _so_paths+=("$f"); done < <(
    find -L "${SYSROOT_DST}/usr/lib" "${SYSROOT_DST}/usr/lib64" "${SYSROOT_DST}/lib" "${SYSROOT_DST}/lib64" \
         \( -type f -o -type l \) -name '*.so' -print0 2>/dev/null
  )

  echo "[sysroot_script_fallback]   found ${#_so_paths[@]} candidate .so paths"

  local _f _ftype _target
  for _f in "${_so_paths[@]}"; do
    # file -L follows symlinks; -b omits leading filename so output is just the type string
    _ftype="$(file -L -b "${_f}" 2>/dev/null || true)"
    echo "[sysroot_script_fallback]   ${_f} -> ${_ftype}"

    # Broader text-script detection: ascii, text, script, utf-8, or empty files
    if echo "${_ftype}" | grep -qiE 'ascii|text|script|utf-8|empty'; then
      echo "[sysroot_script_fallback]   --- ${_f#"${fallback_dir}/"} (BEFORE) ---"
      head -5 "${_f}" 2>/dev/null | sed 's/^/[sysroot_script_fallback]     | /' || true

      # Resolve symlink so edits land on the real file (all symlinks pointing at it
      # will see the updated content automatically)
      _target="$(readlink -f "${_f}" 2>/dev/null || echo "${_f}")"
      if [[ -n "${_target}" && -f "${_target}" ]]; then
        # Strip OUTPUT_FORMAT(...) block — handles both single-line and multi-line forms
        awk '
          BEGIN { in_block = 0 }
          /OUTPUT_FORMAT[[:space:]]*\(/ {
            in_block = 1
            if (/\)/) { in_block = 0 }
            next
          }
          in_block {
            if (/\)/) { in_block = 0 }
            next
          }
          { print }
        ' "${_target}" > "${_target}.tmp" && mv "${_target}.tmp" "${_target}"
      fi

      echo "[sysroot_script_fallback]   --- ${_f#"${fallback_dir}/"} (AFTER) ---"
      head -5 "${_f}" 2>/dev/null | sed 's/^/[sysroot_script_fallback]     | /' || true
      echo "[sysroot_script_fallback]   patched: ${_f#"${fallback_dir}/"}"
    else
      echo "[sysroot_script_fallback]   (skipped: not text) ${_f}"
    fi
  done

  # Remap conda env vars so that -L/-I flags injected by conda-build activation
  # point at the fallback sysroot instead of the original.  These vars are set
  # before build.sh runs and are not part of EXTRA_ZIG_ARGS, so they must be
  # updated here explicitly.
  #
  # We use bash parameter expansion  ${VAR//$old/$new}  which replaces every
  # occurrence of $src_sysroot with $fallback_dir in the variable's value.
  # The ${VAR-} form avoids unbound-variable errors when a var is unset.
  echo "[sysroot_script_fallback] Remapping conda env vars from ${src_sysroot} → ${fallback_dir} ..."

  local _old="${src_sysroot}"
  local _new="${fallback_dir}"
  local _var _orig _updated

  for _var in \
    CONDA_BUILD_SYSROOT \
    LDFLAGS \
    CFLAGS \
    CXXFLAGS \
    CPPFLAGS \
    LDFLAGS_LD \
    LIBRARY_PATH \
    CPATH \
    PKG_CONFIG_PATH; do

    # Skip vars that are unset
    _orig="${!_var-__UNSET__}"
    [[ "${_orig}" == "__UNSET__" ]] && continue

    _updated="${_orig//$_old/$_new}"
    if [[ "${_updated}" != "${_orig}" ]]; then
      export "${_var}=${_updated}"
      echo "[sysroot_script_fallback]   remapped ${_var}"
    fi
  done

  export ZIG_SYSROOT_FALLBACK_DIR="${fallback_dir}"
  echo "[sysroot_script_fallback] Done. Fallback sysroot: ${ZIG_SYSROOT_FALLBACK_DIR}"
  return 0
}
