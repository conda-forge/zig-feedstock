# ZIG BUILD FUNCTIONS
#
# Main zig build helper functions for the zig compiler package.
# These functions handle the core build process for zig using zig itself,
# and manage build-specific issues like failing language reference tests.

# Build zig using zig
# This is the primary method for compiling zig from source.
# Usage: build_zig_with_zig <build_dir> <zig_binary> <install_dir>
#
# Args:
#   $1 - Build directory containing zig source
#   $2 - Path to zig binary to use for building
#   $3 - Installation directory for output
#
# Returns: 0 on success, 1 on failure
#
function build_zig_with_zig() {
  local build_dir=$1
  local zig=$2
  local install_dir=$3

  local current_dir
  current_dir=$(pwd)

  if [[ -d "${build_dir}" ]]; then
    cd "${build_dir}" || return 1
      "${zig}" build \
        --prefix "${install_dir}" \
        ${EXTRA_ZIG_ARGS[@]+"${EXTRA_ZIG_ARGS[@]}"} \
        -Dversion-string="${PKG_VERSION}" || return 1
        # --search-prefix "${install_dir}" \
    cd "${current_dir}" || return 1
  else
    echo "No build directory found" >&2
    return 1
  fi
}

# Remove failing language reference tests for cross-compilation
# Some language reference code snippets fail during cross-compilation,
# particularly with lld failing to find architecture-specific libraries.
# This function removes those problematic snippets from the build.
#
# Usage: remove_failing_langref <build_dir> [tests_list_file]
#
# Args:
#   $1 - Build directory containing the langref files
#   $2 - File listing patterns to exclude (default: build-level-patches/xxxx-remove-langref-std.txt)
#
# Returns: 0 on success, 1 on failure
#
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
