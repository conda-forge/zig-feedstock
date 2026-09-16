#!/usr/bin/env python3
"""Regression test: dl_iterate_phdr must not trap on an ELF without PT_PHDR.

zig's std.posix.dl_iterate_phdr derives dl_phdr_info.addr by scanning the
program headers for PT_PHDR. Upstream falls off that loop into `unreachable`,
so a binary with no PT_PHDR segment panics with "reached unreachable code"
(ppc64le static links are the case we hit). Our patch
patches/ppc64le/posix.zig-dl-iterate-phdr-no-pt-phdr.patch replaces the
`else unreachable` with `else 0`.

langref exercises this incidentally, via doctests that panic and walk the
stack, but this test is the dedicated, always-on oracle for the path
regardless of skip_langref.

The test is only meaningful if the probe binary genuinely lacks PT_PHDR: a
binary that HAS one takes the `break` and passes with or without the patch.
That premise is asserted, and a violation is reported as INCONCLUSIVE rather
than PASS.

An optional zig_lib_dir argument points --zig-lib-dir at a different stdlib,
which is how the positive control is run: against an UNPATCHED lib dir this
test must FAIL with "reached unreachable code". If it passes there, the probe
is not reaching the patched code and a green result here proves nothing.

PARAMETERIZED OVER LINKER (LINKER_CASES below): PT_PHDR presence is a
property of the LINKER, not of -static -- ld.bfd omits PT_PHDR for a static
non-PIE ET_EXEC, LLD emits it even under -static (measured: round 4's
-static-only probe came out LLD-linked and carried PT_PHDR, giving an
INCONCLUSIVE result rather than exercising the patch; a follow-up measured
that `-fuse-ld=bfd` is inert -- see below -- so LLD-then-linked is the only
buildable starting point). So this file builds two cases:
  - lld            : expect PT_PHDR present  (the normal, now-default path)
  - synth-no-pt-phdr : PT_PHDR removed from the same LLD probe two ways --
                       null-in-place (zero the entry's p_type, touch nothing
                       else) and delete-and-shrink (remove the entry and
                       decrement e_phnum); comparing the two outcomes decides
                       whether an unloadable result means the image itself
                       is invalid or the surgery is.

BFD REACHABILITY -- INVESTIGATED, NEGATIVE RESULT: `-fuse-ld=bfd` is not
wired to anything in this toolchain and cannot currently be used to force
ld.bfd through `zig cc`/`zig build-exe` (see the comment above LINKER_CASES
for the full finding). Instead of relying on a bfd link, the second case
SYNTHESIZES a PT_PHDR-less binary: build the normal LLD probe, then rewrite
a copy of its ELF program-header table in place to remove the PT_PHDR entry
(_strip_pt_phdr, reusing the same raw-byte header parser as the reader
below), assert the removal actually took, and run the result. This restores
the positive-control coverage above without depending on a real ld.bfd link.
If the rewritten binary cannot even be executed (loader rejects it), that is
reported as a distinct INVALID finding, not folded into a patch-code FAIL.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

from _test_utils import _run, check_emulation_env

PROBE_SRC = """\
const std = @import("std");

fn callback(info: *std.posix.dl_phdr_info, size: usize, counter: *usize) error{}!void {
    _ = size;
    counter.* += 1;
    // .addr is the field the PT_PHDR scan computes; touch it so the
    // computation cannot be optimised out.
    std.mem.doNotOptimizeAway(info.addr);
}

