# NOTES.md

Rationale relocated out of `recipe.yaml` comments during a 2026-09-13
readability pass. `recipe.yaml` keeps a short one-line pointer at each
original site, e.g. `# See recipe/NOTES.md 1.3.` -- cite subsections by
their `<group>.<number>` label, not by line number.

This file is tracked under `recipe/` and ships with the feedstock; it
carries the settled, per-patch and per-structure rationale a maintainer
needs to understand `recipe.yaml` and `recipe/PATCH_MANIFEST.yaml`.

## 1. Patch rationale

Per-patch WHY, ordering constraints, and drop-when conditions.

### 1.1 Patch order: macho-lld-support before prefer-shared-libcxx <a id="patch-order-macho-lld-support-before-prefer-shared-libcxx"></a>
All platforms: wires LLD MachO into the zig cc pipeline and allows
`-fuse-ld=lld`. `Lld.zig-macho-lld-support.patch` must apply before
`Lld.zig-prefer-shared-libcxx.patch` because the latter patches code inside
the `machoLink` function that the former adds.

### 1.2 Patch order: mingw setjmp-s before arm64-stubs <a id="patch-order-mingw-setjmp-s-before-arm64-stubs"></a>
mingw CRT patches: `_mingw.sh` warms all three windows-gnu triples on EVERY
lane regardless of the output's own target OS, so these patches must apply
unconditionally -- gating them to `not unix` / win-32 left the freshly built
zig blind to them everywhere else (undefined `__setjmp3`, `_fpreset`).
Order: `mingw-include-setjmp-s.patch` first (creates
`lib/libc/mingw/misc/setjmp.S` and wires it into `mingw32_x86_src`), then
`mingw-arm64-stubs.patch` (`fpreset_arm64.c` + `.aarch64` dispatch), which
assumes the +11 line shift ahead of the setjmp hunk.

### 1.3 Patch: target.zig-ppc64le-glibc-2.17-min <a id="patch-ppc64le-glibc-2-17-min"></a>
Lowers ppc64le `glibc_min` from 2.19 to 2.17: the abilists have full 2.17
data. Drop this patch when the conda-forge ppc64le glibc floor reaches 2.18
or higher.

### 1.4 Patch: Lld.zig-no-unconditional-as-needed-glibc-bundled <a id="patch-lld-no-unconditional-as-needed-glibc-bundled"></a>
Honours `-Wl,--no-as-needed` for bundled glibc libs (e.g. `-lm`). Without
this patch, zig drops `-lm` from `DT_NEEDED` even when the caller explicitly
requested `--no-as-needed`, breaking `dlsym(sin)` at runtime. Three-part
fix: `Config.zig` flag + `main.zig` recorder + `Lld.zig` bracket.

### 1.5 Patch: Sema.zig-shr-exact-safety-downgrade <a id="patch-sema-shr-exact-safety-downgrade"></a>
LLVM backend: downgrades `.shr_exact` to `.shr` when safety checks are on.
LLVM's InstCombine folds `shl(lshr_exact(x,N),N)` to `x`, making the
runtime back-shift comparison trivially true and silently dropping the
panic. Affects all LLVM-backend targets (ppc64le, aarch64, riscv64, ...).

### 1.6 Patch gating: ppc64le patches gated on `linux` <a id="patch-ppc64le-gating-on-linux"></a>
ppc64le patches are gated on `linux` (any linux variant) so the produced
linux-64 / linux-aarch64 / linux-riscv64 zig binaries can also
`zig cc -target powerpc64le-linux-gnu`.

### 1.7 Patch: LdScript.zig-arch-support (self-hosted ELF-linker arms removed) <a id="patch-ldscript-zig-arch-support"></a>
Architecture Support: only `LdScript` is required here, since its
`outputFormat()` runs on every backend. The 8 self-hosted ELF-linker arch
arms (relocation, Elf, Atom, LinkerDefined, ZigObject, synthetic_sections,
eh_frame, Thunk) were removed in build 9 after a linux-64 -> linux-ppc64le
build plus ppc64le tests confirmed they are dead code: the 0003
linker-redirect patch forces the LLD backend (-> gcc/ld) for powerpc64le
+elf, so the self-hosted final-link path is never instantiated.

### 1.8 Patch: gccmain-do-global-ctors-guard <a id="patch-gccmain-do-global-ctors-guard"></a>
win-64/arm64: bounds zig's mingw `__do_global_ctors` walk so a malformed
flexlink-merged `__CTOR_LIST__` (no -1 head / no NULL terminator) cannot run
off the end (`0xC00000FD STATUS_STACK_OVERFLOW` pre-main).

