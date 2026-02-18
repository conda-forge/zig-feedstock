#!/usr/bin/env bash
################################################################################
# Cross-Compilation Helper Functions
################################################################################
#
# This file contains helper functions for cross-compilation scenarios where
# code is compiled on one platform (build machine) to run on another platform
# (target machine).
#
# Key helpers:
# - QEMU emulator setup for running target-platform binaries on build machine
# - llvm-config wrapper to run under QEMU with proper sysroot
# - Zig libc configuration file generation for cross-compilation targets
#
# These functions enable:
# 1. Building Zig compiler from source on different architectures
# 2. Running target-specific build tools via QEMU emulation
# 3. Proper libc header and library discovery for cross-targets
#
################################################################################

################################################################################
# setup_crosscompiling_emulator
#
# Setup QEMU emulator for cross-compilation.
# Sets the CROSSCOMPILING_EMULATOR environment variable to enable running
# target-platform binaries during the build process.
#
# Usage:
#   setup_crosscompiling_emulator "qemu-arm64"
#
# Parameters:
#   $1 - qemu_prg: Name of QEMU binary (e.g., "qemu-aarch64-static")
#
# Exit codes:
#   0 - Success
#   1 - Missing parameter or QEMU not found
################################################################################
function setup_crosscompiling_emulator() {
  local qemu_prg=$1

  if [[ -z "${qemu_prg}" ]]; then
    echo "ERROR: qemu_prg parameter required for setup_crosscompiling_emulator" >&2
    return 1
  fi

  # Set CROSSCOMPILING_EMULATOR if not already set
  if [[ -z "${CROSSCOMPILING_EMULATOR:-}" ]]; then
    if [[ -f /usr/bin/"${qemu_prg}" ]]; then
      export CROSSCOMPILING_EMULATOR=/usr/bin/"${qemu_prg}"
      echo "Set CROSSCOMPILING_EMULATOR=${CROSSCOMPILING_EMULATOR}"
    else
      echo "ERROR: CROSSCOMPILING_EMULATOR not set and ${qemu_prg} not found in /usr/bin/" >&2
      return 1
    fi
  else
    echo "Using existing CROSSCOMPILING_EMULATOR=${CROSSCOMPILING_EMULATOR}"
  fi

  return 0
}

################################################################################
# create_qemu_llvm_config_wrapper
#
# Create a wrapper script for llvm-config that runs under QEMU emulation.
# This allows the build machine to run llvm-config binaries compiled for the
# target architecture, with proper sysroot configuration.
#
# The original llvm-config is backed up and replaced with a wrapper that:
# 1. Sets QEMU_LD_PREFIX to the sysroot path
# 2. Executes the real llvm-config under QEMU emulation
#
# Usage:
#   create_qemu_llvm_config_wrapper "/path/to/sysroot"
#
# Parameters:
#   $1 - sysroot_path: Path to the target architecture sysroot
#
# Exit codes:
#   0 - Success
#   1 - Missing parameter, CROSSCOMPILING_EMULATOR not set, or operation failed
#
# Dependencies:
#   - CROSSCOMPILING_EMULATOR must be set (via setup_crosscompiling_emulator)
#   - PREFIX environment variable must be set to conda environment prefix
################################################################################
function create_qemu_llvm_config_wrapper() {
  local sysroot_path=$1

  if [[ -z "${sysroot_path}" ]]; then
    echo "ERROR: sysroot_path parameter required for create_qemu_llvm_config_wrapper" >&2
    return 1
  fi

  if [[ -z "${CROSSCOMPILING_EMULATOR:-}" ]]; then
    echo "ERROR: CROSSCOMPILING_EMULATOR must be set before calling create_qemu_llvm_config_wrapper" >&2
    return 1
  fi

  echo "Creating QEMU wrapper for llvm-config"

  # Backup original llvm-config
  mv "${PREFIX}"/bin/llvm-config "${PREFIX}"/bin/llvm-config.zig_conda_real || return 1

  # Create wrapper script that runs llvm-config under QEMU
  cat > "${PREFIX}"/bin/llvm-config << EOF
#!/usr/bin/env bash
export QEMU_LD_PREFIX="${sysroot_path}"
"${CROSSCOMPILING_EMULATOR}" "${PREFIX}"/bin/llvm-config.zig_conda_real "\$@"
EOF

  chmod +x "${PREFIX}"/bin/llvm-config || return 1
  echo "✓ llvm-config wrapper created"
  return 0
}

################################################################################
# remove_qemu_llvm_config_wrapper
#
# Remove the QEMU wrapper for llvm-config and restore the original binary.
# Safe to call even if the wrapper was never created.
#
# Usage:
#   remove_qemu_llvm_config_wrapper
#
# Exit codes:
#   0 - Success
#   1 - Restore operation failed
################################################################################
function remove_qemu_llvm_config_wrapper() {
  if [[ -f "${PREFIX}"/bin/llvm-config.zig_conda_real ]]; then
    rm -f "${PREFIX}"/bin/llvm-config && mv "${PREFIX}"/bin/llvm-config.zig_conda_real "${PREFIX}"/bin/llvm-config || return 1
  fi
  return 0
}

################################################################################
# create_zig_libc_file
#
# Create a Zig libc configuration file for cross-compilation targets.
# This file tells Zig compiler where to find C library headers, startup files,
# and other libc components for the target architecture.
#
# The configuration includes:
# - include_dir: Path to C headers in sysroot
# - sys_include_dir: System headers path
# - crt_dir: C runtime object files (crt*.o)
# - gcc_dir: GCC library directory containing compiler runtime files
#
# Usage:
#   create_zig_libc_file "/tmp/libc.txt" "/path/to/sysroot" "aarch64"
#
# Parameters:
#   $1 - output_file: Path where the libc config file will be created
#   $2 - sysroot_path: Path to the target architecture sysroot
#   $3 - sysroot_arch: Target architecture name (e.g., "aarch64", "armv7l")
#
# Exit codes:
#   0 - Success
#   1 - Missing parameters or GCC library directory not found
#
# Dependencies:
#   - BUILD_PREFIX environment variable must be set
#   - GCC cross-compiler for sysroot_arch must be installed
################################################################################
function create_zig_libc_file() {
  local output_file=$1
  local sysroot_path=$2
  local sysroot_arch=$3

  if [[ -z "${output_file}" ]] || [[ -z "${sysroot_path}" ]] || [[ -z "${sysroot_arch}" ]]; then
    echo "ERROR: create_zig_libc_file requires: output_file, sysroot_path, sysroot_arch" >&2
    return 1
  fi

  echo "Creating Zig libc configuration file: ${output_file}"

  # Find GCC library directory (contains crtbegin.o, crtend.o)
  local gcc_lib_dir
  gcc_lib_dir=$(dirname "$(find "${BUILD_PREFIX}"/lib/gcc/${sysroot_arch}-conda-linux-gnu -name "crtbeginS.o" | head -1)")

  if [[ -z "${gcc_lib_dir}" ]] || [[ ! -d "${gcc_lib_dir}" ]]; then
    echo "WARNING: Could not find GCC library directory for ${sysroot_arch}" >&2
    gcc_lib_dir=""
  else
    echo "  Found GCC library directory: ${gcc_lib_dir}"
  fi

  # Create libc configuration file
  cat > "${output_file}" << EOF
include_dir=${sysroot_path}/usr/include
sys_include_dir=${sysroot_path}/usr/include
crt_dir=${sysroot_path}/usr/lib
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_lib_dir}
EOF

  echo "✓ Zig libc file created: ${output_file}"
  return 0
}