pub fn main() !void {
    var counter: usize = 0;
    try std.posix.dl_iterate_phdr(&counter, error{}, callback);
    std.debug.print("dl_iterate_phdr ok, entries={d}\\n", .{counter});
}
"""

PANIC_RE = re.compile(r"reached unreachable code|panic:", re.IGNORECASE)


def _build(triplet: str, src: str, binary: str, zig_target: str,
           zig_lib_dir: str = "", extra_flags: list[str] | None = None,
           ) -> subprocess.CompletedProcess:
    # qemu-user does not PATH-search argv[0]; resolve it ourselves.
    zig = shutil.which(f"{triplet}-zig") or f"{triplet}-zig"
    cmd = [zig, "build-exe"]
    if zig_lib_dir:
        cmd += ["--zig-lib-dir", zig_lib_dir]
    # -static keeps the link non-PIE ET_EXEC, which is what drops PT_PHDR
    # (linker-dependent -- see LINKER_CASES).
    cmd += ["-target", zig_target, "-static"] + (extra_flags or [])
    cmd += ["-femit-bin=" + binary, src]
    # _run's 30s default is too low: zig build-exe under qemu has measured >149s.
    return _run(cmd, timeout=600, target=triplet)


_PT_PHDR = 6
_PT_NULL = 0


def _parse_ehdr(ehdr: bytes) -> tuple[str, int, int, int, int] | None:
    """Common ELF header fields needed for program-header work.

    Returns (endian, e_phoff, e_phentsize, e_phnum, e_phnum_off), or None if
    `ehdr` (the first bytes of a file) is not a parsable ELF header.
    e_phnum_off is the file offset of the e_phnum field itself (2 bytes,
    same width in both ELF classes), needed by callers that rewrite it.
    Shared by _read_program_headers (read-only) and _strip_pt_phdr /
    _null_pt_phdr (in-place edits) so the offset table exists in exactly
    one place.
    """
    if len(ehdr) < 20 or ehdr[:4] != b"\x7fELF":
        return None
    ei_class = ehdr[4]  # 1=32-bit, 2=64-bit
    ei_data = ehdr[5]  # 1=little-endian, 2=big-endian
    endian = "little" if ei_data == 1 else "big"
    if ei_class == 2 and len(ehdr) >= 64:
        e_phoff = int.from_bytes(ehdr[0x20:0x28], endian)
        e_phentsize = int.from_bytes(ehdr[0x36:0x38], endian)
        e_phnum = int.from_bytes(ehdr[0x38:0x3A], endian)
        e_phnum_off = 0x38
    elif ei_class == 1 and len(ehdr) >= 52:
        e_phoff = int.from_bytes(ehdr[0x1C:0x20], endian)
        e_phentsize = int.from_bytes(ehdr[0x2A:0x2C], endian)
        e_phnum = int.from_bytes(ehdr[0x2C:0x2E], endian)
        e_phnum_off = 0x2C
    else:
        return None
    return endian, e_phoff, e_phentsize, e_phnum, e_phnum_off


_PHDR64_FIELDS = [
    ("p_type", 0, 4), ("p_flags", 4, 4), ("p_offset", 8, 8), ("p_vaddr", 16, 8),
    ("p_paddr", 24, 8), ("p_filesz", 32, 8), ("p_memsz", 40, 8), ("p_align", 48, 8),
]
_PHDR32_FIELDS = [
    ("p_type", 0, 4), ("p_offset", 4, 4), ("p_vaddr", 8, 4), ("p_paddr", 12, 4),
    ("p_filesz", 16, 4), ("p_memsz", 20, 4), ("p_flags", 24, 4), ("p_align", 28, 4),
]


def _read_program_headers(binary: str) -> tuple[int, int, int, list[dict]] | None:
    """Full ELF program-header table for `binary`, or None if unparsable.

    Returns (e_phoff, e_phentsize, e_phnum, entries), each entry a dict of
    every Phdr field (p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz,
    p_memsz, p_align) as integers. 32/64-bit field layout is picked from
    e_phentsize (56 => ELF64, 32 => ELF32); anything else is unparsable.
    Raw-byte reader (mirrors _test_utils._elf_foreign_arch) so this does not
    depend on readelf/llvm-readelf being on PATH; ELF headers are
    self-describing regardless of the binary's target arch.
    """
    try:
        with open(binary, "rb") as f:
            ehdr = f.read(64)  # covers Elf32_Ehdr (52B) and Elf64_Ehdr (64B)
            parsed = _parse_ehdr(ehdr)
            if parsed is None:
                return None
            endian, e_phoff, e_phentsize, e_phnum, _e_phnum_off = parsed
            if e_phentsize == 56:
                fields = _PHDR64_FIELDS
            elif e_phentsize == 32:
                fields = _PHDR32_FIELDS
            else:
                return None
            f.seek(e_phoff)
            entries = []
            for _ in range(e_phnum):
                raw = f.read(e_phentsize)
                if len(raw) < e_phentsize:
                    break
                entries.append({
                    fname: int.from_bytes(raw[off:off + size], endian)
                    for fname, off, size in fields
                })
            return e_phoff, e_phentsize, e_phnum, entries
    except OSError:
        return None


def _read_program_header_types(binary: str) -> list[int] | None:
    """ELF program header p_type values for `binary`, or None if unparsable."""
    parsed = _read_program_headers(binary)
    if parsed is None:
        return None
    _e_phoff, _e_phentsize, _e_phnum, entries = parsed
    return [e["p_type"] for e in entries]


def _strip_pt_phdr(src: str, dst: str) -> None:
    """Copy `src` to `dst`, then rewrite `dst` to remove its PT_PHDR entry.

    Shifts the surviving program-header entries down over the removed one
    and decrements e_phnum in the ELF header, using the same endianness and
    32/64-bit width _parse_ehdr already derived from EI_DATA/EI_CLASS (never
    hardcoded, so this works unchanged on big-endian or 32-bit probes too).
    Raises ValueError if `src` has no PT_PHDR entry to strip.
    """
    shutil.copy(src, dst)
    os.chmod(dst, 0o755)
    with open(dst, "r+b") as f:
        ehdr = f.read(64)
        parsed = _parse_ehdr(ehdr)
        if parsed is None:
            raise ValueError(f"{src!r} is not a parsable ELF")
        endian, e_phoff, e_phentsize, e_phnum, e_phnum_off = parsed

        f.seek(e_phoff)
        raw = f.read(e_phentsize * e_phnum)
        entries = [raw[i * e_phentsize:(i + 1) * e_phentsize] for i in range(e_phnum)]
        kept = [e for e in entries if int.from_bytes(e[0:4], endian) != _PT_PHDR]
        if len(kept) == len(entries):
            raise ValueError(f"{src!r} has no PT_PHDR entry to strip")

        f.seek(e_phoff)
        f.write(b"".join(kept))
        # Zero the vacated tail so no stale bytes are misread as an entry.
        f.write(b"\x00" * (e_phentsize * (len(entries) - len(kept))))

        f.seek(e_phnum_off)
        f.write(len(kept).to_bytes(2, endian))


def _null_pt_phdr(src: str, dst: str) -> None:
    """Non-invasive counterpart to _strip_pt_phdr: zero the PT_PHDR entry's
    p_type field in place and touch nothing else. Preserving every other
    byte -- e_phnum, e_phoff, and every other Phdr field -- is the point.
    Raises ValueError if `src` has no PT_PHDR entry to null.
    """
    shutil.copy(src, dst)
    os.chmod(dst, 0o755)
    with open(dst, "r+b") as f:
        ehdr = f.read(64)
        parsed = _parse_ehdr(ehdr)
        if parsed is None:
            raise ValueError(f"{src!r} is not a parsable ELF")
        endian, e_phoff, e_phentsize, e_phnum, _e_phnum_off = parsed

        f.seek(e_phoff)
        index = None
        for i in range(e_phnum):
            entry = f.read(e_phentsize)
            if int.from_bytes(entry[0:4], endian) == _PT_PHDR:
                index = i
                break
        if index is None:
            raise ValueError(f"{src!r} has no PT_PHDR entry to null")

        f.seek(e_phoff + index * e_phentsize)
        f.write(_PT_NULL.to_bytes(4, endian))


def _has_pt_phdr(binary: str) -> bool:
    types = _read_program_header_types(binary)
    if types is not None:
        return _PT_PHDR in types
    # Raw parse failed (unexpected for a zig-built ELF); fall back to a tool
    # rather than hard-depending on readelf being on PATH.
    readelf = shutil.which("readelf")
    if not readelf:
        raise RuntimeError(
            f"cannot parse ELF program headers of {binary!r} and no readelf on PATH"
        )
    result = subprocess.run([readelf, "-l", binary], check=True,
                             capture_output=True, text=True)
    # Segment-type column; PT_PHDR renders as a bare "PHDR" token.
    return bool(re.search(r"^\s*PHDR\b", result.stdout, re.MULTILINE))


def _dump_segments(binary: str, label: str = "") -> None:
    """Best-effort diagnostic dump of binary's full program header table."""
    tag = f"{binary} ({label})" if label else binary
    parsed = _read_program_headers(binary)
    if parsed is not None:
        e_phoff, e_phentsize, e_phnum, entries = parsed
        print(f"program headers for {tag}: e_phoff=0x{e_phoff:x} "
              f"e_phnum={e_phnum} e_phentsize={e_phentsize}", file=sys.stderr)
        for i, e in enumerate(entries):
            print(f"  [{i}] p_type={e['p_type']} p_flags=0x{e['p_flags']:x} "
                  f"p_offset=0x{e['p_offset']:x} p_vaddr=0x{e['p_vaddr']:x} "
                  f"p_paddr=0x{e['p_paddr']:x} p_filesz=0x{e['p_filesz']:x} "
                  f"p_memsz=0x{e['p_memsz']:x} p_align=0x{e['p_align']:x}",
                  file=sys.stderr)
        return
    if shutil.which("readelf"):
        subprocess.run(["readelf", "-l", binary], check=False)


