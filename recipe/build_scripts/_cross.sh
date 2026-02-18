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

function remove_failing_langref() {
  local build_dir=$1
  local testslistfile=${2:-"${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt}

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}"/doc/langref ]]; then
    # These langref code snippets fails with lld.ld failing to find /usr/lib64/libmvec_nonshared.a
    # No idea why this comes up, there is no -lmvec_nonshared.a on the link command
    # there seems to be no way to redirect to sysroot/usr/lib64/libmvec_nonshared.a
    grep -v -f "${testslistfile}" "${build_dir}"/doc/langref.html.in > "${build_dir}"/doc/_langref.html.in
    mv "${build_dir}"/doc/_langref.html.in "${build_dir}"/doc/langref.html.in
    while IFS= read -r file
    do
      rm -f "${build_dir}"/doc/langref/"$file"
    done < "${SRC_DIR}"/build-level-patches/xxxx-remove-langref-std.txt
  else
    echo "No langref directory found"
    exit 1
  fi
}
