# NOTES.md

Rationale relocated out of `recipe.yaml` comments during a 2026-09-29
readability pass. `recipe.yaml` keeps a short one-line pointer at each
original site, e.g. `# See recipe/NOTES.md 1.3.` -- cite subsections by
their `<group>.<number>` label, not by line number.

This file is tracked under `recipe/` and ships with the feedstock; it
carries the settled, per-patch and per-structure rationale a maintainer
needs to understand `recipe.yaml`. It is specific to the **0.17.0** track
(zig 0.17.0 release) -- do not assume parity with the 0.16 feedstock's
own `NOTES.md`, even where a patch name matches.

A pointer documents only the entry immediately following it, not every
entry down to the next pointer. An entry with no pointer of its own has
no subsection here, and that absence is deliberate -- it marks a patch
whose rationale is not written down, matching the rows
`recipe/PATCH_MANIFEST.yaml` scores UNRECORDED.

## 1. Patch rationale

Per-patch WHY, ordering constraints, and drop-when conditions.

### 1.1 Patch order: macho-lld-support before prefer-shared-libcxx <a id="patch-order-macho-lld-support-before-prefer-shared-libcxx"></a>
All platforms: wires LLD MachO into the zig cc pipeline and allows
`-fuse-ld=lld`. `Lld.zig-macho-lld-support.patch` must apply before
`Lld.zig-prefer-shared-libcxx.patch` because the latter patches code inside
the `machoLink` function the former adds.

0.17.0 release: `prefer-shared-libcxx` no longer edits `MachO.zig`; a hook
in `src/libs/libcxx.zig` `buildLibCxx` does `.load_dso` of
`findSharedLibCxxPath` on macho, and the zig-llvm/lib probe is gone.
`macho-lld-support` was regenerated (hunk move only).

### 1.2 Compile-time deps on macho-lld-support <a id="compile-time-deps-on-macho-lld-support"></a>
`llvm.zig-lld-ofmt-macho.patch` uses the `.macho` arm of `switch (lld.ofmt)`,
added by `Lld.zig-macho-lld-support.patch`; it applies cleanly at zero fuzz
but will not compile without that provider. `main.zig-fuse-ld-lld-cc-path.patch`
calls `llvm.LinkMachO(...)`, whose binding is likewise added by
`Lld.zig-macho-lld-support.patch` via `bindings.zig`. Both are compile-time
symbol edges, not apply-time hunk conflicts, so `patch --dry-run` cannot
detect a missing provider -- `recipe.yaml` keeps `macho-lld-support` first
in the patch list for exactly this reason. NOTE: `main.zig-fuse-ld-lld-cc-path.patch`
is a misnomer -- it contains no gcc/cc-path resolution logic, only the
`ld64.lld` dispatch registration and linker-arg forwarding.

### 1.3 Patch order: mingw setjmp-s before arm64-stubs <a id="patch-order-mingw-setjmp-s-before-arm64-stubs"></a>
`mingw.zig-01-include-setjmp-s.patch` and `mingw.zig-02-arm64-stubs.patch`
are unconditional (not gated to any one Windows target): `_mingw.sh` warms
all three windows-gnu triples on every build regardless of the recipe's own
target platform, so gating either patch to a single target left the
freshly built zig blind to it on the other two. Both patches insert entries
into the same `src/libs/mingw.zig` region, so the "-01 before -02"
constraint is an apply-time hunk-offset dependency (dry-run-detectable),
not a compile-time symbol edge -- neither patch references anything the
other introduces. The `-01`/`-02` filename ids encode this order directly.
`mingw-setjmp-no-crtimp.patch` (unconditional) sits between them in the
patch list -- it strips `_CRTIMP` from the bootstrap header's
`_setjmp`/`_setjmp3` declarations so `generate_mingw_import_libs()` does not
emit dllimport thunks for symbols `setjmp.S` already defines locally; its
own position is not order-sensitive against either `-01` or `-02`.

### 1.4 Patch: posix.zig-dl-iterate-phdr-no-pt-phdr (unconditional) <a id="patch-dl-iterate-phdr-no-pt-phdr"></a>
`PT_PHDR` is absent from static, non-PIE ELF images produced by GNU ld
(LLD and gold always emit one); `dl_iterate_phdr`'s single-image fallback
in `lib/std/posix.zig` previously hit `unreachable` on such an image. This
patch changes that arm to return `0`, a provable no-op on any image that
does carry a `PT_PHDR` (all PIE/dynamic images, and everything LLD links),
since the load bias there is already `0`. Unlike the 0.16 track, where the
equivalent patch is gated to ppc64le only (the one lane there whose final
link went through GNU ld/`ld.bfd`), this patch is **unconditional** on
0.17: it is a general ELF-correctness fix, and gating it to one platform
would leave the same panic reachable on any other lane that ever links a
static non-PIE binary through GNU ld. The wider scope costs nothing on
lanes that never hit the code path and closes the defect class everywhere
at once instead of one architecture at a time.

### 1.5 Patch: target.zig-glibc-needs-libunwind <a id="patch-glibc-needs-libunwind"></a>
Forces libunwind for all glibc targets. Drop when the conda-forge linux
glibc floor reaches a version that no longer forces libunwind.