# ---------------------------------------------------------------------------
# Linker parameterization
# ---------------------------------------------------------------------------
# Investigated 2026-09-11: `-fuse-ld=bfd` is not wired to anything in this
# toolchain and cannot currently force ld.bfd through zig cc/build-exe:
#   - recipe/building/zig-cc-unix.c has zero "bfd" occurrences (grepped) --
#     the wrapper does not intercept, translate, or block the flag.
#   - Upstream zig's own cc-arg-parser (checked against vendored
#     tmp_patchgen/src/zig-0.15.2/src/main.zig, structurally representative)
#     has NO -fuse-ld= entry in its clang_arg table at all; an unmatched
#     flag falls into the generic `.other` case and is appended to cc_argv
#     verbatim -- it never reaches linker selection.
#   - patches/main.zig-fuse-ld-lld-cc-path.patch bolts recognition onto
#     EXACTLY the literal string "-fuse-ld=lld" inside that `.other` branch
#     (sets create_module.opts.use_lld = true). No other -fuse-ld=<X> value
#     is special-cased anywhere in this patch set.
# So "-fuse-ld=bfd" reaches zig as an inert passthrough token and cannot
# produce a genuine PT_PHDR-less link through zig cc/build-exe. 2026-09-11
# also measured directly: `-fuse-ld=bfd -static` still links with LLD and
# the output still HAS PT_PHDR. Given that, the bfd case below does not try
# to build via a linker flag at all -- it builds the normal LLD probe, then
# SYNTHESIZES a PT_PHDR-less binary by editing a copy's ELF program-header
# table directly (_strip_pt_phdr), reusing _parse_ehdr/_has_pt_phdr rather
# than a second implementation.
# Note: build-exe takes -flld/-fno-lld; -fuse-ld=lld is cc-path only.
LINKER_CASES = [
    {
        "name": "lld",
        "kind": "direct",
        # -fllvm required: self-hosted backends cannot link with LLD (x86_64 default)
        "extra_flags": ["-fllvm", "-flld"],
        "expect_pt_phdr": True,  # LLD emits PT_PHDR even under -static (measured).
    },
    {
        "name": "synth-no-pt-phdr",
        "kind": "synthesized",
        "methods": [
            ("null-in-place", _null_pt_phdr),
            ("delete-and-shrink", _strip_pt_phdr),
        ],
    },
]


