#!/usr/bin/env python3
"""Regression probe for posix.zig-dl-iterate-phdr-no-pt-phdr.patch.

The patch fixes dl_iterate_phdr's single-image (no-dynamic-link-segment)
fallback, which previously hit `unreachable` when the running ELF had no
PT_PHDR program header (e.g. a static non-PIE executable). This probe
synthesizes that PT_PHDR-less case deterministically -- by editing a built
binary's ELF program header table in pure Python -- rather than guessing
which linker/flags omit PT_PHDR, since that varies by toolchain and is not
what this test is meant to pin down.

Without the patch, the panic deadlocks in futex forever inside the
stack-trace printer (see the patch header), so a TIMEOUT on the experiment
run is the expected failure signature, not a harness error.
"""
from __future__ import annotations

import struct
import sys
import tempfile
from pathlib import Path

from _test_utils import FAIL, PASS, SKIP, _run, check_emulation_env, resolve_test_prefix, timed_out

_LINK_TIMEOUT_S = 900  # emulated zig build-exe compile+link needs headroom
_RUN_TIMEOUT_S = 30    # a hung process (patch absent) must not stall CI forever

_ZIG_SRC = """\
const std = @import("std");

const IterError = error{};

fn cb(info: *std.posix.dl_phdr_info, size: usize, counter: *usize) IterError!void {
    _ = info;
    _ = size;
    counter.* += 1;
}

pub fn main() void {
    var counter: usize = 0;
    std.posix.dl_iterate_phdr(&counter, IterError, cb) catch unreachable;
    std.process.exit(0);
}
"""

_prefix = resolve_test_prefix("bin")
_wrapper_dir = _prefix / "bin"

# ELF64 constants (struct module only -- no external tools).
_PT_NULL = 0
_PT_PHDR = 6
_EI_DATA = 5
_ELFDATA2LSB = 1
_ELFDATA2MSB = 2


def _elf_endian_fmt(data: bytes) -> str:
    ei_data = data[_EI_DATA]
    if ei_data == _ELFDATA2LSB:
        return "<"
    if ei_data == _ELFDATA2MSB:
        return ">"
    raise ValueError(f"unrecognised e_ident[EI_DATA]={ei_data}")


_PT_NAMES = {
    0: "NULL",
    1: "LOAD",
    2: "DYNAMIC",
    3: "INTERP",
    4: "NOTE",
    6: "PHDR",
    7: "TLS",
    0x6474E550: "GNU_EH_FRAME",
    0x6474E551: "GNU_STACK",
    0x6474E552: "GNU_RELRO",
}


def _dump_program_headers(label: str, path: Path) -> None:
    """Print the ELF program header table for diagnostics only.

    Best-effort: any exception is caught and reported, never raised.
    """
    try:
        data = path.read_bytes()
        endian = _elf_endian_fmt(data)
        (e_phoff,) = struct.unpack_from(endian + "Q", data, 0x20)
        (e_phentsize,) = struct.unpack_from(endian + "H", data, 0x36)
        (e_phnum,) = struct.unpack_from(endian + "H", data, 0x38)
        print(f"[phdr-dump] {label}: e_phoff=0x{e_phoff:x} e_phnum={e_phnum} "
              f"e_phentsize={e_phentsize}")
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            (p_type, p_flags) = struct.unpack_from(endian + "II", data, off)
            (p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align) = \
                struct.unpack_from(endian + "QQQQQQ", data, off + 8)
            name = _PT_NAMES.get(p_type, "")
            name_suffix = f"({name})" if name else ""
            print(f"[phdr-dump]   [{i}] p_type=0x{p_type:x}{name_suffix} "
                  f"p_flags=0x{p_flags:x} p_offset=0x{p_offset:x} "
                  f"p_vaddr=0x{p_vaddr:x} p_paddr=0x{p_paddr:x} "
                  f"p_filesz=0x{p_filesz:x} p_memsz=0x{p_memsz:x} "
                  f"p_align=0x{p_align:x}")
    except Exception as exc:
        print(f"[phdr-dump] {label}: dump failed: {exc}")