### 1.6 Patch: target.zig-ppc64le-glibc-2.17-min <a id="patch-ppc64le-glibc-2-17-min"></a>
Lowers ppc64le `glibc_min` from 2.19 to 2.17: the abilists have full 2.17
data. Drop this patch when the conda-forge ppc64le glibc floor reaches 2.18
or higher.

### 1.7 Patch: Lld.zig-no-unconditional-as-needed-glibc-bundled <a id="patch-lld-no-unconditional-as-needed-glibc-bundled"></a>
Honours `-Wl,--no-as-needed` for bundled glibc libs (e.g. `-lm`). Without
this patch, zig drops `-lm` from `DT_NEEDED` even when the caller
explicitly requested `--no-as-needed`, breaking `dlsym(sin)` at runtime.

### 1.8 Patch: Sema.zig-shr-exact-safety-downgrade <a id="patch-sema-shr-exact-safety-downgrade"></a>
LLVM backend: downgrades `.shr_exact` to `.shr` when safety checks are on.
LLVM's InstCombine folds `shl(lshr_exact(x,N),N)` to `x`, making the
runtime back-shift comparison trivially true and silently dropping the
panic. Affects all LLVM-backend targets (ppc64le, aarch64, riscv64, ...),
not only ppc64le.

### 1.9 Patch: linux/build.zig-01-maxrss-raise <a id="patch-build-zig-maxrss-raise"></a>
Raises the linux common-group `max_rss` ceiling toward a 16GB budget:
ppc64le Stage 1 peaks at 11.41GB, close enough to a tighter ceiling to risk
a false OOM abort under CI's resource accounting.

### 1.10 Patch gating: ppc64le patches gated on `linux` <a id="patch-ppc64le-gating-on-linux"></a>
The two ppc64le patches are gated on `linux` (any linux variant), not on
`ppc64le` alone, so the produced linux-64 / linux-aarch64 / linux-riscv64
zig binaries can also `zig cc -target powerpc64le-linux-gnu` as
cross-compilers.

### 1.11 Patch: ppc64le/0001-arch-support-LdScript.zig + 0002-build-config-build.zig <a id="patch-ppc64le-0001-0002"></a>
`0001` keeps only the `LdScript.zig` hunk (`elf64-powerpcle` format
recognition): its `outputFormat()` runs on every backend. The 8
self-hosted ELF-linker arch arms that used to ship alongside it
(relocation table, ELF TLS/thunk switch, stub reloc-scan, EH reloc, and
others) were removed as dead code -- ppc64le's final ELF link goes through
LLD (via the wrapper's `-fuse-ld=lld` auto-injection plus a `-fplt`
CFLAGS/CXXFLAGS lever), not through zig's self-hosted linker, so those arms
were never instantiated. `0002` forces `exe.use_llvm=true` and
`exe.root_module.link_libc=true`; it does **not** touch `use_lld` or
redirect the link to a system GCC/`ld.bfd` -- an earlier recipe.yaml
comment claimed otherwise and has been corrected. ppc64le carries no
GCC/`ld.bfd` linker-redirect patch at all on this track: the former pair of
such patches was removed from both `recipe.yaml` and disk once
LLD-linking ppc64le directly was confirmed working.

### 1.12 Patch chain: mingw atexit removal / restoration / consumption <a id="patch-mingw-atexit-chain"></a>
Three patches form a removal-then-restoration chain, not a simple
apply-order pair. `mingw-crtexe-no-atexit.patch` removes the only
`atexit()` definition in `crtexe.c`. `ucrtbase-export-atexit-alias.patch`
restores it as an `atexit == _crt_atexit` alias in
`api-ms-win-crt-runtime-l1-1-0.def.in` (`ucrtbase.dll` only exports
`_crt_atexit` under that name). `gccmain-do-global-ctors-guard.patch` is a
silent third consumer -- its own file calls `atexit(__do_global_dtors)`
without mentioning either of the other two patches. Dropping the
restoration while keeping the removal breaks the windows-gnu link with an
undefined `atexit`, and the error surfaces inside `gccmain.c`, two patches
away from the actual cause -- never drop one of the three without the
other two. `gccmain-do-global-ctors-guard.patch` itself bounds zig's mingw
`__do_global_ctors` walk so a malformed, flexlink-merged `__CTOR_LIST__`
(no `-1` head / no NULL terminator) cannot run off the end
(`0xC00000FD STATUS_STACK_OVERFLOW` pre-main); zig ships no PE
crtbegin/crtend bookends, so this can occur whenever a binary composing
`__CTOR_LIST__` from multiple objects omits one of those markers.

## 2. Recipe structure

Output layout, context-var semantics, and test-leg purposes.

