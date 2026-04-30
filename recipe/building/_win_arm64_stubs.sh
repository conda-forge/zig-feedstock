# ARM64 Windows intrinsic stubs for win-arm64 cross-compilation.
# These resolve link-time symbols that lld can't auto-import on ARM64.
# Stubs are written to libarm64/ (MinGW arch-convention dir for ARM64 imports).

function create_chkstk_ms_stub() {
  # ___chkstk_ms (3 underscores on ARM64) -- stack probe called by MSVC ABI.
  # Minimal no-op: safe when stack size < guard page distance.
  local zig_bin="${1}"
  local win_target="${2}"
  local output_dir="${3}"
  local obj="${output_dir}/___chkstk_ms.o"

  [[ -f "${obj}" ]] && return 0

  local src="${output_dir}/_chkstk_ms_arm64.S"
  cat > "${src}" << 'EOF'
// ARM64 ___chkstk_ms stub -- probes stack pages for guard page support.
// On ARM64, the ABI uses 3 underscores. This minimal stub just returns
// (no-op probe), which is safe when stack size < guard page distance.
    .text
    .globl ___chkstk_ms
    .def ___chkstk_ms; .scl 2; .type 32; .endef
___chkstk_ms:
    ret
EOF

  "${zig_bin}" cc -target "${win_target}" -c "${src}" -o "${obj}" 2>/dev/null || true
  rm -f "${src}"
  dbg echo "=== Compiled ___chkstk_ms stub ==="
}

function create_fpreset_stub() {
  # _fpreset: zig's bundled CRT objects (crt2.obj, libmingw32.lib) contain
  # BL _fpreset (ARM64 branch). _fpreset lives in msvcrt.dll, but lld can't
  # auto-import via BRANCH26 relocations. ARM64 has no x87 FPU -- no-op.
  local zig_bin="${1}"
  local win_target="${2}"
  local output_dir="${3}"
  local obj="${output_dir}/_fpreset_arm64.o"

  [[ -f "${obj}" ]] && return 0

  local src="${output_dir}/_fpreset_arm64.c"
  cat > "${src}" << 'EOF'
// Static _fpreset stub for ARM64 Windows.
// ARM64 has no x87 FPU -- _fpreset is a no-op.
// Zig's bundled CRT objects call _fpreset via BL (branch) which generates
// IMAGE_REL_ARM64_BRANCH26 relocations that lld can't auto-import.
// This stub resolves the symbol at link time, avoiding the auto-import.
void _fpreset(void) {}
EOF

  "${zig_bin}" cc -target "${win_target}" -c "${src}" -o "${obj}" 2>/dev/null || true
  rm -f "${src}"
  dbg echo "=== Compiled _fpreset stub ==="
}

function create_setjmpex_stub() {
  # __intrinsic_setjmpex: setjmp variant for structured exception handling.
  # Real implementation is in the CRT; this provides a link-time fallback.
  local zig_bin="${1}"
  local win_target="${2}"
  local output_dir="${3}"
  local obj="${output_dir}/__intrinsic_setjmpex.o"

  [[ -f "${obj}" ]] && return 0

  local src="${output_dir}/_setjmpex_arm64.c"
  cat > "${src}" << 'EOF'
// Weak stub for __intrinsic_setjmpex on ARM64.
// Real implementation is in the CRT; this provides a link-time fallback.
typedef void *jmp_buf[32];
__attribute__((weak))
int __intrinsic_setjmpex(jmp_buf env, void *frame) {
    (void)env;
    (void)frame;
    return 0;
}
EOF

  "${zig_bin}" cc -target "${win_target}" -c "${src}" -o "${obj}" 2>/dev/null || true
  rm -f "${src}"
  dbg echo "=== Compiled __intrinsic_setjmpex stub ==="
}

function create_win_arm64_stubs() {
  # Create all ARM64 Windows intrinsic stubs.
  # output_dir should be the libarm64/ directory; it is created if absent.
  local zig_bin="${1}"
  local win_target="${2}"
  local output_dir="${3}"

  mkdir -p "${output_dir}"
  dbg echo "=== Compiling ARM64 intrinsic stubs ==="
  create_chkstk_ms_stub "${zig_bin}" "${win_target}" "${output_dir}"
  create_fpreset_stub "${zig_bin}" "${win_target}" "${output_dir}"
  create_setjmpex_stub "${zig_bin}" "${win_target}" "${output_dir}"
}