### 1.9 Patch: Lld.zig-prefer-shared-libcxx <a id="patch-lld-prefer-shared-libcxx"></a>
Unconditional across all platforms, by deliberate design (not staged-ahead
scaffolding for another workstream). Edits three files -- `src/link/Lld.zig`,
`src/link/MachO.zig`, and adds `src/link/libcxx_shared.zig` -- so zig prefers
a shared libc++ over its own bundled static `libc++.a` when one is
resolvable next to `zig_lib_dir`. On a miss the probe returns null and the
build falls back to the static bundled lib; there is no hard error, so
failure here is silent. On osx and windows, conda's LLVM/clang are built
against a shared libc++; without this patch zig would statically bundle its
own libc++ while still linking that shared-libc++ LLVM, risking the same
libc++ ABI-skew failure class seen elsewhere in this feedstock. `build.sh`'s
macOS libc++ injection guard depends on this patch's resolution behaviour
(it deliberately does NOT add `${PREFIX}/lib/libc++.dylib` to
`ZIG_LLVM_LIBRARIES` there, to avoid a duplicate `LC_LOAD_DYLIB`). The probe
is inactive when cross-compiling (guarded on `target.cpu.arch !=
builtin.cpu.arch`), so only NATIVE lanes exercise it; the osx native lane
builds in a `--test skip` configuration, so the probe's Darwin behaviour has
not been confirmed by a direct `otool -L` measurement.

