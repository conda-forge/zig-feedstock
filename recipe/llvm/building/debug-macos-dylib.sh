#!/usr/bin/env bash
# Debug diagnostics for libLLVM.dylib symbol export failures on macOS.
# Sourced by build.sh when ZIG_LLVM_DEBUG=1 and symbol check fails.
# REMOVAL: delete this file + remove 3-line source block in build.sh.

debug_macos_dylib() {
  local _llvm_dylib="$1"
  local _test_sym="$2"
  local _build_dir="$3"

  echo "  === macOS dylib debug diagnostics ==="

  # --- Existing diagnostics (moved from build.sh) ---

  # Check if symbol exists but is hidden/local (lowercase 't')
  local _sym_line
  _sym_line=$({ nm "${_llvm_dylib}" 2>/dev/null | grep "${_test_sym}" | head -1; } || true)
  if [[ -n "${_sym_line}" ]]; then
    echo "    Found but HIDDEN: ${_sym_line}"
    echo "    -> zig cc is hiding the symbol despite -fvisibility=default"
    echo "    -> and LLVM_EXTERNAL_VISIBILITY attribute."
  else
    echo "    Symbol completely ABSENT from libLLVM.dylib"
    echo "    -> The AArch64AsmParser .o files were NOT linked into the dylib."
    echo "    -> Check zig-force-load-cxx: are archives being silently skipped?"
  fi

  # Show what LLVMInitialize* symbols ARE exported (for comparison)
  echo "    Exported LLVMInitialize* symbols (nm -g):"
  { nm -g "${_llvm_dylib}" 2>/dev/null | grep 'LLVMInitialize' | head -20 | sed 's/^/      /'; } || true
  echo "    All LLVMInitialize* symbols (nm, including hidden):"
  { nm "${_llvm_dylib}" 2>/dev/null | grep 'LLVMInitialize' | head -20 | sed 's/^/      /'; } || true

  # Show overall symbol stats
  local _total _global
  _total=$({ nm "${_llvm_dylib}" 2>/dev/null | wc -l; } || echo 0)
  _global=$({ nm -g "${_llvm_dylib}" 2>/dev/null | wc -l; } || echo 0)
  echo "    Total symbols: ${_total}, Global (exported): ${_global}"

  # Check if -Wl,-dead_strip leaked in despite LLVM_NO_DEAD_STRIP
  echo "    Checking for dead_strip in build.ninja:"
  { grep -r 'dead_strip' "${_build_dir}/build.ninja" 2>/dev/null | grep -i 'libLLVM' | head -5 | sed 's/^/      /'; } || echo "      (not found)"

  # Check AArch64AsmParser archive existence
  echo "    AArch64AsmParser archive check:"
  local _aarch64_lib
  _aarch64_lib=$(find "${_build_dir}" -name 'libLLVMAArch64AsmParser*' -type f 2>/dev/null | head -1)
  if [[ -n "${_aarch64_lib}" ]]; then
    echo "      EXISTS: ${_aarch64_lib}"
    echo "      Symbols in archive:"
    { nm "${_aarch64_lib}" 2>/dev/null | grep 'LLVMInitialize' | sed 's/^/        /'; } || echo "        (none found)"
  else
    echo "      MISSING: libLLVMAArch64AsmParser.a not found!"
  fi

  # --- NEW diagnostics: zig-force-load-cxx wrapper investigation ---

  echo ""
  echo "    === zig-force-load-cxx wrapper investigation ==="

  # Dump the link command for libLLVM.dylib from build.ninja
  echo "    libLLVM.dylib link command (build.ninja):"
  { grep -B2 -A20 'LINK_LIBRARIES.*libLLVM' "${_build_dir}/build.ninja" 2>/dev/null \
    | head -30 | sed 's/^/      /'; } || echo "      (could not extract link command)"

  # Check for -all_load / -force_load flags
  echo "    force_load / all_load flags in build.ninja:"
  { grep -E 'force_load|all_load' "${_build_dir}/build.ninja" 2>/dev/null \
    | head -10 | sed 's/^/      /'; } || echo "      (not found — archives may not be force-loaded)"

  # Show CMAKE_CXX_COMPILER in build.ninja (verify wrapper is used)
  echo "    CMAKE_CXX_COMPILER in build.ninja:"
  { grep 'CMAKE_CXX_COMPILER\|CXX_COMPILER' "${_build_dir}/build.ninja" 2>/dev/null \
    | head -5 | sed 's/^/      /'; } || echo "      (not found)"

  # Dump key lines from zig-force-load-cxx wrapper
  # ZIG_CXX is set to the wrapper path by build.sh (e.g. ${ZIG_WRAPPERS}/zig-force-load-cxx)
  local _wrapper=""
  for _try in \
    "${ZIG_CXX:-}" \
    "$(command -v zig-force-load-cxx 2>/dev/null || true)" \
    "${BUILD_PREFIX}/bin/zig-force-load-cxx" \
    "${PREFIX}/bin/zig-force-load-cxx"; do
    [[ -n "${_try}" && -f "${_try}" ]] && _wrapper="${_try}" && break
  done
  if [[ -n "${_wrapper}" && -f "${_wrapper}" ]]; then
    echo "    zig-force-load-cxx wrapper (${_wrapper}):"
    echo "      --- archive detection logic ---"
    { grep -n -A2 '\.a\b\|archive\|ar x\|force.load\|all_load' "${_wrapper}" 2>/dev/null \
      | head -20 | sed 's/^/      /'; } || echo "      (could not extract)"
  else
    echo "    zig-force-load-cxx wrapper: NOT FOUND"
  fi

  echo "    === end macOS dylib debug ==="
}