def _run_linker_case(triplet: str, zig_target: str, zig_lib_dir: str,
                      tmpdir: str, case: dict) -> int:
    """Dispatch to the builder for one LINKER_CASES entry. 0 pass, 1 fail."""
    if case["kind"] == "synthesized":
        return _run_synth_case(triplet, zig_target, zig_lib_dir, tmpdir, case)
    return _run_direct_case(triplet, zig_target, zig_lib_dir, tmpdir, case)


def _run_direct_case(triplet: str, zig_target: str, zig_lib_dir: str,
                      tmpdir: str, case: dict) -> int:
    """Build+run a probe linked directly with case['extra_flags']."""
    name = case["name"]
    src = os.path.join(tmpdir, f"probe_{name}.zig")
    binary = os.path.join(tmpdir, f"probe_{name}")
    with open(src, "w") as f:
        f.write(PROBE_SRC)

    build = _build(triplet, src, binary, zig_target, zig_lib_dir,
                    extra_flags=case["extra_flags"])
    if build.returncode != 0:
        # Distinct from a runtime panic: a compile failure here usually
        # means the std.posix.dl_iterate_phdr signature drifted, not that
        # the PT_PHDR bug is back.
        print(f"FAIL [{name}]: could not build the dl_iterate_phdr probe "
              "(API drift, not a PT_PHDR result?)", file=sys.stderr)
        print(build.stdout, file=sys.stderr)
        print(build.stderr, file=sys.stderr)
        return 1

    has_phdr = _has_pt_phdr(binary)
    if has_phdr != case["expect_pt_phdr"]:
        got = "HAS" if has_phdr else "LACKS"
        want = "HAS" if case["expect_pt_phdr"] else "LACKS"
        print(f"INCONCLUSIVE [{name}]: probe binary {got} a PT_PHDR segment "
              f"(expected {want}), so it cannot exercise the intended path; "
              "adjust the link flags", file=sys.stderr)
        _dump_segments(binary)
        return 1

    result = _run([binary], timeout=600, target=triplet)
    combined = (result.stdout or "") + (result.stderr or "")

    if result.returncode == 0 and not PANIC_RE.search(combined):
        state = "with" if has_phdr else "without"
        print(f"PASS [{name}] dl_iterate_phdr survives an ELF {state} PT_PHDR")
        return 0

    state = "with" if has_phdr else "without"
    print(f"FAIL [{name}]: probe exited {result.returncode} on a binary "
          f"{state} PT_PHDR", file=sys.stderr)
    print("--- stdout ---", file=sys.stderr)
    print(result.stdout, file=sys.stderr)
    print("--- stderr ---", file=sys.stderr)
    print(result.stderr, file=sys.stderr)
    print("--- program headers (probe) ---", file=sys.stderr)
    _dump_segments(binary)
    return 1