### 1.10 Patch: ppc64le/build.zig-llvm-lld-config <a id="patch-ppc64le-build-zig-llvm-lld-config"></a>
Sets `exe.use_lld = false` for powerpc64le, selecting the non-LLD link
fallback. The patch's original comment justified this by claiming LLD does
not support PowerPC64 TOC relocations; source inspection of LLD's PPC64
backend refutes that specific claim -- TOC relocations are implemented
there. Measurement also showed `use_lld=false` alone does not itself route
the link through GCC: without the companion GCC-driver-redirect patches
(the former two 0003 patches, no longer present in this tree) it instead
falls through to zig's own self-hosted ELF linker, which panics with "TODO
unhandled cpu arch" on ppc64le. The real gap this patch works around was
later identified as a PLT-family relocation class LLD's PPC64 backend never
implements (`R_PPC64_PLT16_HA` / `PLT16_LO_DS` / `PLTSEQ` / `PLTCALL`),
triggered because conda-forge injects `-fno-plt` into CFLAGS/CXXFLAGS, which
makes GCC emit inline-PLT relocations of that class. A measured fix appends
`-fplt` (after conda's `-fno-plt`, so it wins) and flips `use_lld` back to
true; this linked cleanly under LLD in a local measurement but was not yet
validated in CI or re-checked against the PT_PHDR/`dl_iterate_phdr`
interaction (1.11) at time of writing. Drop-when: the `-fplt` fix is
validated end-to-end in CI and the PT_PHDR interaction is re-confirmed
against an LLD-linked ppc64le binary.

### 1.11 Patch: ppc64le/posix.zig-dl-iterate-phdr-no-pt-phdr <a id="patch-ppc64le-dl-iterate-phdr-no-pt-phdr"></a>
`lib/std/posix.zig`'s `dl_iterate_phdr`, static-executable branch, derives
the ELF load bias by scanning the binary's own program headers for a
`PT_PHDR` entry and asserts one exists (`unreachable` on a miss). GNU
`ld.bfd` does not emit a `PT_PHDR` program header for static, non-PIE
executables (LLD and gold do). Any process linked static+non-PIE via
`ld.bfd` that calls into a path touching `dl_iterate_phdr` hits that
`unreachable` -- observed as a panic with no captured frames, easily
mistaken for a hang if the panic-print path itself stalls. This only affects
ppc64le because its GCC-driver redirect (the former two 0003 patches, no
longer present in this tree) forces the external GCC/`ld.bfd` linker for
powerpc64le+elf; every other lane links with LLD, which always emits
`PT_PHDR`, so they never exercise this branch. Fix: change the
`unreachable` arm to return `0` -- for `ET_EXEC` non-PIE the load bias is
always 0, matching what the existing loop already computes for that case,
so PIE/dynamic/LLD-linked images are unaffected. Downstream dependency:
this patch exists only because `ld.bfd` is used at all; the GCC-driver
redirect unit it depended on has since been removed from this tree.

### 1.12 Non-patch: recipe/build.sh ppc64le flag block <a id="build-sh-ppc64le-flag-block"></a>
Three CFLAGS/CXXFLAGS/LDFLAGS additions -- `-fno-partial-inlining`,
`-fno-ipa-cp-clone`, and `-Wl,--stub-group-size=0` -- were introduced
alongside the ppc64le mlongcall and lld-bundle cmake patches (since removed
from this tree) as part of the same "defense in depth" `R_PPC64_REL24`
mitigation block. When those two cmake patches were
retired, these three flags were deliberately retained during the CI
measurement rather than removed at the same time, so the retirement result
says nothing about whether they are still needed -- it was obtained WITH
them present. Their only recorded rationale was the mitigation that has now
been retired, so they are currently unjustified: they need their own
targeted ablation on the ppc64le lane (watching for a `R_PPC64_REL24`
recurrence) before they can be either kept with a real justification or
dropped.

## 2. Recipe structure

Output layout, context-var semantics, build controls, and test-leg
purposes.

### 2.1 Context: target_triplet / zig_target_triplet mapping <a id="context-target-triplet-zig-target-triplet-mapping"></a>
`target_triplet` uses the same mapping as `build_triplet` but is keyed on
`target_platform` instead of `build_platform`; it feeds `xc_build_triplet`
for unhosted cross-compilers (which run ON `target_platform`).
`zig_target_triplet` uses the same mapping as `zig_build_triplet` (zig
`-target` format) but is likewise keyed on `target_platform`; it feeds
`xc_build_zig_triplet` for the same unhosted-cross-compiler case.

### 2.2 Context: ZIG_SYSROOT_MODE <a id="context-zig-sysroot-mode"></a>
`auto` = absolute GROUP paths for the riscv64 sysroot only. `legacy`/`abs`
force one form.

### 2.3 Requirements.build: bootstrap_native_rebuild deps <a id="requirements-build-bootstrap-native-rebuild-deps"></a>
`bootstrap_native_rebuild` links `clang_libs`/`lld_libs` directly
(static-llvm); `llvmdev` alone lacks them. The
`gcc_impl`/`binutils_impl(build_platform)` deps give a build-arch (not
cross) gcc for zig's C++ glue.

### 2.4 Tests: zig_impl -fuse-ld=lld pass-through <a id="tests-fuse-ld-lld-pass-through"></a>
Verifies the `-fuse-ld=lld` patch: zig cc must honour `-fuse-ld=lld` and
pass unrecognized linker args to LLD instead of rejecting them (Linux/ELF +
NonUnix/COFF, not macOS/Mach-O).

### 2.5 Tests: zig_impl -fuse-ld=lld NonUnix/COFF branch <a id="tests-fuse-ld-lld-nonunix-coff-branch"></a>
NonUnix: tests with COFF to verify `-fuse-ld=lld` compiles, links, and
runs. Running the binary also validates MSYS2 UCRT DLL resolution
(`api-ms-win-crt-*`).

### 2.6 Tests: zig_impl -fuse-ld=lld ppc64le branch <a id="tests-fuse-ld-lld-ppc64le-branch"></a>
ppc64le links via LLD (GCC-driver redirect, patch 0003, removed in build
9). This branch tests that link path; `-fuse-ld=lld` is intentionally not
used there.

### 2.7 Tests: test_mingw_crt.py coverage split <a id="tests-mingw-crt-coverage-split"></a>
`test_mingw_crt.py`'s deep content checks are win-64-only (`xc_w64`);
presence/size for all three mingw targets is asserted inside `_mingw.sh`
itself.

### 2.8 Requirements.run (zig_ output): pin_subpackage vs external zig_impl <a id="requirements-run-pin-subpackage-vs-external-zig-impl"></a>
For native/cross-target: depends on `zig_impl` for the same
`cross_target_platform_` (`pin_subpackage` works). For cross-compiler:
depends on `zig_impl` for the BUILD platform instead (an external package,
since `pin_subpackage` only reaches same-recipe outputs).

### 2.9 Tests (zig_ output): native-triplet compiler suite listing <a id="tests-native-triplet-compiler-suite-listing"></a>
Native-triplet compiler suite (cross-compiler builds only): the build
machine's own zig-cc/cxx/etc, mirroring the target suite above but keyed
on `xc_build_triplet` instead of `conda_triplet`.

### 2.10 Tests: test_nonunix_shim_target.py <a id="tests-nonunix-shim-target"></a>
Shim target selection is pure logic; the guarded `.c` sources must be
copied or `_compile_c_shim` is skipped and the count assertion misfires.

### 2.11 Tests: test_flag_translation_parity.py unix shim leg <a id="tests-flag-translation-parity-unix-shim-leg"></a>
The Leg (C) syntax-check covers the unix shim. Both `zig-cc-unix.c` and
`unix_common.h` are needed: the `.c` file `#include`s `unix_common.h`.
Without both, the leg SKIPs and the shim can silently rot uncompiled again.

### 2.12 Output packaging layout (zig_impl_ / zig_ / zig / zig-compiler) <a id="output-packaging-layout"></a>
Four-output split:
- `zig_impl_${{ cross_target_platform_ }}`: the actual zig compiler binary
  (triplet-prefixed) and standard library. No activation scripts, no
  wrappers -- just the implementation.
- `zig_${{ cross_target_platform_ }}`: activation scripts, depends on the
  matching `zig_impl_${{ cross_target_platform_ }}`. No binaries -- just
  environment setup.
- `zig` (metapackage): unprefixed symlinks, `zig -> $TRIPLET-zig`. Only
  built when `cross_target_platform_ == target_platform`.
- `zig-compiler` (toolchain metapackage): bundles `zig` with a C toolchain
  for a full development environment.
