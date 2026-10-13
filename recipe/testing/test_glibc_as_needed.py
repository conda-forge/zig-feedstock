#!/usr/bin/env python3
"""
Regression test for conda-forge/zig-feedstock#209.

Cross-linking to *-linux-gnu must honour --as-needed for zig's bundled glibc
stubs (only referenced libs in DT_NEEDED) while still honouring an explicit
-Wl,--no-as-needed -lm. Runs identically on every host OS; reads DT_NEEDED with
a pure-Python ELF64-LE parser (no readelf).

  Case A: trivial main (issue repro, as C to skip a libc++ build) must not NEED
          librt/libutil/libresolv.
  Case B: -Wl,--no-as-needed -lm must keep libm.so.6 in DT_NEEDED.

Exit codes: 0 = both cases passed, 1 = at least one FAIL.
"""

from __future__ import annotations

import os
import shutil
import struct
import sys
import tempfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from _test_utils import (
    _build_is_win,
    _run,
    resolve_test_prefix,
    setup_zig_global_cache_dir,
    timed_out,
)

setup_zig_global_cache_dir()

_host = os.environ.get("CONDA_ZIG_HOST", "")
# Only emulated lanes run a foreign zig; cross-compiler lanes run a build-arch zig.
_triplet = _host.removesuffix("-zig") if os.environ.get("QEMU_EXECVE") else ""

_PT_LOAD = 1
_PT_DYNAMIC = 2
_DT_NULL = 0
_DT_NEEDED = 1
_DT_STRTAB = 5
_LINK_TIMEOUT_S = 300


def read_dt_needed(path: Path) -> list[str]:
    """Return DT_NEEDED names of an ELF64 little-endian file, in order."""
    data = path.read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{path.name}: not an ELF64 little-endian file")
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)

    loads: list[tuple[int, int, int]] = []  # (vaddr, offset, filesz)
    dyn: tuple[int, int] | None = None  # (offset, filesz)
    for i in range(e_phnum):
        p_type, _flags, p_off, p_vaddr, _paddr, p_filesz = struct.unpack_from(
            "<IIQQQQ", data, e_phoff + i * e_phentsize
        )
        if p_type == _PT_LOAD:
            loads.append((p_vaddr, p_off, p_filesz))
        elif p_type == _PT_DYNAMIC:
            dyn = (p_off, p_filesz)
    if dyn is None:
        return []

    needed_offs: list[int] = []
    strtab_vaddr = None
    off, size = dyn
    for pos in range(off, off + size, 16):
        tag, val = struct.unpack_from("<qQ", data, pos)
        if tag == _DT_NULL:
            break
        if tag == _DT_NEEDED:
            needed_offs.append(val)
        elif tag == _DT_STRTAB:
            strtab_vaddr = val
    if strtab_vaddr is None:
        return []

    strtab_off = None
    for vaddr, foff, filesz in loads:
        if vaddr <= strtab_vaddr < vaddr + filesz:
            strtab_off = foff + (strtab_vaddr - vaddr)
            break
    if strtab_off is None:
        raise ValueError(f"{path.name}: DT_STRTAB not covered by a PT_LOAD")

    names = []
    for n in needed_offs:
        start = strtab_off + n
        names.append(data[start:data.index(b"\0", start)].decode("ascii", "replace"))
    return names


def _find_zig() -> str | None:
    """Plain `zig` (as in the issue repro), not the triplet wrapper."""
    for name in ("zig", os.environ.get("CONDA_ZIG_BUILD"), os.environ.get("CONDA_ZIG_HOST")):
        found = name and shutil.which(name)
        if found:
            return found
    bindir = "Library/bin" if _build_is_win else "bin"
    prefix = resolve_test_prefix(bindir)
    cand = prefix / bindir / ("zig.exe" if _build_is_win else "zig")
    return str(cand) if cand.is_file() else None


def _case(label: str, zig: str, cmd_args: list[str], src_name: str, src: str,
          out_name: str, check) -> bool:
    with tempfile.TemporaryDirectory() as td:
        (Path(td) / src_name).write_text(src)
        r = _run([zig, *cmd_args], cwd=td, timeout=_LINK_TIMEOUT_S, target=_triplet or None)
        out = Path(td) / out_name
        if r.returncode != 0 or not out.is_file():
            tail = "TIMEOUT" if timed_out(r) else "\n".join(r.stderr.splitlines()[-15:])
            print(f"{label} NEEDED: <link failed>")
            print(f"{label}: FAIL (compile/link rc={r.returncode}) {tail}")
            return False
        needed = read_dt_needed(out)
        print(f"{label} NEEDED: {' '.join(needed)}")
        ok, detail = check(needed)
        print(f"{label}: {'PASS' if ok else 'FAIL'} ({detail})")
        return ok


def _check_a(needed: list[str]) -> tuple[bool, str]:
    bad = [n for n in ("librt.so.1", "libutil.so.1", "libresolv.so.2") if n in needed]
    return (not bad, f"unreferenced libs in DT_NEEDED: {bad}" if bad else "no spurious libs")


def _check_b(needed: list[str]) -> tuple[bool, str]:
    ok = "libm.so.6" in needed
    return (ok, "libm.so.6 present" if ok else "libm.so.6 dropped despite --no-as-needed -lm")


def main() -> int:
    print("=== zig glibc --as-needed tests (zig-feedstock#209) ===")
    zig = _find_zig()
    if not zig:
        print("GLIBC-AS-NEEDED: FAIL (zig executable not found)")
        return 1
    print(f"  zig = {zig}")
    if os.environ.get("QEMU_EXECVE"):
        print("  note: emulated lane; zig runs under qemu, output is only parsed")

    a_ok = _case(
        "GLIBC-AS-NEEDED-A", zig,
        ["cc", "-target", "x86_64-linux-gnu.2.3.3", "-O2", "t.c", "-o", "t"],
        "t.c", "int main(void){return 0;}\n", "t", _check_a,
    )
    b_ok = _case(
        "GLIBC-AS-NEEDED-B", zig,
        ["cc", "-target", "x86_64-linux-gnu.2.28", "-Wl,--no-as-needed", "-lm",
         "t.c", "-o", "t2"],
        "t.c", "int main(void){return 0;}\n", "t2", _check_b,
    )
    return 0 if (a_ok and b_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
