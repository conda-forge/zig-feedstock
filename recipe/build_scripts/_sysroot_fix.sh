#!/usr/bin/env bash
# Fix sysroot linker scripts to use relative paths instead of absolute /usr/lib64

function fix_sysroot_libc_scripts() {
  local sysroot_base="${1:-${BUILD_PREFIX}}"

  echo "Fixing sysroot linker scripts for relative paths..."

  # Find all sysroot directories
  for sysroot_dir in "${sysroot_base}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${sysroot_dir}" ]] || continue

    local arch_name=$(basename $(dirname "${sysroot_dir}"))
    echo "  Processing sysroot: ${arch_name}"

    # Fix libc.so, libpthread.so, libm.so, etc. in usr/lib and usr/lib64
    for lib_dir in "${sysroot_dir}"/usr/lib "${sysroot_dir}"/usr/lib64; do
      [[ -d "${lib_dir}" ]] || continue

      # Find all .so files that are actually linker scripts
      for script_file in "${lib_dir}"/{libc,libpthread,libm,librt,libdl}.so; do
        [[ -f "${script_file}" ]] || continue

        # Check if it's a linker script (contains "GROUP" or "INPUT")
        if grep -q -E "^(GROUP|INPUT)" "${script_file}" 2>/dev/null; then
          echo "    Patching ${script_file}"

          # Backup original
          cp "${script_file}" "${script_file}.orig"

          # Replace absolute paths with sysroot-relative paths
          # Original: GROUP ( /lib64/libc.so.6 /usr/lib64/libc_nonshared.a  AS_NEEDED ( /lib/ld-linux-aarch64.so.1 ) )
          # Fixed:    GROUP ( ../../lib64/libc.so.6 ../lib64/libc_nonshared.a  AS_NEEDED ( ../../lib/ld-linux-aarch64.so.1 ) )
          # Also handles: INPUT ( /usr/lib64/libpthread_nonshared.a -lpthread )

          sed -i \
            -e "s| /lib64/| ../../lib64/|g" \
            -e "s| /usr/lib64/| ../lib64/|g" \
            -e "s|( /lib64/|( ../../lib64/|g" \
            -e "s|( /usr/lib64/|( ../lib64/|g" \
            -e "s| /lib/ld-| ../../lib/ld-|g" \
            -e "s|( /lib/ld-|( ../../lib/ld-|g" \
            "${script_file}"

          echo "      Before: $(cat ${script_file}.orig)"
          echo "      After:  $(cat ${script_file})"
        fi
      done
    done
  done

  echo "Sysroot linker scripts fixed successfully"
}
