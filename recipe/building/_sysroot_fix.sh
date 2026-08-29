#!/usr/bin/env bash
# Rewrite sysroot linker-script GROUP paths so ld.lld can resolve them

function fix_sysroot_libc_scripts() {
  local sysroot_base="${1:-${BUILD_PREFIX}}"

  # auto: absolute GROUP paths for the riscv64 sysroot, relative elsewhere.
  # legacy / abs force one form for every sysroot.
  local _mode="${ZIG_SYSROOT_MODE:-auto}"
  if [[ "${_mode}" != "auto" ]]; then
    echo "fix_sysroot_libc_scripts: ZIG_SYSROOT_MODE=${_mode} overrides the per-sysroot default"
  fi

  dbg echo "Fixing sysroot linker scripts (mode=${_mode})..."

  # Find all sysroot directories. NOTE: this glob matches EVERY triplet's
  # sysroot under sysroot_base (usually BUILD_PREFIX), not just the target's.
  dbg echo "  Sysroot dirs to process (ALL triplets under ${sysroot_base}): ${sysroot_base}/*-conda-linux-gnu/sysroot"
  for sysroot_dir in "${sysroot_base}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${sysroot_dir}" ]] || continue

    local arch_name
    arch_name=$(basename "$(dirname "${sysroot_dir}")")
    dbg echo "  Processing sysroot: ${arch_name} (${sysroot_dir})"

    # Fix libc.so, libpthread.so, libm.so, etc. in usr/lib and usr/lib64
    for lib_dir in "${sysroot_dir}"/usr/lib "${sysroot_dir}"/usr/lib64; do
      [[ -d "${lib_dir}" ]] || continue

      # Find all .so files that are actually linker scripts
      for script_file in "${lib_dir}"/{libc,libpthread,libm,librt,libdl}.so; do
        [[ -f "${script_file}" ]] || continue

        # Check if it's a linker script (contains "GROUP" or "INPUT")
        if grep -q -E "^(GROUP|INPUT)" "${script_file}" 2>/dev/null; then
          dbg echo "    Patching ${script_file}"

          # usr/lib and usr/lib64 can resolve to the same file; do not overwrite a kept .orig
          [[ -f "${script_file}.orig" ]] || cp "${script_file}" "${script_file}.orig"

          local _use_abs=0
          case "${_mode}" in
            abs)    _use_abs=1 ;;
            legacy) _use_abs=0 ;;
            *)      [[ "${sysroot_dir}" == *riscv64-conda-linux-gnu* ]] && _use_abs=1 ;;
          esac
          if [[ "${_use_abs}" == "1" ]]; then
            sed -i \
              -e "s| /lib64/| ${sysroot_dir}/lib64/|g" \
              -e "s| /usr/lib64/| ${sysroot_dir}/usr/lib64/|g" \
              -e "s|( /lib64/|( ${sysroot_dir}/lib64/|g" \
              -e "s|( /usr/lib64/|( ${sysroot_dir}/usr/lib64/|g" \
              -e "s| /lib/ld-| ${sysroot_dir}/lib/ld-|g" \
              -e "s|( /lib/ld-|( ${sysroot_dir}/lib/ld-|g" \
              "${script_file}"
          else
            sed -i \
              -e "s| /lib64/| ../../lib64/|g" \
              -e "s| /usr/lib64/| ../lib64/|g" \
              -e "s|( /lib64/|( ../../lib64/|g" \
              -e "s|( /usr/lib64/|( ../lib64/|g" \
              -e "s| /lib/ld-| ../../lib/ld-|g" \
              -e "s|( /lib/ld-|( ../../lib/ld-|g" \
              "${script_file}"
          fi

          dbg echo "  patched $(basename "${script_file}") ($(wc -c < "${script_file}" | tr -d ' ') bytes)"
          if [[ "${DEBUG_ZIG_BUILD:-0}" == "1" ]]; then
            dbg echo "    keeping ${script_file}.orig (DEBUG_ZIG_BUILD=1)"
          else
            rm -f "${script_file}.orig"
          fi
        fi
      done
    done
  done

  dbg echo "Sysroot linker scripts fixed successfully"
  return 0
}
