#!/usr/bin/env bash
# Fix sysroot linker scripts to use relative paths instead of absolute /usr/lib64

function fix_sysroot_libc_scripts() {
  local sysroot_base="${1:-${BUILD_PREFIX}}"

  is_debug && echo "Fixing sysroot linker scripts for relative paths..."

  # Find all sysroot directories
  for sysroot_dir in "${sysroot_base}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${sysroot_dir}" ]] || continue

    local arch_name=$(basename $(dirname "${sysroot_dir}"))
    is_debug && echo "  Processing sysroot: ${arch_name}"

    # Fix libc.so, libpthread.so, libm.so, etc. in usr/lib and usr/lib64
    for lib_dir in "${sysroot_dir}"/usr/lib "${sysroot_dir}"/usr/lib64; do
      [[ -d "${lib_dir}" ]] || continue

      # Find all .so files that are actually linker scripts
      for script_file in "${lib_dir}"/{libc,libpthread,libm,librt,libdl}.so; do
        [[ -f "${script_file}" ]] || continue

        # Check if it's a linker script (contains "GROUP" or "INPUT")
        if grep -q -E "^(GROUP|INPUT)" "${script_file}" 2>/dev/null; then
          is_debug && echo "    Patching ${script_file}"

          # Backup original
          cp "${script_file}" "${script_file}.orig"

          # Replace absolute paths with sysroot-relative paths
          sed -i \
            -e "s| /lib64/| ../../lib64/|g" \
            -e "s| /usr/lib64/| ../lib64/|g" \
            -e "s|( /lib64/|( ../../lib64/|g" \
            -e "s|( /usr/lib64/|( ../lib64/|g" \
            -e "s| /lib/ld-| ../../lib/ld-|g" \
            -e "s|( /lib/ld-|( ../../lib/ld-|g" \
            "${script_file}"

          if is_debug; then
            echo "      Before: $(cat "${script_file}.orig")"
            echo "      After:  $(cat "${script_file}")"
          fi
        fi
      done
    done
  done

  is_debug && echo "Sysroot linker scripts fixed successfully"
}
