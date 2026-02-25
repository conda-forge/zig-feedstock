function create_zig_linux_libc_file() {
  local output_file=$1

  if [[ -z "${output_file}" ]]; then
    echo "ERROR: create_zig_libc_file requires: output_file" >&2
    return 1
  fi

  echo "Creating Zig libc configuration file: ${output_file}"

  # Find GCC library directory (contains crtbegin.o, crtend.o)
  local gcc_lib_dir="${CONDA_BUILD_SYSROOT//${BUILD_PREFIX}/${BUILD_PREFIX}\/lib\/gcc}"
  gcc_lib_dir=${gcc_lib_dir//\/sysroot/}
  gcc_lib_dir=$(dirname "$(find "${gcc_lib_dir}" -name "crtbeginS.o" | head -1)")

  if [[ -z "${gcc_lib_dir}" ]] || [[ ! -d "${gcc_lib_dir}" ]]; then
    echo "WARNING: Could not find GCC library directory for ${CONDA_BUILD_SYSROOT}" >&2
    gcc_lib_dir=""
  else
    echo "  Found GCC library directory: ${gcc_lib_dir}"
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

  echo "✓ Zig libc file created: ${output_file}"
  return 0
}