### 2.1 Context: build number / build string / zig_impl_pin <a id="context-snapshot-build-number-zig-impl-pin"></a>
Release scheme: the source is the zig 0.17.0 release tarball,
`build_number` is 0 (increment per rebuild), and the build string is
`${{ hash }}_${{ build_number }}` -- no snapshot segment. The former
`snapshot`/`snapshot_ref`/`build_ref` context keys are gone, and
`channel_targets` is removed (uploads go to conda-forge main, not zig_dev).
Bootstrap self-hosts against the last published dev `zig_impl`:
`bootstrap_snapshot_ref` ("2320") and `bootstrap_build_ref` ("23202") build
`zig_impl_pin`:
`[version="${{ abi_version }}.*", build="*_${{ bootstrap_snapshot_ref }}_*", build_number=">=${{ bootstrap_build_ref }}"]`.
The `build=` glob keys on the snapshot field of the dev build string; the
`>=` floor on `build_number` rejects lower revs and fails the solve loudly
when nothing qualifies. It resolves only because `variants.yaml`
`channel_sources` lists `conda-forge/label/zig_dev` first; that source is
for the first release build only. Once 0.17.0 is on main, drop it and make
the pin `abi_version.*` from main.

### 2.2 Context: target_triplet / zig_target_triplet mapping <a id="context-target-triplet-zig-target-triplet-mapping"></a>
`target_triplet` uses the same mapping as `build_triplet` but is keyed on
`target_platform` instead of `build_platform`; it feeds `xc_build_triplet`
for unhosted cross-compilers (which run ON `target_platform`).
`zig_target_triplet` mirrors `zig_build_triplet` (zig `-target` format) the
same way, keyed on `target_platform`, feeding `xc_build_zig_triplet` for
the same unhosted-cross-compiler case.

### 2.3 Output packaging layout (zig_impl_ / zig_ / zig / zig-compiler) <a id="output-packaging-layout"></a>
Four-output split:
- `zig_impl_${{ xtarget_ }}`: the actual zig compiler binary
  (triplet-prefixed) and standard library. No activation scripts, no
  wrappers -- just the implementation.
- `zig_${{ xtarget_ }}`: the activation/wrapper layer, depending on the
  matching `zig_impl_${{ xtarget_ }}`. No compiler binary of its own for
  native/cross-target builds.
- `zig` (metapackage): unprefixed symlink, `zig -> $TRIPLET-zig`. Built
  only when `xtarget_ == target_platform`.
- `zig-compiler` (toolchain metapackage): bundles `zig` with a C toolchain
  for a full development environment.

### 2.4 Tests: zig_impl -fuse-ld=lld pass-through <a id="tests-fuse-ld-lld-pass-through"></a>
Verifies the `-fuse-ld=lld` patch: zig cc must honour `-fuse-ld=lld` and
pass unrecognized linker args to LLD instead of rejecting them (Linux/ELF +
NonUnix/COFF; macOS/Mach-O is a separate branch of the same test block).

### 2.5 Tests: test_mingw_crt.py coverage split <a id="tests-mingw-crt-coverage-split"></a>
`test_mingw_crt.py`'s deep content checks are win-64-only (`xc_w64`);
presence/size for all three mingw targets (x86_64/aarch64/x86-windows-gnu)
is asserted inside `_mingw.sh` itself, at generation time, on every lane
that runs it.

### 2.6 Requirements.run (zig_ output): pin_subpackage vs external zig_impl <a id="requirements-run-pin-subpackage-vs-external-zig-impl"></a>
For native/cross-target: depends on `zig_impl` for the same `xtarget_`
(`pin_subpackage` works, since it is the same recipe's output). For
cross-compiler: depends on `zig_impl` for the BUILD platform instead -- an
external package, since `pin_subpackage` only reaches same-recipe outputs
and the cross-compiler's own `zig_impl` is a different `xtarget_`'s build.
The `zig_` cross package runs on `zig_impl_<xc_build_platform> ${{ abi_version }}.*`.

### 2.7 Tests (zig_ output): native-triplet compiler suite listing <a id="tests-native-triplet-compiler-suite-listing"></a>
Cross-compiler builds only: alongside the target-triplet wrapper suite,
this block also lists the build machine's own zig-cc/cxx/etc, mirroring
the target suite but keyed on `xc_build_triplet` instead of
`conda_triplet`.

### 2.8 Tests: foreign import library link probe <a id="tests-foreign-import-lib-link-probe"></a>
Verifies the `<triplet>-zig-cc` wrapper can link a foreign (MSVC-built)
prebuilt import library (zstd). Deliberately native-keyed
(`is_native and (xc_w64 or xc_warm64)`): a win-64 test environment can only
install win-64 zstd, so a cross lane cannot exercise this probe against its
own target's zstd.

### 2.9 Tests: test_nonunix_shim_target.py <a id="tests-nonunix-shim-target"></a>
Shim target selection is pure logic; the guarded `.c` sources must be
copied into the test's `files:` list or `_compile_c_shim` is skipped
entirely and the count assertion misfires (passes vacuously instead of
exercising anything).

### 2.10 Tests: test_flag_translation_parity.py unix shim leg <a id="tests-flag-translation-parity-unix-shim-leg"></a>
The Leg (C) syntax-check covers the unix shim. Both `zig-cc-unix.c` and
`unix_common.h` are needed in the test's `files:` list -- the `.c` file
`#include`s `unix_common.h`. Without both, the leg SKIPs and the shim can
silently rot uncompiled again.