def _flip_pt_phdr_to_null(src: Path, dst: Path) -> bool:
    """Copy src to dst, rewriting a PT_PHDR entry's p_type to PT_NULL.

    Returns True if a PT_PHDR entry was found and rewritten, False if the
    binary already has none (already the target case -- caller uses dst,
    which is byte-identical to src, as-is).

    Reads e_phoff/e_phentsize/e_phnum from the ELF header rather than
    assuming fixed offsets, and supports both ELF64 endiannesses via
    e_ident[EI_DATA].
    """
    data = bytearray(src.read_bytes())
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{src}: not an ELF file")
    endian = _elf_endian_fmt(data)
    ei_class = data[4]
    if ei_class != 2:
        raise ValueError(f"{src}: expected ELFCLASS64, got EI_CLASS={ei_class}")

    (e_phoff,) = struct.unpack_from(endian + "Q", data, 0x20)
    (e_phentsize,) = struct.unpack_from(endian + "H", data, 0x36)
    (e_phnum,) = struct.unpack_from(endian + "H", data, 0x38)

    found = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        (p_type,) = struct.unpack_from(endian + "I", data, off)
        if p_type == _PT_PHDR:
            struct.pack_into(endian + "I", data, off, _PT_NULL)
            found = True
            break

    dst.write_bytes(bytes(data))
    dst.chmod(0o755)
    return found


def main(conda_triplet: str, zig_triplet: str) -> int:
    if not check_emulation_env(conda_triplet):
        return 1

    zig_bin = _wrapper_dir / f"{conda_triplet}-zig"
    if not zig_bin.is_file():
        FAIL("resolved zig wrapper found", f"not found: {zig_bin}")
        return 1

    with tempfile.TemporaryDirectory() as tmpdir:
        td = Path(tmpdir)
        src = td / "probe.zig"
        control = td / "probe_control"
        modified = td / "probe_modified"
        src.write_text(_ZIG_SRC)

        # Static + non-PIE: the toolchain configuration the patch's own
        # header measured as PT_PHDR-less under GNU ld/bfd. We still
        # synthesize the PT_PHDR-less case below rather than relying on
        # that, since it is linker-dependent and not what this test pins.
        build = _run(
            [str(zig_bin), "build-exe", str(src), "-fno-PIE", "-static",
             "-target", zig_triplet, f"-femit-bin={control}"],
            timeout=_LINK_TIMEOUT_S,
            target=conda_triplet,
        )
        if build.returncode != 0 or not control.is_file():
            FAIL("dl_iterate_phdr PT_PHDR probe", "zig build-exe failed")
            print(build.stdout, file=sys.stderr)
            print(build.stderr, file=sys.stderr)
            return 1

        _dump_program_headers("control (pre-flip)", control)

        found = _flip_pt_phdr_to_null(control, modified)
        note = "" if found else "control binary already had no PT_PHDR entry"

        try:
            if found:
                print("[linker-diag] control carries PT_PHDR -> linked by LLD")
            else:
                print("[linker-diag] control lacks PT_PHDR -> linked by ld.bfd "
                      "or another linker that omits it")
        except Exception as exc:
            print(f"[linker-diag] diagnostic failed: {exc}")

        if modified.is_file():
            _dump_program_headers("modified (post-flip)", modified)

        # CONTROL RUN: only an environment check when a PT_PHDR was actually
        # removed; if none was found, control equals modified and this run
        # IS the assertion.
        ctrl_run = _run([str(control)], timeout=_RUN_TIMEOUT_S, target=conda_triplet)
        if ctrl_run.returncode != 0:
            if not found:
                FAIL("dl_iterate_phdr tolerates missing PT_PHDR",
                     f"control binary has no PT_PHDR and did not exit 0 "
                     f"(rc={ctrl_run.returncode}, timeout={timed_out(ctrl_run)})")
                return 1
            SKIP("dl_iterate_phdr PT_PHDR probe",
                 f"control binary did not exit 0 (rc={ctrl_run.returncode}, "
                 f"timeout={timed_out(ctrl_run)}); environment cannot run "
                 "target binaries, probe inconclusive")
            return 0

        # EXPERIMENT RUN: with the patch, the single-image fallback treats a
        # missing PT_PHDR as bias 0 and returns normally (exit 0). Without
        # it, `unreachable` panics, and the panic deadlocks in futex forever
        # inside the stack-trace printer -- so a TIMEOUT here is the
        # expected failure signature, not a harness error.
        exp_run = _run([str(modified)], timeout=_RUN_TIMEOUT_S, target=conda_triplet)
        if timed_out(exp_run):
            FAIL("dl_iterate_phdr tolerates missing PT_PHDR",
                 "TIMEOUT -- unreachable panic deadlocked in futex "
                 "(patch appears absent or ineffective)" + (f"; {note}" if note else ""))
            return 1
        if exp_run.returncode != 0:
            FAIL("dl_iterate_phdr tolerates missing PT_PHDR",
                 f"rc={exp_run.returncode}" + (f"; {note}" if note else ""))
            return 1

        PASS("dl_iterate_phdr tolerates missing PT_PHDR", note)
        return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <conda_triplet> <zig_triplet>")
    sys.exit(main(sys.argv[1], sys.argv[2]))