def _run_synth_case(triplet: str, zig_target: str, zig_lib_dir: str,
                     tmpdir: str, case: dict) -> int:
    """Build one base LLD probe, then run every case['methods'] against it.

    The base build is the expensive step (zig build-exe under qemu has
    measured >149s), so it happens exactly once and is shared by both
    synthesis methods; comparing their outcomes is what lets a single CI
    run tell an unloadable image apart from invalid surgery.
    """
    name = case["name"]
    src = os.path.join(tmpdir, f"probe_{name}.zig")
    base_binary = os.path.join(tmpdir, f"probe_{name}_base")
    with open(src, "w") as f:
        f.write(PROBE_SRC)

    # -fllvm required: self-hosted backends cannot link with LLD (x86_64 default)
    build = _build(triplet, src, base_binary, zig_target, zig_lib_dir,
                    extra_flags=["-fllvm", "-flld"])
    if build.returncode != 0:
        print(f"FAIL [{name}]: could not build the base probe for ELF "
              "surgery (API drift, not a PT_PHDR result?)", file=sys.stderr)
        print(build.stdout, file=sys.stderr)
        print(build.stderr, file=sys.stderr)
        return 1

    if not _has_pt_phdr(base_binary):
        print(f"INCONCLUSIVE [{name}]: base probe already lacks PT_PHDR "
              "before surgery, so stripping it proves nothing", file=sys.stderr)
        return 1

    _dump_segments(base_binary, label="control, before surgery")

    rc = 0
    for method_name, method_fn in case["methods"]:
        label = f"synth-{method_name}"
        binary = os.path.join(
            tmpdir, f"probe_synth_{method_name.replace('-', '_')}")

        try:
            method_fn(base_binary, binary)
        except ValueError as exc:
            print(f"FAIL [{label}]: ELF surgery could not apply "
                  f"{method_name!r}: {exc}", file=sys.stderr)
            rc |= 1
            continue

        if _has_pt_phdr(binary):
            print(f"FAIL [{label}]: synthesis broke -- rewritten binary "
                  "STILL HAS a PT_PHDR segment after surgery", file=sys.stderr)
            _dump_segments(binary, label=method_name)
            rc |= 1
            continue

        try:
            result = _run([binary], timeout=600, target=triplet)
        except OSError as exc:
            # The kernel/qemu loader refused to even start the process (as
            # opposed to starting it and it crashing) -- distinct, louder
            # finding: this method's synthesis may itself be invalid.
            print(f"INVALID [{label}]: rewritten probe could not be "
                  f"executed at all ({type(exc).__name__}: {exc}) -- a "
                  "PT_PHDR-less static ET_EXEC is expected to be loadable "
                  "but was not; if null-in-place runs and delete-and-shrink "
                  "does not, the surgery is at fault -- if neither runs, "
                  "the image itself is rejected", file=sys.stderr)
            _dump_segments(binary, label=method_name)
            rc |= 1
            continue

        combined = (result.stdout or "") + (result.stderr or "")

        if result.returncode == 0 and not PANIC_RE.search(combined):
            print(f"PASS [{label}] dl_iterate_phdr survives a synthesized "
                  "ELF without PT_PHDR")
            continue

        if PANIC_RE.search(combined):
            print(f"FAIL [{label}]: probe exited {result.returncode} on a "
                  "PT_PHDR-less binary (unreachable hit -- patch 0004 not "
                  "in effect)", file=sys.stderr)
        else:
            print(f"INVALID [{label}]: rewritten probe exited "
                  f"{result.returncode} without panicking and without "
                  "exiting cleanly -- the loader may be rejecting the "
                  "PT_PHDR-less ELF outright; if null-in-place runs and "
                  "delete-and-shrink does not, the surgery is at fault -- "
                  "if neither runs, the image itself is rejected",
                  file=sys.stderr)
        print("--- stdout ---", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print("--- stderr ---", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        print("--- program headers (probe) ---", file=sys.stderr)
        _dump_segments(binary, label=method_name)
        rc |= 1

    return rc


def main(triplet: str, zig_target: str = "", zig_lib_dir: str = "") -> int:
    if not check_emulation_env(triplet):
        return 1
    if not zig_target:
        zig_target = triplet.replace("-conda", "") + ".2.17"

    with tempfile.TemporaryDirectory() as tmpdir:
        rc = 0
        for case in LINKER_CASES:
            rc |= _run_linker_case(triplet, zig_target, zig_lib_dir, tmpdir, case)
        return rc


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3, 4):
        sys.exit(f"usage: {sys.argv[0]} <conda_triplet> [zig_target] [zig_lib_dir]")
    sys.exit(main(
        sys.argv[1],
        sys.argv[2] if len(sys.argv) > 2 else "",
        sys.argv[3] if len(sys.argv) > 3 else "",
    ))