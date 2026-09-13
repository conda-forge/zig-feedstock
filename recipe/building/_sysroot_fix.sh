#!/usr/bin/env bash
# Fix sysroot linker scripts to use relative paths instead of absolute /usr/lib64

function fix_sysroot_libc_scripts() {
  local sysroot_base="${1:-${BUILD_PREFIX}}"

  dbg echo "Fixing sysroot linker scripts for relative paths..."

  # Find all sysroot directories
  for sysroot_dir in "${sysroot_base}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${sysroot_dir}" ]] || continue

    local arch_name
    arch_name=$(basename "$(dirname "${sysroot_dir}")")
    dbg echo "  Processing sysroot: ${arch_name}"

    local _patched=0

    # Fix libc.so, libpthread.so, libm.so, etc. in usr/lib and usr/lib64
    local -a _lib_dirs=( "${sysroot_dir}"/usr/lib "${sysroot_dir}"/usr/lib64 )
    # zig gets --libc-runtimes <sysroot>/lib64 (build.sh:190-192); those scripts
    # need rewriting too. riscv64 only: its branch emits sysroot-ABSOLUTE paths,
    # which are position-independent. The other arches emit paths RELATIVE to the
    # script's depth, so widening the list would corrupt them.
    if [[ "${sysroot_dir}" == *riscv64-conda-linux-gnu* ]]; then
      _lib_dirs+=( "${sysroot_dir}"/lib64 "${sysroot_dir}"/lib64/lp64d "${sysroot_dir}"/lib )
    fi
    for lib_dir in "${_lib_dirs[@]}"; do
      [[ -d "${lib_dir}" ]] || continue

      # Find all .so files that are actually linker scripts
      for _script_base in libc libpthread libm librt libdl; do
        local script_file="${lib_dir}/${_script_base}.so"
        [[ -f "${script_file}" ]] || continue

        # Check if it's a linker script (contains "GROUP" or "INPUT")
        if grep -q -E "^(GROUP|INPUT)" "${script_file}" 2>/dev/null; then
          dbg echo "    Patching ${script_file}"

          # Backup original
          [[ -f "${script_file}.orig" ]] || cp "${script_file}" "${script_file}.orig"

          # riscv64: rewrite to sysroot-absolute paths (relative paths lose the
          # ld-linux AS_NEEDED stub once usr/lib is symlinked to lib64); all
          # other arches keep the sysroot-relative rewrite.
          if [[ "${sysroot_dir}" == *riscv64-conda-linux-gnu* ]]; then
            sed -i \
              -e "s| /lib64/| ${sysroot_dir}/lib64/|g" \
              -e "s| /usr/lib64/| ${sysroot_dir}/usr/lib64/|g" \
              -e "s|( /lib64/|( ${sysroot_dir}/lib64/|g" \
              -e "s|( /usr/lib64/|( ${sysroot_dir}/usr/lib64/|g" \
              -e "s| /lib/ld-| ${sysroot_dir}/lib/ld-|g" \
              -e "s|( /lib/ld-|( ${sysroot_dir}/lib/ld-|g" \
              "${script_file}"
          else
            # Replace absolute paths with sysroot-relative paths
            sed -i \
              -e "s| /lib64/| ../../lib64/|g" \
              -e "s| /usr/lib64/| ../lib64/|g" \
              -e "s|( /lib64/|( ../../lib64/|g" \
              -e "s|( /usr/lib64/|( ../lib64/|g" \
              -e "s| /lib/ld-| ../../lib/ld-|g" \
              -e "s|( /lib/ld-|( ../../lib/ld-|g" \
              "${script_file}"
          fi

          dbg echo "      patched $(basename "${script_file}") ($(wc -c < "${script_file}") bytes)"
          _patched=$(( _patched + 1 ))
          rm -f "${script_file}.orig"
        fi
      done
    done

    if [[ "${_patched}" -eq 0 ]]; then
      echo "WARNING: [sysroot_fix] ${arch_name}: patched 0 linker scripts (searched: ${_lib_dirs[*]:-none})" >&2
    else
      echo "INFO: [sysroot_fix] ${arch_name}: patched ${_patched} linker script(s)" >&2
    fi
  done

  dbg echo "Sysroot linker scripts fixed successfully"
  return 0
}
