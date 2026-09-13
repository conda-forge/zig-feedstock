#!/usr/bin/env python3
"""Verify <triplet>-zig-cc wrapper: -Wl,-eSYM to -Wl,/ENTRY:SYM translation on Windows."""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Ensure stdout/stderr are UTF-8 on Windows (system ANSI codepage breaks
# rattler-build's UTF-8 stream reader even when tests pass).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# Success-path verbose diagnostics (matrix + DIAG probes) are gated behind
# DEBUG_ZIG_BUILD=1; failure-path output always prints unconditionally.
DIAG = os.environ.get("DEBUG_ZIG_BUILD", "0") == "1"


def _fail(zig_cc_exe: str, argv: list[str], result: subprocess.CompletedProcess[str], label: str) -> None:
    """Emit the full argv, untruncated stderr, and a -v re-run's link line, then exit."""
    print(f"FAIL: [{zig_cc_exe}] {label} (rc={result.returncode})", flush=True)
    print(f"ARGV: {' '.join(argv)}", flush=True)
    print(f"STDERR:\n{result.stderr}", flush=True)
    verbose = subprocess.run([*argv, "-v"], capture_output=True, text=True, check=False)
    print(f"VERBOSE RERUN rc={verbose.returncode}", flush=True)
    print(f"VERBOSE STDOUT:\n{verbose.stdout[:20000]}", flush=True)
    print(f"VERBOSE STDERR:\n{verbose.stderr[:20000]}", flush=True)
    sys.stdout.flush()
    sys.exit(f"FAIL: [{zig_cc_exe}] {label}")


def _pe_entry_rva(path):
    """Return AddressOfEntryPoint from a PE image, or None."""
    try:
        data = path.read_bytes()
        if data[:2] != b"MZ":
            return None
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
            return None
        # COFF header is 20 bytes after the 4-byte signature; the optional
        # header starts there and AddressOfEntryPoint sits at offset 16.
        return struct.unpack_from("<I", data, e_lfanew + 4 + 20 + 16)[0]
    except Exception:
        return None


def _coff_undefined_symbols(path):
    """Return the set of undefined symbol names in a COFF object, or None.

    A symbol whose SectionNumber is 0 (IMAGE_SYM_UNDEFINED) is a reference the
    object expects someone else to define. Object files have no MZ/PE header;
    the COFF header starts at offset 0.
    """
    try:
        data = path.read_bytes()
        # COFF header: Machine(2) NumberOfSections(2) TimeDateStamp(4)
        #              PointerToSymbolTable(4) NumberOfSymbols(4)
        ptr, nsyms = struct.unpack_from("<II", data, 8)
        if ptr == 0 or nsyms == 0:
            return None
        strtab = ptr + nsyms * 18
        found = set()
        i = 0
        while i < nsyms:
            off = ptr + i * 18
            raw = data[off:off + 8]
            secnum = struct.unpack_from("<h", data, off + 12)[0]
            naux = data[off + 17]
            if raw[:4] == b"\x00\x00\x00\x00":
                stroff = struct.unpack_from("<I", data, off + 4)[0]
                end = data.index(b"\x00", strtab + stroff)
                name = data[strtab + stroff:end].decode("ascii", "replace")
            else:
                name = raw.rstrip(b"\x00").decode("ascii", "replace")
            if secnum == 0 and name:
                found.add(name)
            i += 1 + naux
        return found
    except Exception:
        return None


def main() -> None:
    # Select the wrapper for THIS lane's target: honour CONDA_ZIG_HOST/ZIG_CC
    # instead of a fixed-order PATH probe (that always picked x86_64 first).
    candidates = [
        "x86_64-w64-mingw32-zig-cc",
        "i686-w64-mingw32-zig-cc",
        "aarch64-w64-mingw32-zig-cc",
    ]
    zig_cc_exe = None
    selected_via = None

    zig_cc_env = os.environ.get("ZIG_CC")
    if zig_cc_env:
        found = shutil.which(zig_cc_env) or (zig_cc_env if Path(zig_cc_env).is_file() else None)
        if found:
            zig_cc_exe = found
            selected_via = "ZIG_CC"

    if zig_cc_exe is None:
        conda_zig_host = os.environ.get("CONDA_ZIG_HOST")
        if conda_zig_host:
            found = shutil.which(f"{conda_zig_host}-cc")
            if found:
                zig_cc_exe = found
                selected_via = "CONDA_ZIG_HOST"

    if zig_cc_exe is None:
        for candidate in candidates:
            found = shutil.which(candidate)
            if found:
                zig_cc_exe = found
                selected_via = "candidate list fallback"
                break

    if zig_cc_exe is None:
        sys.stdout.flush()
        sys.exit("FAIL: no <arch>-w64-mingw32-zig-cc wrapper found on PATH")

    on_path = [c for c in candidates if shutil.which(c)]
    print(f"INFO: using wrapper: {zig_cc_exe} (selected via {selected_via})")
    print(f"INFO: wrappers on PATH: {', '.join(on_path)}")

    # Base TU: two candidate entry points, deliberately no main and no WinMain.
    # The second symbol (OtherEntry) exists purely so the PE entry-RVA
    # diagnostic below can prove -Wl,-e SELECTS a named symbol rather than
    # merely being tolerated by the linker.
    c_source_base = """#include <windows.h>
void MyEntry(void) { ExitProcess(0); }
void OtherEntry(void) { ExitProcess(1); }
"""

    # Fail-over ladder for custom -Wl,-e entry translation. Open question: reference doc S6.
    #
    # (name, extra_flags, extra_source, strict)
    VARIANTS = [
        ("nostartfiles",          ["-Wl,--subsystem,console", "-nostartfiles"], "", True),
        ("baseline",              ["-Wl,--subsystem,console"], "", False),
        ("nostartfiles_nosubsys", ["-nostartfiles"], "", True),
        ("nodefaultlibs",         ["-Wl,--subsystem,console", "-nostartfiles",
                                   "-nodefaultlibs", "-lkernel32"], "", True),
        ("subsystem_windows",     ["-Wl,--subsystem,windows"], "", False),
        ("subsystem_windows_stub",["-Wl,--subsystem,windows"],
                                  "int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d)\n"
                                  "{ (void)a; (void)b; (void)c; (void)d; return 0; }\n", False),
        ("no_subsystem_flag",     [], "", False),
        ("nostartfiles_force_u",  ["-Wl,--subsystem,console", "-nostartfiles",
                                   "-Wl,-u,MyEntry"], "", True),
        ("with_main",             ["-Wl,--subsystem,console"],
                                  "int main(void) { return 0; }\n", False),
        ("with_winmain_stub",     ["-Wl,--subsystem,console"],
                                  "int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d)\n"
                                  "{ (void)a; (void)b; (void)c; (void)d; return 0; }\n", False),
        ("with_both",             ["-Wl,--subsystem,console"],
                                  "int main(void) { return 0; }\n"
                                  "int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d)\n"
                                  "{ (void)a; (void)b; (void)c; (void)d; return 0; }\n", False),
        ("nostartfiles_with_main",["-Wl,--subsystem,console", "-nostartfiles"],
                                  "int main(void) { return 0; }\n", True),
    ]

    # "driver" is a probe of driver-level flag acceptance; it never gates.
    ENTRY_FORMS = [
        ("concat", ["-Wl,-eMyEntry"]),
        ("comma",  ["-Wl,-e,MyEntry"]),
        ("driver", ["-e", "MyEntry"]),
        ("long",   ["-Wl,--entry,MyEntry"]),
    ]

    PER_LINK_TIMEOUT_S = 300
    TOTAL_BUDGET_S = 700

    started = time.monotonic()
    results = {}

    def _budget_left():
        return TOTAL_BUDGET_S - (time.monotonic() - started)

    def _run_link(tmpdir_path, form_name, form_flags, var_name, extra, src_extra):
        if _budget_left() <= 0:
            return ("SKIP", "budget exhausted", "")
        tag = f"{form_name}_{var_name}"
        c_file = tmpdir_path / f"{tag}.c"
        exe_file = tmpdir_path / f"{tag}.exe"
        c_file.write_text(c_source_base + src_extra)
        argv = [zig_cc_exe] + form_flags + extra + [str(c_file), "-o", str(exe_file)]
        t0 = time.monotonic()
        try:
            r = subprocess.run(argv, capture_output=True, text=True, check=False,
                               timeout=min(PER_LINK_TIMEOUT_S, max(1, int(_budget_left()))))
        except subprocess.TimeoutExpired:
            return ("TIMEOUT", f"{PER_LINK_TIMEOUT_S}s", "")
        elapsed = time.monotonic() - t0
        if r.returncode != 0:
            first = ""
            for line in (r.stderr or "").splitlines():
                if "error" in line.lower():
                    first = line.strip()
                    break
            return ("FAIL", f"rc={r.returncode} {elapsed:.0f}s {first}", r.stderr or "")
        if not exe_file.is_file() or exe_file.stat().st_size == 0:
            return ("FAIL", f"no/empty output {elapsed:.0f}s", r.stderr or "")
        return ("PASS", f"{elapsed:.0f}s {exe_file.stat().st_size}B", "")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)

        # The first link of a run pays for compiling zig's mingw libc from
        # source; warm that cache with one unscored link before the matrix so
        # the first real matrix cell isn't the one that eats the compile cost.
        if DIAG:
            print("INFO: cache-warm link (unscored) ...")
        warm = _run_link(tmpdir_path, "warm", ["-Wl,-eMyEntry"],
                         "warm", ["-Wl,--subsystem,console"],
                         "int main(void) { return 0; }\n")
        if DIAG:
            print(f"INFO: cache-warm result: {warm[0]} {warm[1]}")

        # Full matrix: every variant against every entry form. No pruning —
        # the caller wants the whole picture in one CI pass.
        for form_name, form_flags in ENTRY_FORMS:
            for var_name, extra, src_extra, _strict in VARIANTS:
                results[(form_name, var_name)] = _run_link(
                    tmpdir_path, form_name, form_flags, var_name, extra, src_extra)

        print("=== failing-cell detail (link diagnostics) ===")
        for form_name, _flags in ENTRY_FORMS:
            for var_name, _e, _s, _st in VARIANTS:
                key = (form_name, var_name)
                if key not in results:
                    continue
                status, _detail, stderr_text = results[key]
                if status != "FAIL" or not stderr_text:
                    continue
                keep = [ln for ln in stderr_text.splitlines()
                        if ("error" in ln.lower() or ">>>" in ln)]
                if not keep:
                    continue
                print(f"  --- {form_name} {var_name} ---")
                for ln in keep[:20]:
                    print(f"    {ln.strip()[:300]}")
        print("=== end failing-cell detail ===")
        sys.stdout.flush()

        if DIAG:
            print("")
            print("=== diagnostics ===")

            # (a) wrapper identity
            try:
                wv = subprocess.run([zig_cc_exe, "-v"], capture_output=True, text=True,
                                     check=False, timeout=60)
                lines = (wv.stderr or "").splitlines()[:5]
                print("DIAG wrapper identity (-v stderr, first 5 lines):")
                for line in lines:
                    print(f"  {line}")
            except Exception as exc:
                print(f"DIAG wrapper identity: failed ({exc})")

            # (b) verbose link line for baseline and the nostartfiles cells --
            # confirms whether crt2.o really left the link line under
            # -nostartfiles, rather than assuming the driver honoured the flag.
            try:
                entry_flags = ENTRY_FORMS[0][1]
                for diag_var_name in ("baseline", "nostartfiles", "nostartfiles_nosubsys"):
                    diag_variant = next(v for v in VARIANTS if v[0] == diag_var_name)
                    _dname, dextra, dsrc, _dstrict = diag_variant
                    c_file = tmpdir_path / f"diag_{diag_var_name}.c"
                    exe_file = tmpdir_path / f"diag_{diag_var_name}.exe"
                    c_file.write_text(c_source_base + dsrc)
                    argv = ([zig_cc_exe] + entry_flags + dextra +
                             [str(c_file), "-o", str(exe_file), "-v"])
                    r = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=120)
                    combined = (r.stdout or "") + (r.stderr or "")
                    found_any = False
                    for line in combined.splitlines():
                        if "lld-link" in line:
                            found_any = True
                            print(f"DIAG lld-link line [{diag_var_name}]: {line[:2000]}")
                    if not found_any:
                        print(f"DIAG lld-link line [{diag_var_name}]: not found in verbose output")
            except Exception as exc:
                print(f"DIAG lld-link line: failed ({exc})")

            # (b2) crt2.obj presence and symbol-table diagnostic: distinguishes
            # whether crt2.obj is dropped from the link line (case 1), present but
            # built without a `main` reference (case 2), or present and does
            # reference `main` (case 3) -- cases 2 and 3 are indistinguishable from
            # the command line alone, so the object's own symbol table must be
            # inspected.
            try:
                baseline_variant = next(v for v in VARIANTS if v[0] == "baseline")
                _bname, bextra, bsrc, _bstrict = baseline_variant
                concat_flags = ENTRY_FORMS[0][1]
                c_file = tmpdir_path / "diag_crt2.c"
                exe_file = tmpdir_path / "diag_crt2.exe"
                c_file.write_text(c_source_base + bsrc)
                argv = ([zig_cc_exe] + concat_flags + bextra +
                         [str(c_file), "-o", str(exe_file), "-v"])
                r = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=120)
                combined = (r.stdout or "") + (r.stderr or "")

                link_line = None
                for line in combined.splitlines():
                    if "lld-link" in line:
                        link_line = line
                        break

                crt2_token = None
                if link_line is not None:
                    for token in link_line.split():
                        if token.lower().endswith("crt2.obj"):
                            crt2_token = token
                            break

                if crt2_token is None:
                    print("DIAG crt2.obj: ABSENT from link line "
                          "(case 1 - driver places different objects per target)")
                else:
                    print(f"DIAG crt2.obj path: {crt2_token}")
                    undefined = _coff_undefined_symbols(Path(crt2_token))
                    if undefined is None:
                        print("DIAG crt2.obj: present, symbol table unreadable")
                    else:
                        has_main = "main" in undefined
                        has_main_decorated = "_main" in undefined
                        print(f"DIAG crt2.obj undefined symbol count: {len(undefined)}")
                        if has_main:
                            print("DIAG crt2.obj references main: YES (as 'main')")
                        elif has_main_decorated:
                            print("DIAG crt2.obj references main: YES (as '_main')")
                        else:
                            print("DIAG crt2.obj references main: NO")
                        if has_main or has_main_decorated:
                            print("DIAG case 3: crt2.obj present AND references main - "
                                  "resolver unidentified")
                        else:
                            print("DIAG case 2: crt2.obj present but does NOT reference "
                                  "main - objects differ per target")
                        print("DIAG crt2.obj undefined symbols (first 15):")
                        for sym in sorted(undefined)[:15]:
                            print(f"    {sym}")
            except Exception as exc:
                print(f"DIAG crt2 symbols: unavailable ({exc})")

            # (c) libmingw32 member listing
            try:
                search_roots = [
                    Path(zig_cc_exe).parent,
                    Path(zig_cc_exe).parent.parent / "lib",
                    Path(zig_cc_exe).parent.parent / "lib" / "zig",
                ]
                archive_path = None
                for root in search_roots:
                    try:
                        if not root.is_dir():
                            continue
                        hits = list(root.rglob("libmingw32.lib")) + list(root.rglob("libmingw32.a"))
                        if hits:
                            archive_path = hits[0]
                            break
                    except Exception:
                        continue
                if archive_path is None:
                    print("DIAG libmingw32: not located")
                else:
                    candidate_ar = zig_cc_exe.replace("-zig-cc", "-zig-ar")
                    if Path(candidate_ar).is_file() or shutil.which(candidate_ar):
                        ar_exe = candidate_ar
                    else:
                        ar_exe = shutil.which("llvm-ar")
                    if ar_exe is None:
                        print(f"DIAG libmingw32 members: archive found at {archive_path} "
                              f"but no archiver available")
                    else:
                        ar_result = subprocess.run([ar_exe, "t", str(archive_path)],
                                                    capture_output=True, text=True,
                                                    check=False, timeout=60)
                        members = [m for m in (ar_result.stdout or "").splitlines() if m.strip()]
                        has_crtexewin = any("crtexewin" in m for m in members)
                        has_crtexe = any("crtexe" in m and "crtexewin" not in m for m in members)
                        print(f"DIAG libmingw32 members: archive={archive_path} "
                              f"count={len(members)} crtexewin={has_crtexewin} crtexe={has_crtexe}")
            except Exception as exc:
                print(f"DIAG libmingw32 members: failed ({exc})")

            # (d) PE entry-point check: proves -Wl,-e SELECTS a named symbol (not
            # merely tolerated) by linking the same TU with two different entry
            # symbols and comparing the resulting AddressOfEntryPoint values.
            try:
                with_main_variant = next(v for v in VARIANTS if v[0] == "with_main")
                _wname, wextra, wsrc, _wstrict = with_main_variant
                c_file = tmpdir_path / "diag_entry.c"
                c_file.write_text(c_source_base + wsrc)

                exe_myentry = tmpdir_path / "diag_entry_myentry.exe"
                argv_myentry = ([zig_cc_exe, "-Wl,-eMyEntry"] + wextra +
                                [str(c_file), "-o", str(exe_myentry)])
                subprocess.run(argv_myentry, capture_output=True, text=True, check=False, timeout=60)

                exe_otherentry = tmpdir_path / "diag_entry_otherentry.exe"
                argv_otherentry = ([zig_cc_exe, "-Wl,-eOtherEntry"] + wextra +
                                   [str(c_file), "-o", str(exe_otherentry)])
                subprocess.run(argv_otherentry, capture_output=True, text=True, check=False, timeout=60)

                exe_otherentry_long = tmpdir_path / "diag_entry_otherentry_long.exe"
                argv_otherentry_long = ([zig_cc_exe, "-Wl,--entry,OtherEntry"] + wextra +
                                        [str(c_file), "-o", str(exe_otherentry_long)])
                subprocess.run(argv_otherentry_long, capture_output=True, text=True, check=False, timeout=60)

                rva_myentry = _pe_entry_rva(exe_myentry) if exe_myentry.is_file() else None
                rva_otherentry = _pe_entry_rva(exe_otherentry) if exe_otherentry.is_file() else None
                rva_otherentry_long = _pe_entry_rva(exe_otherentry_long) if exe_otherentry_long.is_file() else None

                print(f"DIAG entry RVA (-Wl,-eMyEntry):        "
                      f"{hex(rva_myentry) if rva_myentry is not None else 'unavailable'}")
                print(f"DIAG entry RVA (-Wl,-eOtherEntry):     "
                      f"{hex(rva_otherentry) if rva_otherentry is not None else 'unavailable'}")
                print(f"DIAG entry RVA (-Wl,--entry,OtherEntry): "
                      f"{hex(rva_otherentry_long) if rva_otherentry_long is not None else 'unavailable'}")

                if rva_myentry is not None and rva_otherentry is not None:
                    if rva_myentry != rva_otherentry:
                        print("DIAG entry flag SELECTS the named symbol (RVAs differ)")
                    else:
                        print("DIAG entry flag IGNORED (identical RVA for two different symbols)")
                else:
                    print("DIAG entry RVA: unavailable")

                if rva_otherentry_long is not None and rva_otherentry is not None:
                    if rva_otherentry_long == rva_otherentry:
                        print("DIAG long form and short form agree")
                    else:
                        print("DIAG SHORT FORM DROPPED: long form selects a different entry than -e")
                else:
                    print("DIAG long form RVA: unavailable")
            except Exception as exc:
                print(f"DIAG entry RVA: failed ({exc})")

            print("=== end diagnostics ===")
            print("")

    strictness = {v[0]: v[3] for v in VARIANTS}

    linked_both = [
        v[0] for v in VARIANTS
        if results.get(("concat", v[0]), ("", "", ""))[0] == "PASS"
        and results.get(("comma", v[0]), ("", "", ""))[0] == "PASS"
    ]
    strict_ok = [name for name in linked_both if strictness[name]]
    weak_ok = [name for name in linked_both if not strictness[name]]

    # Success-path matrix is DIAG-gated; on failure it always prints since it
    # is the primary evidence for the FAIL verdict below.
    if DIAG or not (strict_ok or weak_ok):
        print("")
        print("=== -Wl,-e translation fail-over matrix ===")
        print(f"wrapper: {zig_cc_exe}")
        for form_name, _flags in ENTRY_FORMS:
            for var_name, _e, _s, _st in VARIANTS:
                key = (form_name, var_name)
                if key not in results:
                    continue
                status, detail, _stderr_text = results[key]
                kind = "strict" if strictness[var_name] else "weak"
                print(f"  {form_name:7s} {var_name:22s} [{kind:6s}] {status:7s} {detail}")
        print("=== end matrix ===")
        sys.stdout.flush()
        print("")

    if strict_ok:
        print(f"PASS: [{zig_cc_exe}] -Wl,-eSYM and -Wl,-e,SYM honoured; "
              f"accepted on STRICT variant(s): {', '.join(strict_ok)}")
    elif weak_ok:
        print("WARNING: acceptance rests only on WEAK variant(s) below. WEAK variants")
        print("WARNING: keep the CRT startup, so they can link even when -Wl,-e was")
        print("WARNING: silently dropped (the CRT supplies a fallback entry regardless).")
        print(f"WARNING: WEAK variant(s) that linked for both entry forms: {', '.join(weak_ok)}")
        print("WARNING: see the 'DIAG entry flag' verdict above for whether -Wl,-e")
        print("WARNING: actually took effect.")
        print(f"PASS: [{zig_cc_exe}] accepted on WEAK variant(s) only: {', '.join(weak_ok)}")
    else:
        sys.stdout.flush()
        sys.exit("FAIL: no variant linked for both -Wl,-eSYM and -Wl,-e,SYM; "
                 "see matrix above")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
