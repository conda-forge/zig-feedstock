#!/usr/bin/env python3
"""Build-29 item 3/4 stack-realloc probe (diagnostic, runs in Windows CI test phase).

Compiles recipe/building/spike_realloc_probe.c with the zig cc wrapper and runs it on
win-64, capturing which exception the deep stack-realloc path raises:
  ACCESS_VIOLATION 0xC0000005 -> item 4 (__chkstk probe bypass)
  STACK_OVERFLOW   0xC00000FD -> clean overflow / item 6 (reserve)
Also builds a -Wl,--stack,0x4000000 variant (exercises wrapper P-4 -> /STACK:) to test
whether a larger reserve removes the fault (item 6). NON-FATAL: always returns 0; the
verdict is surfaced in the CI log for triage, it does not gate the package.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from _test_utils import PASS, SKIP, WARN, _run, get_zig_wrapper

AV = 0xC0000005
SO = 0xC00000FD


def _target_arch():
    host = os.environ.get("CONDA_ZIG_HOST", "")
    t = host[:-4] if host.endswith("-zig") else host
    if "aarch64" in t or "arm64" in t:
        return "arm64"
    if "x86_64" in t or "amd64" in t:
        return "x86_64"
    return "?"


def _verdict(rc, out):
    u = rc & 0xFFFFFFFF
    if "ACCESS_VIOLATION" in out or u == AV:
        return "ACCESS_VIOLATION 0xC0000005 -> item4 (__chkstk probe bypass)"
    if "STACK_OVERFLOW" in out or u == SO:
        return "STACK_OVERFLOW 0xC00000FD -> overflow/item6 (reserve)"
    if "SURVIVED" in out:
        return "SURVIVED (no fault at this depth)"
    return "other rc=%d (0x%08x)" % (rc, u)


def _find_src():
    here = Path(__file__).resolve().parent
    for cand in (here.parent / "building" / "spike_realloc_probe.c", here / "spike_realloc_probe.c"):
        if cand.exists():
            return cand
    return None


def main():
    print("=== stack-realloc probe (build-29 item 3/4 diagnostic) ===")
    print("  CONDA_ZIG_HOST = %r" % os.environ.get("CONDA_ZIG_HOST", ""))
    if sys.platform != "win32":
        SKIP("stack-probe", "not a Windows host -- runs only in win CI test phase")
        return 0
    cc = get_zig_wrapper("cc")
    if not cc.exists():
        SKIP("stack-probe", "cc wrapper not found")
        return 0
    src = _find_src()
    if src is None:
        SKIP("stack-probe", "spike_realloc_probe.c not found")
        return 0

    td = tempfile.mkdtemp()
    exe = os.path.join(td, "probe.exe")
    exe_big = os.path.join(td, "probe_big.exe")

    r = _run([str(cc), "-O2", str(src), "-o", exe], timeout=180)
    if r.stderr in ("NOTFOUND", "TIMEOUT") or r.returncode != 0:
        WARN("stack-probe: compile", "compile failed rc=%s: %s" % (r.returncode, (r.stderr or "")[:200]))
        return 0
    PASS("stack-probe: compiled with zig cc wrapper")

    rb = _run([str(cc), "-O2", "-Wl,--stack,0x4000000", str(src), "-o", exe_big], timeout=180)
    if rb.returncode == 0:
        PASS("stack-probe: -Wl,--stack,0x4000000 variant compiled (exercises wrapper P-4)")
    else:
        WARN("stack-probe: bigstack compile", "rc=%s" % rb.returncode)

    arch = _target_arch()
    if arch != "x86_64":
        SKIP("stack-probe: run", "target arch %s not runnable on x86_64 host -- compile-only" % arch)
        return 0

    for tag, e in (("default", exe), ("bigstack", exe_big)):
        if not os.path.exists(e):
            continue
        rr = _run([e, "200000"], timeout=180)
        out = (rr.stderr or "") + (rr.stdout or "")
        v = _verdict(rr.returncode, out)
        print("[probe:%s] rc=%s verdict: %s" % (tag, rr.returncode, v))
        WARN("stack-probe:%s" % tag, v)

    return 0  # diagnostic only: never fail the build


if __name__ == "__main__":
    sys.exit(main())
