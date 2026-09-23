# Recipe improvements ledger (zig 0.17 track)

Generated 2026-09-14 from workflow wf_ea95c57a-438, anchored at snapshot 2127+e90365cd5. This file is the STATE of the improvement work and must be updated in the SAME commit as each change. Improvements ride the CURRENT nightly snapshot-bump branch by policy (amended 2026-09-14): separate improvement PRs get no review and cost more than they return, so the nightly snapshot PR doubles as the merge vehicle and work leap-frogs forward on each night's branch. WARNING: the bot cuts each nightly snapshot PR from `dev`, not from the previous snapshot branch -- a snapshot PR that does not merge before the next is cut strands its accumulated improvements and needs a manual merge (precedent: #186 cut from dev at 6c00f159 ~70 min before #185 merged, hence merge commit 8f80f319).

**Note.** Batches 1 and 2 (items 1, 2, 3, 8, and 6) both landed on `snapshot/dev-2127+e90365cd5` (PR #186) under the amended rule above.

## Status table

| ID | Title | Effort | Risk | Status | Validated by |
|----|-------|--------|------|--------|---------------|
| 1 | config.h mutation assert instead of silent no-op | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 2 | Split EXTRA_ZIG_ARGS along maker/configurer boundary | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 3 | Stop mingw layer degrading silently | S-M | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 4 | Use ZIG_LIB_DIR instead of argv[0]/lib-copy workaround (SPECULATIVE) | S-M | med | IN PROGRESS | PR #189 board, 24/24 green @ d8b08e8d |
| 5 | Build-time upstream-assumption ledger | S-M | low | TODO | - |
| 6 | Encode patch order in filenames, not comments | M | low-med | DONE (scope narrowed) | PR #186 board, 24/24 green @ 335fdf83 |
| 7 | Adopt -Doptimize=safe | S | low | DONE (2026-09-18) | - |
| 8 | Retire shipped debug instrumentation | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 9 | Replace hand-rolled import libs with upstream's (SPECULATIVE) | L | high | TODO | - |
| 10 | Machine-check patch apply-order via Applies-after headers | M | low | DONE (scope narrowed, 2026-09-18) | - |
| 11 | Stop parsing `zig env` output as JSON (upstream emits ZON) | S | low | DONE (adc8b717) | - |
| 12 | Split collapsed libc++.a skip into four arms + named compile timeout | S | low | DONE (adc8b717) | - |
| 13 | Emulated-lane coverage gap in libcxx simulation test | S | med | DONE (adc8b717) | - |
| 14 | Tool-probe checks evaporate when the tool is absent | S | low | DONE (adc8b717) | - |
| 15 | No byte-size floor on generated mingw artifacts | S | low | DONE (adc8b717; floor tightened 2026-09-18) | - |
| 16 | Harness cannot express expected-but-absent coverage | M | low | TODO | - |
| 17 | Four disagreeing predicates for "is this lane emulated" | M | med | DONE (2026-09-16) | - |
| 18 | Langref debug scaffolding and 0.17 full-langref remeasure | M | low | DEFERRED | - |
| 19 | Redundant QEMU env exports | S | low | DONE (2026-09-17, 451c9cb8) | - |
| 20 | build.zig-03-msvc-crt-dynamic carries 0.16.0 provenance | S | low | DONE (2026-09-18) | - |
| 21 | posix.zig-dl-iterate-phdr-no-pt-phdr applies at max fuzz | S | low | DONE (2026-09-18) | - |

## Batches

- **Batch 0 (infrastructure)**: restructure `recipe/SNAPSHOT_TRIAGE.md` into invariant-procedure vs anchor-table, create this ledger, create the thin triage skill. Touches no recipe logic. - DONE 2026-09-14
- **Batch 1 (silent-degradation sweep)**: items 1, 2, 3 and optionally 8. One theme, all small, one CI board validates all of them. - DONE 2026-09-14
- **Batch 2**: item 6 (patch order in filenames). Scope narrowed to two-file rename (mingw.zig-01/-02); validated by PR #186 board 24/24 green @ 335fdf83. - DONE 2026-09-14
- **Batch 3**: spikes for items 4 and 7 - investigate and decide, not implementation.
- **Batch 4 (cross-track adoption from 0.16)**: items 11, 12 adopted from the 0.16 track's measurements; item 13 raised by the same comparison. Uncommitted. - 2026-09-14
- **Batch 5 (second cross-track round from 0.16)**: item 14 adopted from the 0.16 track's `strings` finding and extended (we have two sites, not one); item 15 is a gap the comparison exposed in our tree. Uncommitted. - 2026-09-14
- **Deferred**: item 9 (large, high risk, speculative).

## Proposals

### 1. Make `config.h` mutation assert instead of silently no-op

**Problem.** `_cfg_subst` (`recipe/building/_common.sh:75-86`) runs `re.sub` per line and never checks the match count; `_cfg_subst_lit` (`:88-114`) does `str.replace` with no check. Six load-bearing call sites depend on it: `recipe/build.sh:223` (zstd/xml2/z), `:227`/`:228` (BUILD_PREFIX->PREFIX for cross), `:242`, `:262`, `:264` (stub `.o` injection). If upstream reshapes `#define ZIG_LLVM_LIBRARIES "a;b;c"` (split lines, quoting change, rename), every one of these becomes a no-op and the build proceeds to fail ~40 min later as undefined symbols at the stage-3 link, or worse links against `${BUILD_PREFIX}` LLVM on a cross lane.

**Change.** Zero-match is a WARNING, not a failure -- `_cfg_subst`/`_cfg_subst_lit` log and continue on 0 substitutions. `_cfg_require` was implemented, then deleted. Safety instead comes from POST-CONDITION assertions run after the mutation block: every appended token present in `ZIG_LLVM_LIBRARIES`, no `ZIG_`/`LLVM_` define still referencing `BUILD_PREFIX` on cross lanes, and each injected stub path present.

**Effort.** S. **Risk.** low.

**Measured 2026-09-14 (PR #186 board 24/24 green @ 6baeee89).** The originally specified design (non-zero return on zero matches, `_cfg_require` wrapper, promoted `dbg grep`) shipped on board 1 and was reverted after four defects found in batch-1 hardening:
- The Windows build shell has no grep. Promoting a dbg-wrapped grep to an always-run path exits 127 (killed win-64 and win-arm64). Always-run paths use bash builtins only.
- Match count is the wrong failure criterion. Opportunistic rewrites legitimately match zero lines (osx-64: cmake already resolved LLVM under PREFIX). Assert outcomes, not match counts.
- set -e kills a helper before it can read $?. `cmd` then `rc=$?` is unsafe; capture inline with `|| rc=$?`. Symptom is a lane dying with NO error text at all.
- ZIG_CXX_COMPILER legitimately lives in BUILD_PREFIX (it is a host tool), so a BUILD_PREFIX-leak check must be an allowlist of link/load defines, not a scan of every ZIG_/LLVM_ define.

**Validation.** Any linux lane; failure signatures `ERROR: ZIG_LLVM_LIBRARIES_MISSING_TOKEN`, `ERROR: config.h still references BUILD_PREFIX:`, `ERROR: config.h stub injection missing:`; non-fatal `WARNING: config.h substitution matched nothing:`.

Status: DONE - validated by PR #186 board 24/24 green @ 6baeee89 (2026-09-14)
Blocked by: nothing

---

### 2. Split `EXTRA_ZIG_ARGS` along the maker/configurer boundary

**Problem.** `recipe/build.sh:78-88` mixes maker-only CLI flags (`--search-prefix`) with package `-D` options in one array, then appends more of both at `:95`, `:118`, `:135`, `:142`/`:154`, `:188-189`, `:194`. It is splatted as one blob at `recipe/building/_build.sh:20-23`. Upstream now has two processes with two parsers: the maker forwards only a subset to the configurer (`lib/compiler/Maker.zig:272-321`), and both fatal on unknown args (`Maker.zig:553`, `configurer.zig:124-126`). The recipe has no place to express which side a flag belongs to, and no way to honour a positional requirement such as `--zig-lib=` having to come first (`Maker.zig:336-337`).

**Change.** Two arrays -- `ZIG_MAKER_ARGS` (non-`-D`, order-significant, first) and `ZIG_PKG_OPTS` (`-D*`) -- concatenated at the single splat site. Every `+=` site picks a side explicitly. Log both separately.

**Effort.** S. **Risk.** low (pure re-grouping; argv order for `-D` is irrelevant).

**Validation.** Every lane; expect a byte-identical effective command line.

Status: DONE - validated by PR #186 board 24/24 green @ 6baeee89 (2026-09-14)
Blocked by: nothing

---

### 3. Stop the mingw layer degrading silently

**Problem.** Three CRT objects are compiled only `if [[ -f ... ]]`: `recipe/building/_mingw.sh:444` (`crtexe.c`), `:450` (`crtexewin.c`), `:456` (`crtdll.c`). Upstream is actively deleting vendored C from `lib/libc/mingw` (zig libc rewrite). A deletion produces a green build with no `crt2.o`, and the failure surfaces in a downstream consumer as an unresolved `mainCRTStartup`. Separately, `_mingw.sh:423-437` is a hand-maintained copy of upstream `addCcArgs`+`addCrtCcArgs` whose only drift detector is an `#error` from a header, and the import-lib floor `_gen_count_floor=2200` (`:326`) catches removals but not additions or arch-skew.

**Change.** (a) Convert the three `-f` guards into hard errors, listing the expected filenames. (b) Add a startup assertion block that names every upstream path/file the layer depends on (`crt/`, `lib-common/`, `libsrc/`, `def-include/`, `any-windows-any/setjmp.h`) and fails with one message if any is missing. (c) Derive the import-lib floor from the actual `.def`/`.def.in` count in the extracted source times the arch count, instead of the hardcoded 2200.

**Effort.** S-M. **Risk.** low.

**Measured 2026-09-14 (PR #186 board 24/24 green @ 6baeee89).** win-64 native ran green: actual import-lib count 2355, derived expectation 2418 (806 def files x 3 arches), hard floor 2200. Confirms the derived value is an overestimate (per-arch .def sets differ), so making it the hard floor would have failed a good build -- which is why it warns only.

**Validation.** win-64 native lane (the only one that sources `_mingw.sh` for generation); signature `ERROR: [_mingw] upstream contract broken: lib/libc/mingw/crt/crtexe.c missing`.

Status: DONE - validated by PR #186 board 24/24 green @ 6baeee89 (2026-09-14)
Blocked by: nothing

---

### 4. Use `ZIG_LIB_DIR` instead of the argv[0]/lib-copy workaround (SPECULATIVE)

**Problem.** Stage 1 ships a bash wrapper plus a copied stdlib tree because "zig 0.17 locates its stdlib by walking up from argv[0]" -- `recipe/building/build_native.sh:205-212` (wrapper) and `:236-249` (`cp -r "${STAGE1_DIR}/lib" "${TARGET_DIR}/lib"`). `ZIG_LIB_DIR_ARGS=()` at `:94`/`:105` is dead residue of the removed CLI form, still splatted at `:170`. Upstream at e90365cd5 reads `EnvVar.ZIG_LIB_DIR` in `src/main.zig:1027`, `:428`, `:462` and -- critically -- `:5010` (`jitCmdInner`, the path `zig build` takes), then forwards it as the prepended `--zig-lib=` that `Maker.zig:172` requires.

**Change.** Export `ZIG_LIB_DIR` around the stage-1/two-stage invocations; delete the dead `ZIG_LIB_DIR_ARGS` array, its splat and the three stale comment/echo residues (`:96`, `:266`, `:279`); keep the lib copy only until one green ppc64le two-stage run proves the env var suffices.

**Effort.** S-M. **Risk.** med.

**SPECULATIVE in one respect:** the env-var path is verified to exist upstream, but that it fully replaces the copied tree for the wrapped `.real` binary is UNVERIFIED here.

**Validation.** linux-ppc64le cross (two-stage bootstrap, `build.sh:282-292`); failure signature is `unable to find zig installation directory`.

Status: IN PROGRESS - export landed and CI-verified (15f8265f; PR #189 board 24/24 green @ d8b08e8d); this change now deletes the copy to test whether the env var alone suffices.
Blocked by: nothing - the prior blocker (a green ppc64le run after the export, in a separate commit) is satisfied. A green board with the copy still present does NOT prove the env var suffices on its own, which is why the copy is being removed now.

---

### 5. A build-time upstream-assumption ledger

**Problem.** Our upstream dependencies are asserted nowhere and discovered only by failure: the `config.h` define shape, the CRT flag set, the assumption that `zig env` emits JSON (`recipe/testing/test_libcxx_shared.py:141-146` parsed it for `global_cache_dir`; `ci_support/probe_mingw_setjmp.sh:91` parses it for `lib_dir`) -- CORRECTED: upstream's `print_env.zig` uses `std.zon.Serializer` and emits ZON (`.{ .global_cache_dir = "..." }`), there is no JSON path and no `--json` flag, so the assumption was never "has key X", it was the false belief the output is JSON at all. The `test_libcxx_shared.py` half is now FIXED (see item 11); the `probe_mingw_setjmp.sh` half is still broken but is untracked local-only tooling. Remaining unasserted: the six-key libc-file format (`recipe/building/_cross.sh:33-40`), and the `_CRTIMP` regex, now at `_mingw.sh:538-608` (STALE ANCHOR, see MEASURED block below -- was `:489-490` before item 3 grew the file; same line-marker rot item 10's Problem block warns against). The `gen_translators.py --check` guard already wired into the recipe is the right precedent.

**Change.** One `building/_assert_upstream.sh`, sourced once early, that checks each assumption against the extracted source and the bootstrap binary and fails with a named assumption id. Mirror the list into `ZIG_RECIPE_LLM_REFERENCE.md` so the doc and the check share one inventory.

**Effort.** S-M (was M). **Risk.** low.

**Validation.** Runs on all lanes; signature `ASSUMPTION FAILED: A07 zig env lacks key 'lib_dir'` before any compilation.

**MEASURED 2026-09-18 (scope narrowed).**

1. STALE ANCHOR. The Problem text's `_CRTIMP` citation at `_mingw.sh:489-490` had drifted -- the file grew when item 3 landed. The real logic is `_mingw.sh:538-608`. Re-anchored above; this is the exact line-marker rot item 10's Problem block already argues against.

2. ALREADY ASSERTED -- scope removed. The `_CRTIMP` assumption needs no new work. `_mingw.sh:544` probes for grep/sed; `:551-586` is a byte-for-byte pure-bash re-implementation of the same match for lanes without them; `:592-605` re-checks after the strip and is FATAL (`return 1`) if it did not take. That is already the shape this item asks for. Remaining work there is cosmetic only: give the two INFO/FATAL sites a named assumption id (`A_CRTIMP_SHAPE`) so failures are greppable. Its one real weakness: if upstream reshapes the declaration (multi-line decl, different callconv keyword, param attributes) BOTH the strip and the re-check miss it the same way, so a still-broken header passes silently -- a false negative, not a false alarm.
   Valid lanes: win-64 / win-arm64 native only (the lanes with mingw CRT and a bootstrap setjmp.h).

3. THE ONE REAL GAP: `A_LIBC_KEYS`. `_cross.sh:33-40` hand-emits a six-key libc file (`include_dir`, `sys_include_dir`, `crt_dir`, `msvc_lib_dir`, `kernel32_lib_dir`, `gcc_dir`; the msvc and kernel32 keys are always blank for linux targets). Nothing in this repo reads zig's `LibCInstallation.zig`, so the key set is asserted only against memory of upstream's parser. `recipe/SNAPSHOT_TRIAGE.md:37` names `LibCInstallation.zig` in a prose contract list, but nothing programmatically diffs against it.
   Builtins-only: NO -- needs a scan of the extracted source. It can degrade to the same bash while-read pattern used at `_mingw.sh:551-586`, but this path is linux-cross-only (`build.sh:183`, `:295-314`) and never runs on osx/win, so the no-grep constraint is close to moot here.

   MEASURED 2026-09-18 against pristine 2131. The six keys MATCH upstream exactly, names and declaration order: `include_dir`, `sys_include_dir`, `crt_dir`, `msvc_lib_dir`, `kernel32_lib_dir`, `gcc_dir` (`LibCInstallation.zig:20-25` vs `_cross.sh:34-39`). No omissions, no extras -- the assumption is CORRECT as of 2131, there is no live defect here. Order does NOT matter to the parser: it matches per-line by name, and the missing-field check is by field index, not file position (`LibCInstallation.zig:69-80`, `:82-87`). `parse` derives expected keys dynamically from `@typeInfo(LibCInstallation).@"struct".field_names` (`LibCInstallation.zig:46`), not a hardcoded list. FAILURE MODE, and this is the important part: an UNKNOWN key is SILENTLY IGNORED, but a MISSING key is a FATAL `error.ParseError` with a "missing field" log (`LibCInstallation.zig:82-87`). Post-parse null checks are os/abi-gated (`:88-121`): `include_dir`/`sys_include_dir` always required; `crt_dir` required unless darwin; `msvc_lib_dir`/`kernel32_lib_dir` only for windows with msvc/itanium abi; `gcc_dir` only for haiku/serenity. The recipe's linux-only heredoc leaving the msvc/kernel32 pair empty is therefore correct. CONSEQUENCE for this item's premise: an upstream field rename or addition already fails LOUDLY and by name at build time. This does NOT degrade silently, so it does not belong to the silent-degradation family that items 1, 3, 14 and 16 share. An assertion would only move an already-named error earlier, which makes `A_LIBC_KEYS` the WEAKEST remaining candidate in this item, not the strongest. If it is ever implemented, it must NOT hardcode the six names -- that check would rot exactly the way this ledger's own file:line anchors did. It must scan the struct's field-name list and diff against the heredoc.

4. SOURCING HAZARD (most likely thing to break an implementation). Only the `zig_impl_${{xtarget_}}` output extracts upstream source and runs build.sh (`recipe.yaml:294-321` under the top-level `source:` at `:174`). The `zig_${{xtarget_}}` wrapper output (`recipe.yaml:599-604`) has NO `source:` block and never sees SRC_DIR. An assertion that reads upstream source files is meaningless there, and fatal for no reason if written as a hard fail. Recommended sourcing point is `recipe/build.sh` right after `building/_common.sh`, lane-gated the way `_cross.sh` already is -- never unconditionally at the top before `is_linux`/`is_cross` are known.

5. RULED OUT: do not assert the `config.h` `ZIG_LLVM_LIBRARIES` regex SHAPE (`build.sh:257`). Item 1's post-condition token-present checks already cover the same failure signature; a second pre-condition assert is redundant.

Status: TODO (narrowed twice) - A_CRTIMP_SHAPE already implemented and cosmetic; A_LIBC_KEYS measured correct at 2131 with a loud failure mode, so low value
Blocked by: nothing - both halves are now measured; what remains is a judgement call on whether A_LIBC_KEYS earns its keep.

---

### 6. Encode patch order in filenames, not comments

**Problem (measured 2026-09-14).** The original claim -- five patches stacking on `src/link/Lld.zig`, three stacking inside `build.zig` within ~25 lines -- conflated apply-time hunk edges with implementation-order comments; most same-file stacks already conformed or had no real edge. Measured findings:
- Only ONE stack was both non-conformant and carried a real apply-time edge: `mingw-include-setjmp-s.patch` and `mingw-arm64-stubs.patch` both modify `src/libs/mingw.zig` at the identical hunk range 122,17. Renamed to `mingw.zig-01-include-setjmp-s.patch` and `mingw.zig-02-arm64-stubs.patch`.
- The other two same-selector-group same-file stacks already conformed: `linux/link.zig-01/02/03` (whose -01 vs -03 hunks genuinely overlap at `src/link.zig` 1226-1229) and `non_unix/build.zig-01/02/03`.
- Two recipe.yaml ordering comments assert order the hunks do not require. `recipe.yaml:179-180` claims `macho-lld-support` must precede `prefer-shared-libcxx`, but their `src/link/Lld.zig` hunks are at 3-300 and 725+ respectively and do not overlap -- the dependency is a symbol edge, not an apply edge. The atexit trio (`mingw-crtexe-no-atexit`, `ucrtbase-export-atexit-alias`, `gccmain-do-global-ctors-guard`) touches three different files and has no apply edge at all.
- Filename encoding structurally cannot express edges that cross selector groups, because `if: linux` and `if: not unix` are mutually exclusive.

**Convention audit.** Convention is `<file>(-<id if needed>)-<reason>.patch`. An audit found 12 of 33 filenames off-convention in four modes: component-name instead of upstream file (7 mingw/ucrtbase/selfinfo patches); wrong file token (`linux/llvm.zig-triple-no-glibc-version` actually targets `lib/std/zig/llvm/Builder.zig` while a real `src/codegen/llvm.zig` is patched by `llvm.zig-lld-ofmt-macho`); id with no series plus cross-directory collision (unconditional `build.zig-02/-03` vs `non_unix build.zig-02/-03`); and inverted `<id>-<reason>-<file>` (`ppc64le/0001`, `0002`, which target different files so the ids assert a series that does not exist). Left unfixed by maintainer scope decision.

**Change.** Renamed the one non-conformant stack with a real apply edge (mingw.zig). No other renames performed.

**Effort.** M (rename + recipe.yaml + doc). **Risk.** low-med (pure rename; risk is a missed reference).

**Validation.** Every lane's patch phase must show no `Hunk ... FAILED`.

Status: DONE (scope narrowed on measurement) - validated by PR #186 board 24/24 green @ 335fdf83 (2026-09-14)
Blocked by: nothing

---

### 7. Adopt `-Doptimize=safe`

**Problem.** `-Doptimize=ReleaseSafe` at `recipe/build.sh:88` and `recipe/building/build_native.sh:173`, `:271` used the PascalCase tag.

**Change.** Switch all three to `-Doptimize=safe`.

**Effort.** S. **Risk.** low.

**Validation.** One linux-64 native build; failure is immediate (`expected -Doptimize to be of type ...`).

**MEASURED (snapshot 2033+af24fd11a, extracted at `build_artifacts/src_cache/542637f163ff4067_extracted`).** `std.lang.Optimize` enum fields are lowercase `debug`/`safe`/`fast`/`small` (`lang.zig:115-133`); PascalCase `Debug`/`ReleaseSafe`/`ReleaseFast`/`ReleaseSmall` exist only as deprecated `pub const` aliases carrying "Deprecated, to be removed after 0.18.0". `Build.option` special-cases `T == std.lang.Optimize` and routes through `Optimize.fromString` (`Build.zig:1048-1058`). `fromString` accepts all eight spellings via a `StaticStringMap` (`lang.zig:135-146`), so both forms work at this snapshot -- but `fromString` itself carries the same deprecation marker (`lang.zig:134-135`). Switching does not dodge a deprecated function today; the point is that when `fromString` is removed and plain `stringToEnum` takes over, only the lowercase field names survive.

**RESIDUAL.** Verification was done against extracted snapshot 2033+af24fd11a, while the branch pins 2131+d08989840; the 2131 source was not extracted locally. Residual risk is bounded because a rejected tag fails immediately and loudly at configure time, so the next board is the verification.

Status: DONE (2026-09-18) - measured at snapshot 2033; next board validates at 2131
Blocked by: nothing

---

### 8. Retire shipped debug instrumentation

**Problem.** `recipe/patches/ppc64le/0001-arch-support-LdScript.zig.patch` adds an unconditional `std.debug.print("zig-feedstock-debug: ...")` on the error path of `LdScript.outputFormat` -- it ships in the released compiler and fires for any unrecognised `OUTPUT_FORMAT` in a user's linker script.

**Change.** Split diagnostics out of functional patches; drop this hunk.

**Effort.** S. **Risk.** low.

**Validation.** linux-ppc64le; the `elf64-powerpcle` arm must still be present.

Status: DONE - validated by PR #186 board 24/24 green @ 6baeee89 (2026-09-14)
Blocked by: nothing

---

### 9. Replace hand-rolled import libs with upstream's (SPECULATIVE)

**Problem.** `_mingw.sh` reimplements `.def` preprocessing and import-lib generation with `zig cc -E -P` plus `llvm-dlltool` (`:241-245`, `:170`), while upstream now does this in-process (`src/libs/mingw.zig` -> `mingw/def.zig`, `mingw/implib.zig`, `mingw/Preprocessor.zig`, including `fixupForImportLibraryGeneration`). Two implementations of `.def` semantics must agree; divergence shows up only downstream.

**Change.** not recorded (no concrete change was specified in the source; this proposal is scoped as a spike/investigation, not an implementation).

Whether the compiler can be driven to materialize these into the install tree is **UNKNOWN** -- this is a spike, not a task.

**Effort.** L. **Risk.** high.

**Validation.** not recorded.

Status: TODO
Blocked by: that investigation; do not schedule alongside a snapshot bump.

---

### 10. Machine-check patch apply-order via Applies-after headers

**Problem.** Four claimed apply-time edges were expressible only in prose or ad-hoc patch headers, and three of them were claimed to cross selector groups where filenames cannot help:
- `src/link/Lld.zig`: `prefer-shared-libcxx` (1210-1222) vs `linux/Lld.zig-no-unconditional-as-needed` (1224-1241), 2-line gap, crosses groups
- `build.zig` on windows: `non_unix/build.zig-03-msvc-crt-dynamic` (886-901) vs `non_unix/build.zig-01-maxrss` (900-906), overlap, currently undocumented anywhere
- `lib/libc/mingw/lib-common/api-ms-win-crt-runtime-l1-1-0.def.in`: `mingw.zig-02-arm64-stubs` vs `ucrtbase-export-atexit-alias`, same file, crosses groups, undocumented
- `src/link.zig`: `link.zig-01` vs `link.zig-03` overlap at 1226-1229 (currently carried only by the filename ids)

The `Applies-after:` header convention already exists in `recipe/patches/linux/Lld.zig-no-unconditional-as-needed-glibc-bundled.patch`, which carries `Applies-after: Lld.zig-macho-lld-support.patch, Lld.zig-prefer-shared-libcxx.patch`.

**MEASURED 2026-09-17 (verifying the actual `@@` headers of all four).** 3 of the 4 claimed edges did NOT survive verification:
- Edge Lld.zig (`Lld.zig-prefer-shared-libcxx` vs `linux/Lld.zig-no-unconditional-as-needed-glibc-bundled`): RECLASSIFIED. Adjacency, NOT overlap. A's hunk ends at new-line 1222 (`@@-1206,7+1210,13@@`), B's begins at old-line 1224 (`@@-1224,6+1224,7@@`). Exactly ONE untouched context line (1223) separates them -- the ledger's "2-line gap" was wrong on the gap size but right that a real ordering constraint exists via offset shift. It is ALREADY encoded by B's existing `Applies-after:` header at that file's line 16.
- Edge build.zig (`non_unix/build.zig-01-maxrss` vs `non_unix/build.zig-03-msvc-crt-dynamic`): REFUTED as specified. The original claim compared build.zig-03's NEW numbering (886-901) against build.zig-01's OLD numbering (900-906), which is not a same-basis comparison. On a common old-file basis build.zig-03 spans 886-891 (`@@-886,6+886,16@@`) and build.zig-01 spans 900-906 (`@@-900,7+900,7@@`): an 8-line gap, disjoint.
- Edge api-ms-win-crt-runtime def.in (`mingw.zig-02-arm64-stubs` vs `ucrtbase-export-atexit-alias`): same file CONFIRMED, overlap REFUTED. Ranges are old 44-50 (`@@-44,7+44,9@@`) and old 37-42 (`@@-37,6+37,7@@`), disjoint, one untouched line (43) between.
- Edge link.zig (`linux/link.zig-01` vs `linux/link.zig-03`): REFUTED. link.zig-01 leaves the `new_path = Path.initCwd(...)` block as unmodified CONTEXT inside `@@-1183,7+1238,16@@`; link.zig-03 REMOVES that same pristine text at `@@-1226,11+1226,18@@`. One passes it through, the other edits it -- not a dual-edit collision. The claimed range 1226-1229 matches neither patch's declared ranges.

Also measured while verifying this item: `recipe/patches/non_unix/build.zig-03-msvc-crt-dynamic.patch` carried non-ASCII bytes (a right-arrow and an ellipsis glyph) inside its hunk body -- fixed in this same change.

**CHANGE (narrowed).** The `Applies-after:` header convention is KEPT and remains correct where it is already used. The universal-header sweep and the recipe.yaml-order checker are NOT built: one real ordering constraint exists in the whole tree (the Lld.zig adjacency) and it already documents itself via the existing header, so a parser plus a CI gate would cost more than it returns.

**General lesson.** Hunk ranges from two patches are only comparable on a COMMON basis (old-file line numbers, or new-file line numbers -- pick one and use it for both). Comparing one patch's post-apply numbering against another's pre-apply numbering manufactures edges that are not there. That error produced 2 of the 4 original claims (build.zig and link.zig).

**Effort.** M. **Risk.** low.

**Validation.** not recorded.

Status: DONE (scope narrowed on measurement, 2026-09-18) - checker NOT built; 3 of 4 edges refuted
Blocked by: nothing

---

### 11. Stop parsing `zig env` output as JSON (upstream emits ZON)

**Problem.** `_find_zig_cache_dir` called `zig env` and did `json.loads(r.stdout)`, reading `global_cache_dir`; the except clause swallowed the JSONDecodeError and returned None. Upstream emits ZON via std.zon.Serializer, so this NEVER worked - the cache dir was always unresolved and the libc++.a lookup fell through to a dead rglob over the installed tree, which ships libcxx as source only. Root cause measured on the 0.16 track and confirmed identical here.

**Change.** Drop the `zig env` subprocess entirely; read the ZIG_GLOBAL_CACHE_DIR environment variable, which `setup_zig_global_cache_dir()` (_test_utils.py:59-77, already called at test_libcxx_shared.py:65) guarantees is set. `import json` removed as the sole consumer.

**Effort.** S. **Risk.** low.

**Validation.** Any lane reaching test_libcxx_shared_simulation; the skip must no longer report an unresolved cache dir.

Status: DONE (adc8b717) - adopted from 0.16 track
Blocked by: nothing

---

### 12. Split collapsed libc++.a skip into four arms + named compile timeout

**Problem.** `_find_libcxx_static` returned a bare Path|None and its single caller emitted one collapsed SKIP string, "could not find libc++.a in zig cache or lib dir". On the 0.16 track that string was PROVEN FALSE in a measured case - the archive existed and a different arm had failed. The cache-warming `zig c++ -shared` compile also used a hardcoded timeout=120 with no named constant.

**Change.** `_find_libcxx_static` returns (path, reason) with four distinct arms - compile timed out / compile returned non-zero / zig cache dir unresolved / no libc++.a archive found. Added `_COMPILE_TIMEOUT_S` = 1800 on emulated lanes, 120 native. Arm wording matches the 0.16 track so the trees converge.

**Effort.** S. **Risk.** low.

**Validation.** The SKIP line must name one specific arm, never the collapsed string.

Status: DONE (adc8b717) - adopted from 0.16 track
Blocked by: nothing

---

### 13. Emulated-lane coverage gap in the libcxx simulation test

**Problem.** `test_libcxx_fallback_static` and `test_libcxx_shared_simulation` were both gated to SKIP on `is_arm64 or is_ppc64le or _is_emulated`, so on this track the emulated lanes never exercised the compile, and the raised `_COMPILE_TIMEOUT_S` from item 12 was inert. The 0.16 track's gate on both its callers (:207-209 and :683-685) is `_is_emulated and not is_ppc64le`, with no `is_arm64` term. On 0.16, riscv64 is emulated and therefore SKIPS under that same gate; ppc64le is the ONLY emulated lane that reaches the compile, which is why its ~937s measurement came from ppc64le alone, not two lanes. The earlier "two emulated lanes" cost estimate in this item was an overestimate.

**Change.** Adopted the 0.16 carve-out at both sites: `is_arm64 or is_ppc64le or _is_emulated` -> `is_arm64 or (_is_emulated and not is_ppc64le)`. We keep our `is_arm64` disjunct deliberately - the 0.16 track has no evidence on it and we are not dropping it for parity. This opens exactly ONE lane, linux-ppc64le; riscv64 still skips (emulated and not ppc64le), aarch64 and osx-arm64 still skip via `is_arm64`, and linux-64/osx-64/win-64 are unchanged. 0.16's `_COMPILE_TIMEOUT_S = 900` is unconditional (its :94) and its own raise is proposed-not-applied, so 900 is what produced its ~937s timeout arm. Ours is already 1800 on emulated lanes (item 12). Opening ppc64le here with 1800 is therefore a live experiment the 0.16 track cannot run: if the timed-out arm stops firing under our 1800s ceiling, that confirms 900 was the whole story on 0.16.

**Effort.** S. **Risk.** med (adds wall-clock to one emulated lane).

**Validation.** linux-ppc64le wall-clock delta and pass/timeout outcome on the next board; expected observation is recorded above.

Status: DONE (adc8b717) - needs a board; expected cost is added wall-clock on linux-ppc64le only
2026-09-16: maintainer decision - emulated carve-out removed, riscv64 runs linking tests too (gate now `is_arm64` only); prior board 35158476859 showed riscv64 0p/3s under the carve-out, and under the old inert gate 3p/1w/3s with 120s timeout.
Blocked by: nothing

---

### 14. Tool-probe checks evaporate when the tool is absent
Problem: two `shutil.which(...)` probes in test_libcxx_shared.py had no else-branch - `nm` at :291-302 and `strings` at :364-375. With the tool absent, neither PASS nor FAIL nor SKIP was recorded and the check vanished from the report entirely. Raised by the 0.16 track, which found the `strings` instance in its own tree; we have TWO sites, not one. This is the silent-degradation theme in the one form the item-1 assertion work cannot catch, because nothing fails and nothing is skipped.
Change: both probes now record a SKIP naming the missing tool.
Effort S, Risk low.
Validation: any lane lacking nm or strings must now show a SKIP line instead of silence.
Status: DONE (adc8b717) - raised by 0.16 track, extended here
Blocked by: nothing

---

### 15. No byte-size floor on generated mingw artifacts
Problem: `_mingw.sh` (730 lines) asserts a COUNT floor on generated import libs (`_gen_count_floor=2200` at :355, checked :371-372) but has NO byte-size assertion on any generated artifact - only `[[ -s ... ]]` non-empty tests at :190 and :278. A truncated-but-non-empty artifact passes both. The 0.16 track carries a real byte-size floor at its `_mingw.sh:680` that we lack; conversely it lacks our count floor. The two assertions are independent and neither subsumes the other.
Change: artifact is `libmingw32.lib`, harvested per target triple inside the cache-warm loop. Floor 1000000 bytes as first landed, measured with `wc -c` (raised to 9500000 on 2026-09-17; see Status below). Adapted NOT copied: our warm loop already had `_warm_failed_count`/`_warm_failed_list` (declared :632-633) with a post-loop FATAL at :722, so the existing counter was reused rather than adding a parallel one. Inserted at :691-699, inside `generate_mingw_import_libs` (function spans :8-743), after the `_warm_lib` existence check at :679-680. Deliberate deviation from the 0.16 shape: the measured size is logged UNCONDITIONALLY, pass or fail. The 1000000 figure was a round number roughly 10x below the 0.16 track's observed 10.8-11.4MB archives, chosen before we had measured our own (SUPERSEDED 2026-09-17 - our figures are in the Status block below). Logging every size puts our real numbers on the next board so the floor can be tightened on evidence. Reference doc section 5 updated in the same change.
Effort S, Risk low.
Validation: FOUR native hosts generate - win-64, win-arm64, osx-64, osx-arm64. The earlier "only win-64" claim is wrong: board 451c9cb8 shows win-arm64 native generating too (import libs generated=2355 failed=0, with its own per-triple size logs), and reference doc 5.6's own-track table records osx-64 and osx-arm64 figures. osx runs ~0.62-0.70MB larger than win on every arch, so win-64 remains the smallest class.
Status: DONE (adc8b717; floor tightened 2026-09-18) - measured, floor raised 1000000 -> 9500000
Measured on board 451c9cb8. win-64 native (job 105298416144): x86_64 10651828, aarch64 11073080, x86 11122370. win-arm64 native (job 105298415972): 10664684 / 11084548 / 11135226 - about 12KB larger on every arch, so win-64 is the smaller class and sets the floor. Earlier win-64 board (job 104231430783): 10651820 / 11073124 / 11122370, i.e. under 50 bytes of cross-board drift. Floor 9500000 is anchored on the win-64 CLASS, not on any exact byte count (see reference doc 5.6: an exact minimum is falsified by the next board). The ~11% margin is orders of magnitude outside the measured build-to-build jitter of tens of bytes. Both lanes: import libs generated=2355 failed=0.
Blocked by: nothing

---

### 16. Harness cannot express expected-but-absent coverage
Problem: raised by the 0.16 track and it generalises item 14. Our harness test files end `return 1 if n_fail > 0 else 0`; SKIP and WARN never affect the exit code. So at the exit-code level a check that EVAPORATED, a check legitimately SKIPPED, and "nothing to test on this lane" are indistinguishable. Item 14 converted two evaporating probes into SKIPs, which is honest but still invisible to anything automated - the board cannot tell you coverage went missing. This is the general form of the whole batch-1 silent-degradation theme.
MEASURED on the PR #189 green board (commit 15f8265f), all 22 build lanes, total registered checks (pass+warn+skip) per tallying file:
- test_flag_translation_parity.py: 2 distinct totals -- 29 on all 4 osx lanes (generated-C leg runs), 16 on all 18 win and linux lanes (that leg SKIPs). Clean partition on build-host mac vs not.
- test_zig_toolchain.py: 10 distinct pass/warn/skip profiles collapsing to 9 distinct totals, range 41..68 (totals discriminate even less than the profiles: linux_64 native and linux_aarch64 native at 46/0/6 and osx_arm64 native at 45/0/7 both total 52). Keys on BUILD-HOST arch, not target. win-64 native 67 vs win-arm64 native 68 total; osx-arm64 native 52 vs its own cross lanes 49. No clean OS/emulated partition, and a count floor cannot even tell the linux natives apart from the osx-arm64 native.
- test_libcxx_shared.py: runs in only 8 of 22 lanes (the cross lanes drop the zig_impl output that carries the test), 5 distinct totals among those 8.
A per-file integer floor is only sound where the totals partition, and more fundamentally the totals are corrupted by the bug the floor is meant to catch -- coverage varies by lane BECAUSE inapplicable checks vanish without recording a SKIP. Flooring that number floors a corrupted quantity.
Change: _test_utils.py gained registered_check_count() and enforce_coverage_floor(floor, label, provenance), which reports through FAIL so the existing `n_fail > 0` reduction reddens the board. Floors are EXACT measured counts with no margin, unlike the soft margin at recipe/building/_mingw.sh:355, because losing one check must fail. Adopted in test_flag_translation_parity.py only (29 mac / 16 non-mac), the one file whose totals partition cleanly.
Effort M, Risk low.
Validation: deliberately delete a probe locally; the board must go red, not merely quieter. Satisfied for test_flag_translation_parity.py only.
Status: PARTIAL - mechanism landed, one of three tallying files adopted. Residual split out as item 22.
Blocked by: nothing

---

### 17. Four disagreeing predicates for "is this lane emulated"
Problem: `_test_utils.py:115-119` defines `_is_emulated` as `sys.platform == "linux" and _native_machine not in ("x86_64","i686") and os.environ.get("CI","") != ""`. That is HOST ARCH, not emulation: it is TRUE on the linux-aarch64 NATIVE lane, where nothing is emulated. The recipe already knows the truth three ways - `NEEDS_EMULATION` (recipe.yaml:622, `linux and build_platform != target_platform`), the `qemu_pkg` gate (recipe.yaml:149, byte-identical condition), and QEMU_EXECVE being non-empty only when the shim is installed, which happens only under that same condition. The harness derived it from `platform.machine()` instead of reading any of them.
MEASURED - THIS IS NOT A CLEANUP. Enumerated every consumer; flipping the flag to correct on linux-aarch64 native changes NINE of them:
- `test_zig_toolchain.py` :234, :255, :321, :358, :470, :510 (`if _is_emulated or _is_cross_compiler:`) and :570 (`if _is_emulated:`) - SEVEN tests that currently SKIP on aarch64 native would start RUNNING there. That is a coverage increase and possibly desirable, but it is a behaviour change on a currently-green lane and can turn it red. (REFUTED 2026-09-16, see Status)
- `test_libcxx_shared.py:82` `_COMPILE_TIMEOUT_S` 1800 -> 120 on that lane (harmless there, it is native, but it changes).
- `test_libcxx_shared.py:775` diagnostic print flips.
The three libcxx gates at :204/:334/:659 are NOT affected - `is_arm64` already skips that lane.
ALSO MEASURED: `NEEDS_EMULATION` is NOT available at test time - it lives in a build `script: env:` block (recipe.yaml:611-624) and is read only by `install_zig_activation.py:245`; zero hits under recipe/testing/. QEMU_EXECVE IS exported in test blocks (recipe.yaml:510, :554, :854, :896 under `if: is_testable`). So the 0.16 track's QEMU_EXECVE-presence test is not merely an acceptable proxy, it is the ONLY correct signal currently visible to the test harness without a recipe change.

MEASURED (session addition, 2026-09-14): four independent semantic encodings of "emulated/cross" coexist in this tree, and two of them DISAGREE:
1. `build_platform != target_platform` - recipe.yaml:149 (qemu_pkg gate), recipe.yaml:622 (NEEDS_EMULATION), _common.sh:14 (`is_cross()`)
2. `is_cross && is_linux` - build.sh:191, :410 (wrapper over form 1)
3. `is_foreign_target(triplet)` - _test_utils.py:144, compares triplet arch against platform.machine()
4. `_is_emulated` - _test_utils.py:115, host-arch plus a CI env check

THE DISAGREEMENT, and note the POLARITY:
- SHELL, build.sh:184: `[ -n "${QEMU_EXECVE:-}" ] && [ -x "${QEMU_EXECVE}" ]` - non-empty AND executable, NO basename check. Accepts any executable at that path.
- PYTHON, _test_utils.py:186: `qemu_execve and os.path.basename(qemu_execve) == f"qemu-execve-{arch}" and os.access(qemu_execve, os.X_OK)` - requires the basename to match EXACTLY.
So our PYTHON is the stricter side and our SHELL is the looser one. A launcher at e.g. /usr/bin/custom-qemu would be accepted by build.sh and rejected by emulation_prefix.

WHY THE POLARITY MATTERS: the 0.16 track has the identical class of defect but INVERTED - its shell does the basename match (`case "$(basename ...)" in qemu-execve-*`) and its Python tests bare presence, so ITS shell is stricter. Same bug, opposite direction. Consequence: the two tracks need OPPOSITE fixes and neither should copy the other's patch. Here the shell should adopt the basename check its own Python already performs; there the Python should adopt the shell's.

THIRD PREDICATE INSIDE ONE FILE: _test_utils.py alone holds both the strict basename form at :186 and the host-arch `_is_emulated` at :115. The disagreement is not only cross-language, it is intra-file.

GENERALISED RULE, REFINED 2026-09-14 (the 0.16 track raised the crude form and then retracted it; do not reinstate it). The crude form was "never let two consumers hold disagreeing predicates for one fact". That is wrong: two consumers CAN legitimately hold different predicates when they are answering DIFFERENT QUESTIONS. The measured example - on the 0.16 track, its shell asks "is this the passthrough-capable shim" (prefix glob, declines to arm on a vanilla name) while its Python asks "is this a usable emulator for this arch" (substring, tolerates the vanilla name). Both are correct for their own question.
THE ACTUAL DEFECT is difference that nobody has DISTINGUISHED: a reader cannot tell intentional divergence from drift, because the question each predicate answers is nowhere stated. THE CURE IS NAMING THE QUESTION, not forcing one predicate. Where two predicates genuinely answer one question, unify; where they answer two, say so at both sites.

LOAD-BEARING SUBSTRING (0.16 track, measured): its build.sh falls back to a VANILLA `qemu-<arch>` binary - no `execve-` infix - and re-exports it as QEMU_EXECVE, because the qemu-execve-<arch> package ships BOTH names. Its substring matcher accepts that; an exact-equality matcher like ours at _test_utils.py:186 would reject it. So "adopt the strict matcher" was the wrong instruction and is withdrawn. RESOLVED 2026-09-14, ANSWER IS NO - our exact matcher is CORRECT for our tree. Measured: every assignment of QEMU_EXECVE in this tree uses `command -v qemu-execve-${qemu_arch}` and nothing else (recipe.yaml:432, :457, :482, :510, :554, :716, :854, :896); build.sh never assigns QEMU_EXECVE at all. There is no vanilla-name fallback here. The one bare-name lookup, build.sh:198 `command -v qemu-${ZIG_QEMU_ARCH}`, is a READ-ONLY check gating the `-fqemu` flag and feeds nothing back.
  THE TWO TREES RESOLVE IN OPPOSITE DIRECTIONS, which is why the matchers must differ. 0.16: vanilla `qemu-<arch>` is discovered and re-exported INTO QEMU_EXECVE, so its matcher must tolerate the vanilla basename. Ours: QEMU_EXECVE is always the strict `qemu-execve-<arch>`, and build.sh:186-188 symlinks FROM it to create a bare `qemu-<arch>` name in a shadow PATH dir for `zig -fqemu`. Their flow is vanilla -> QEMU_EXECVE; ours is QEMU_EXECVE -> vanilla. Exact equality is right here and substring is right there.
  CAVEAT: this covers values our own code produces. A QEMU_EXECVE pre-set in the inherited environment is not excluded, which is the same unresolved residual as the PATH-probe item.
  CONSEQUENCE: neither matcher may be ported to the other tree. This is the fourth measured case this session where the correct answer was that the tracks must diverge (after the maker/configurer arg split, the predicate polarity, and launcher naming).

Change: either export NEEDS_EMULATION into the test env and read it, or adopt the QEMU_EXECVE-presence definition. Rename the flag either way. Do NOT bundle with anything else - it needs its own board precisely because it opens seven tests on aarch64 native.
Effort M, Risk med.
Validation: linux-aarch64 native, watching those seven test_zig_toolchain checks go from SKIP to a real result; and the shell (build.sh:184) and Python (_test_utils.py:186) QEMU_EXECVE predicates must be compared and reconciled, not just the aarch64 test count observed.
Status: DONE (2026-09-16). REFUTED 2026-09-16 (board 35142723040@9366b74a vs 35158476859@9816320f): old `_is_emulated` was FALSE on every CI lane (its `CI` env clause is unset inside rattler-build test envs), not TRUE on aarch64 native as predicted above - aarch64 native's SKIP set is unchanged, emulated=False on both boards. The fix's real effect is False->True on the ppc64le and riscv64 emulated lanes only. ppc64le test_libcxx_shared gains coverage (3p/0f/1w/3s -> 8p/0f/1w/2s, timeout-SKIP gone); riscv64 skip removed, see #13. test_zig_toolchain results unchanged on all three lanes.
Blocked by: nothing, but must be its own commit and its own board.

### 18. Langref debug scaffolding and 0.17 full-langref remeasure
Status: DEFERRED (2026-09-17) - after the current fast-iteration round
0.16 build 18 measured full ppc64le langref: 4762s, 298/298 steps, run 35172156518, so the historical 6h-window overrun did not reproduce there. 0.17 has no equivalent measurement yet.
Port source: local branch scaffold/v0.16-langref @ da618e1d (supersedes the two scaffold/v0.16-* tags): critical subset + extended probe + heartbeat + _zig_diag.sh + _riscv64_diag.sh, all gated off; see recipe/building/SCAFFOLD.md on that branch. View with git diff c28e8b0e da618e1d -- recipe. Gate on `xtarget_ == target_platform and (ppc64le or riscv64)`, knobs as recipe.yaml defaults.
Porting fixes needed: heartbeat stop must be `kill || true; wait || true` (build.sh:3 is unconditional `set -euo pipefail`); re-add `ZIG_LANGREF_PROBE_SKIP_LIST` (space-safe names).
Blocked by: nothing, deferred by priority after the fast-iteration round.

---

### 19. Redundant QEMU env exports
Status: DONE (2026-09-17, 451c9cb8) - verify on next board
Facts (qemu-execve 11.0.3 build 12): activation always exports `QEMU_EXECVE=${CONDA_PREFIX}/bin/qemu-execve-<arch>`; activation never sets `QEMU_EXECVE_NATIVE_PASSTHROUGH`, and the C code defaults passthrough ON unless the value is exactly `"0"`.
Change: removed 8 `export QEMU_EXECVE="${QEMU_EXECVE:-$(command -v qemu-execve-...)}"` and 11 `QEMU_EXECVE_NATIVE_PASSTHROUGH` sites (8 `export ...=1` in recipe.yaml plus 3 `env ...=1` prefixes in build.sh/_langref.sh). Pin -> `version="==11.0.3", build_number=">=12"` (converges with 0.16 track).
Validation: emulated lanes still print `QEMU_EXECVE=... exists=yes` in diag, resolve `qemu-execve` 11.0.3 build >=12, and `test/langref-critical` counts unchanged.

---

### 20. build.zig-03-msvc-crt-dynamic carries 0.16.0 provenance

**Problem.** Measured while verifying item 10. `non_unix/build.zig-03-msvc-crt-dynamic.patch` declares in its header that it was verified against zig 0.16.0 (2026-05-13), while its sibling `non_unix/build.zig-01-maxrss.patch` declares 0.17.0 snapshot 2015+3fdcbc03d (2026-09-06). Additionally the anchor line `exe.stack_size = stack_size;` appears as trailing context in BOTH patches at incompatible old-file offsets (build.zig-03 near 887, build.zig-01 near 906), which cannot both be right against one base file. This does NOT prove drift -- the patch may simply carry a stale provenance header -- but it is unresolved and the patch is in the `if: not unix` group, so it is load-bearing for every win lane.

**Resolution path.** Run `recipe/ci_support/check_patch_relevancy.sh win-64` and review this patch's FAIL/DRIFT/OFFSET verdict; refresh the provenance header, or regenerate the patch, according to what it reports.

**MEASURED 2026-09-18.** `check_patch_relevancy.sh win-64` against snapshot 2131+d08989840 (23 effective patches, CLEAN 9/23) reports this patch as `OFFSET(19)` -- it applies, no FAIL, no DRIFT, no fuzz. OFFSET(19) is mid-range for this tree (`main.zig-fuse-ld-lld-cc-path` OFFSET(63), `non_unix/Lld.zig-suppress-importeddllmain` OFFSET(43) in the same run). The "incompatible anchor offsets" worry above is the same common-basis error refuted for item 10 (comparing one patch's new-file numbering against another's old-file numbering) -- not evidence of drift. Provenance header refreshed to name the current snapshot.

**Effort.** S. **Risk.** low (was med).

Status: DONE (2026-09-18) - NOT drifted; OFFSET(19), header text was stale only
Blocked by: nothing

---

### 21. posix.zig-dl-iterate-phdr-no-pt-phdr applies at max fuzz

**Problem.** Measured 2026-09-18 by `check_patch_relevancy.sh win-64` against snapshot 2131+d08989840. `patches/posix.zig-dl-iterate-phdr-no-pt-phdr.patch` reports `HIGHFUZZ(offset=0 fuzz=3 - regen recommended)`. It was the ONLY non-CLEAN, non-OFFSET verdict in the run; every other patch was CLEAN or a plain OFFSET.

**Why it matters.** HIGHFUZZ means BOTH `git apply --check` and plain `patch --dry-run` (GNU default fuzz=2) REJECT the hunk, while `patch --fuzz=10` accepts it; the reported `fuzz=3` is just the level the probe actually needed on a scale that goes up to 10, not a ceiling. Per the script's own header, rattler-build's patch application is measurably more tolerant than GNU patch's default fuzz (verified against real CI logs), and the HIGHFUZZ tier exists precisely to avoid false FAILs on patches that build fine in practice. So this is a real upstream-churn signal in that region and a legitimate regen candidate -- which is what the script recommends -- but it is NOT evidence the build is about to break. The patch is in the UNCONDITIONAL selector group, so the region is load-bearing on every lane; that is a reason to regen it deliberately, not a reason to treat it as urgent.

**Resolution path.** Regenerate the patch against a pristine pinned 2131 source, then re-run the audit and require CLEAN or a plain OFFSET. Do it as its own change so a board attributes any breakage to it.

**ROOT CAUSE (measured 2026-09-18, regenerated against pristine 2131).** A single context-line drift, not a functional problem. Upstream renamed `std.elf.AT_EXECFN` to `std.elf.AT.EXECFN`; that identifier appears ONLY as a trailing CONTEXT line in the patch, never on a changed line. The edit itself still landed at identical line numbers (offset=0) while the context failed to match -- that is the whole HIGHFUZZ(fuzz=3) verdict. This CONFIRMS the corrected reading already recorded for this item: it was matching on degraded context, it was not close to failing. The regenerated patch keeps the same functional hunk (`} else unreachable,` -> `} else 0,`) at `@@ -818,7 +818,7 @@`, now with the upstream-current context line and a function-context `@@` header. The patch's own header note was extended too: the changed expression and its line numbers are unchanged across snapshots, but the surrounding context is not -- that distinction is what the old note elided.

**Effort.** S. **Risk.** low.

Status: DONE (2026-09-18) - regenerated against pristine 2131; audit re-run CONFIRMS CLEAN (was HIGHFUZZ fuzz=3), CLEAN count 9/23 -> 10/23, no other patch verdict changed
Blocked by: nothing

---

### 22. Lane-conditional absence is implicit, so coverage counts are not lane-invariant
Problem: the true generalisation of item 14 and the residual of item 16. Checks that do not apply to a lane simply do not execute; they record nothing. So per-file check totals differ by lane for two indistinguishable reasons -- legitimate inapplicability and real evaporation. Measured spread on PR #189 / 15f8265f: test_zig_toolchain.py 41..68 across 22 lanes, 10 distinct pass/warn/skip profiles collapsing to 9 distinct totals, keyed on build-host arch. This is why item 16 could only floor one of three files.
Change: make every lane-conditional path record an explicit SKIP, as item 14 did for two tool probes. Coverage totals then become lane-invariant by construction and a single integer floor per file works with no lane keying and no CI-matrix knowledge inside the test file.
Effort L, Risk low. Touches roughly 230 call sites across test_zig_toolchain.py (~155) and test_libcxx_shared.py (~68).
Validation: the same total registers on every lane for a given file; then delete a probe and the board goes red without any lane-keyed table.
Status: TODO - residual of item 16
Blocked by: nothing

---

### 23. Unjustified arm64 gate in test_libcxx_shared.py, inherited for parity with no evidence
Problem: measured on PR #189 / 15f8265f, the file registers 0 passed / 0 failed / 0 warnings / 3 skipped on linux_aarch64_xtarget_linux-aarch64, win_arm64_xtarget_win-arm64 and osx_arm64_xtarget_osx-arm64. The mechanism is `is_arm64` (derived from sys.argv[1] conda_triplet, i.e. the per-output TARGET arch), not native-vs-emulated lanes -- it also fires on any arm64 cross output, not just true-native ones. Each of the three probes DID record an explicit SKIP, it did not vanish silently. So the original framing ("does nothing on the true-aarch64 native lanes", implying silent loss) was wrong on both counts: wrong axis (target arch, not native/emulated) and wrong claim (SKIP recorded, not evaporated). The gate itself was inherited "for parity" with no evidence it is needed.
Change: dropped all three `if is_arm64: SKIP(...); return` gates in test_libcxx_fallback_static, test_libcxx_probe_paths and test_libcxx_shared_simulation, to get a real measurement on arm64 targets instead of an assumed one.
Effort S, Risk med (opens linking-test wall-clock on arm64 targets for the first time).
Validation: those three lanes register a non-zero pass count, or a real FAIL/WARN naming a concrete reason.
Status: IN PROGRESS - gate dropped 2026-09-19; DONE only once a board shows real arm64 pass/fail counts
Blocked by: nothing

---

### 24. The mingw named-member check covers only one of three windows target arches
Problem: recipe/testing/test_mingw_crt.py:206 defines the required member tuple ("ucrt_snprintf", "ucrt_vsnprintf", "thread", "mutex"). Severity is correct and unconditional -- :211-215 does sys.exit(1) on a missing member, with no WARN branch and no per-arch conditional altering severity anywhere in :185-217. Coverage is the defect: :190 inspects exactly ONE on-disk archive, lib_dir / "libmingw32.lib", once. The comment at :2 and the success print at :217 ("x86_64-windows-gnu CRT bootstrap: OK") scope it to x86_64-windows-gnu only. aarch64-windows-gnu and x86-windows-gnu archives are never member-checked in any form, so a missing required member on those two arches produces NO output at all. The three-arch list at :108 ("x86_64-windows-gnu", "aarch64-windows-gnu", "x86-windows-gnu") drives only the link-probe loop at :105-145 (failures aggregated at :221-224); it does not feed the member check. Same silent-degradation class as items 14 and 16: absence of a record is worse than a WARN, because nothing in the log distinguishes "checked and fine" from "never checked". Found by a question from the sibling zig 0.16 feedstock session, which has the inverse trade-off -- it looks at all three arches but FAILs on only x86_64-windows-gnu and merely WARNs on the other two; the correct target for both trees is FAIL on all three.
Measured by the ocaml-feedstock session against our published zig_win-arm64 2131 package: every archive in a given staged mingw lib dir reports an identical byte size (lib-common 10664696, lib32 11135226, libarm64 11084548 -- four names x two extensions, one size per dir). That four-name copy is deliberate, by design, and correct -- not a defect. The consequence is assertion strength, not artifact health: the byte floor at _mingw.sh:699 (9500000) cannot tell a real libmingw32 from a combined archive misnamed as one, so on the two arches this item's member check skips, staged archives get zero content-level verification, only a size floor the four-name copy trivially satisfies. The aarch64 archive did link a trivial C main to .exe on a native win-arm64 lane, so the artifact itself is functional; the gap is purely in what the automated check can catch.
Change: lift the member check into the per-target loop so it runs for all three windows arches at the existing FAIL severity, rather than once against the native libmingw32.lib.
Effort M, Risk med (may immediately redden aarch64-windows-gnu and x86-windows-gnu if their archives really are missing members -- that would be the silent breakage being found, not a regression).
Validation: the check reports a per-arch result for all three targets; a deliberately stripped member on any one of the three arches trips a FAIL.
Status: TODO
Blocked by: nothing

---

### 25. The zig-cc wrapper contract has no coverage of linking a foreign prebuilt import library for a Windows target
Problem: MEASURED facts with anchors. Every wrapper-facing Windows-target link this recipe exercises uses ONLY zig-cc-produced inputs: the cache-warm link at recipe/building/_mingw.sh:667-670 compiles and links warm.c alone (`zig cc -target <t> -pthread warm.c -o warm.exe`, no -l beyond -pthread), and the test probe at recipe/testing/test_mingw_crt.py:116 is argv [zig_exe, "cc", "-target", target, "-o", out, src] with _LINK_PROBE_C (:41-55) touching only mingw CRT symbols zig supplies. The SELF-BUILD is the opposite: recipe.yaml:371-381 puts clangdev, llvm, lld, libclang-cpp, zlib and zstd in zig_impl's host requirements with NO windows gate, so zig_impl for win-64/win-32/win-arm64 links conda-forge stock (foreign-toolchain) archives when it builds itself via build_zig_with_zig (recipe/building/_build.sh:6-35; the cmake path configure_cmake_zigcpp is dead code, never called). That path is green.
Static-vs-import-lib question: RESOLVED by measurement, not unverified. The ocaml-feedstock session listed conda-forge's win-arm64 zstd package: libzstd.lib and zstd.lib are both 45308 bytes beside 600064-byte libzstd.dll/zstd.dll -- import-library sizing -- and no static libzstd.a exists in the package at all. This confirms the naming inference from CMakeLists.txt-01-correct-LLVM_LIBRARIES.patch:4,13 (zstd.dll.lib). So the self-build's foreign-archive link is import-lib/shared and does NOT exercise a foreign-static-archive path; for that sub-question the gap is total, not partial.
This also weakens the item's original premise: conda-forge ships no static libzstd for win-arm64, and zig is the only compiler on that lane, so no static archive can be obtained or produced there with available packages. If no such artifact exists, no consumer can link one either -- the static-archive gap is THEORETICAL, not consumer-facing.
The real consumer-facing operation is linking a foreign IMPORT LIBRARY, which now has positive external evidence: the ocaml session's probe linked conda-forge's libzstd import lib through the zig-cc wrapper successfully (exit 0) on the native win-arm64 lane. This recipe still does not test it -- every wrapper-facing link above uses zig-cc-produced inputs only. The self-build's success at pulling in conda-forge's own zstd masks this gap by producing evidence that looks reassuring without exercising the wrapper path a consumer actually uses.
Structural reason this matters most on win-arm64: conda-forge ships stock arm64 binaries built by MSVC and zig is the only compiler available for that lane (no m2w64-style matching toolchain), so every consumer there is a cross-toolchain consumer by default.
Provenance: raised by the ocaml-feedstock session's executable link, which originally panicked the driver ("reached unreachable code") on the first executable pulling in conda-forge libzstd. That original zstd-mechanism hypothesis is now DEAD: their import-lib link succeeded and no static archive exists to explain a mechanism around one. Their leading explanation moved to a command-line-length / response-file threshold, which is not a zig-feedstock defect and is out of scope here.
Change: added recipe/testing/test_foreign_import_lib.py, a wrapper-facing probe (invoking the <triplet>-zig-cc entry point, not bare zig cc) that links an executable against conda-forge's prebuilt zstd IMPORT LIBRARY, declaring the symbol locally rather than including its header so an include-path failure cannot be misread as a link failure. Keyed on `is_native and (xc_w64 or xc_warm64)` -- native, not per-target -- because a win-64 test environment can only install win-64-subdir zstd: conda cannot install a foreign subdir's import library, so a cross-target import-lib probe is unreachable by construction. win-32 is excluded because no native win-32 lane exists in the matrix (`is_native and xc_win32` can never fire). Covering the static-archive case would first require identifying a package that actually ships a static archive for the target; none is currently known.
Effort S-M, Risk low (a new probe; if it fails it is reporting a real consumer-facing defect).
Validation: each NATIVE windows lane (win-64, win-arm64) reports pass/fail for linking a foreign prebuilt import library through the wrapper. recipe/testing/test_foreign_import_lib.py passed first run on both native windows lanes at commit a6dbbc44, 24/24 green.
Status: DONE, CI-VERIFIED
Blocked by: nothing

---

### 26. Assert that the highest published build_number belongs to the highest published snapshot
Problem: all snapshots publish as version 0.17.0, so build_number is conda's sole ordering lever; nothing currently asserts that it orders correctly. Measured consequence: published zig_dev builds were 2033_0, 2056_0, 2056_1, 2085_0, 2125_0, 2127_0, 2131_0, so the single 2056 rebuild outranked every newer snapshot and an unconstrained consumer spec resolved 75 snapshots stale. Found by the ocaml-feedstock session, not by us, after it had already cost them CI rounds. The leading build-string field is a VARIANT hash and cannot discriminate snapshots (aba11b2 spans 2127 and 2131), so the snapshot field is the only usable selector. Note the residual hazard that snapshot-derived numbering does not remove: a rebuild of an OLD snapshot published at a higher number would invert the order again.
Change: add a post-publish or CI check asserting that max(build_number) across published builds belongs to max(snapshot), for each subdir; fail loudly if not.
Effort S-M. Risk low.
Validation: the check reddens when a deliberately mis-numbered build is present, and passes on the current label state.
Status: TODO
Blocked by: nothing

---

### 27. The nonunix wrapper never implemented GNU `-l:<filename>` exact-filename linking, so it panics the zig 0.17 driver
Problem: MEASURED facts with anchors, verified in this tree. `zig-cc-unix.c:174`'s `is_post_translate_drop()` DROPS `-l:libpthread.a` and `-l:libpthread.so*` (`:152-154`), plus `-lgcc_eh`/`-lgcc_s` on the same line -- but a drop only works on unix because pthread there is supplied transparently via libc, so losing the token costs nothing. `zig-cc-nonunix.c:116-124`'s `is_drop_flag()` implements none of these filters -- the nonunix side has never had ANY handling for GNU `-l:` syntax, not a narrower version of the unix behaviour, an absent one. The split is structural, not an oversight in one function: `install_zig_activation.py:49` sets `is_nonunix` from `"mingw32" in conda_triplet`, then `:440-473` builds the unix `.c` and `:391-409` the nonunix `.c` from the same `flag_rules.py`-generated `_translate.inc` (R1-R13); that shared manifest contains NEITHER filter, so hand-written drop/translate logic on either side has always had to be added per-file, and nonunix simply never got any. Consequence on mingw: `-l:libpthread.a` reaches zig's own `-l:` parsing path unmodified, where zig 0.17's driver panics ("reached unreachable code", exit 3) for `aarch64-w64-mingw32`.
MEASURED by the ocaml-feedstock session, conda-forge ocaml-feedstock PR 146, job 106541858575: baseline + `-l:libpthread.a` = exit 3 PANIC; baseline + `-lpthread` = exit 0; baseline + `-lwinpthread` = exit 0. They also refuted command-line length (to 22183 chars), object count (1..256), and `.a`-vs-`.lib` archive naming as causes.
Change: `zig-cc-nonunix.c` now implements the general, semantically-correct GNU `-l:` resolution instead of a narrow token-specific rewrite. GNU ld/gcc's `-l:<filename>` means "search the `-L` directories in order for a file of that EXACT name and link it as an input file" -- a different contract from `-lfoo` (library search by stem). The wrapper collects every `-L` dir from argv in a first pass (both `-L <dir>` and `-L<dir>` spellings), then for each `-l:<filename>` token resolves it against those dirs in order and substitutes the token with the RESOLVED ABSOLUTE PATH passed as a plain positional input file. This preserves GNU semantics exactly, works for ANY `-l:libfoo.a` (not just libpthread), and sidesteps zig's `-l:` parsing path entirely -- which is what panics the driver, so this is a structural fix, not a token-specific workaround. If the file is not found in any `-L` dir, the wrapper prints a one-line diagnostic naming the token and the searched directories and exits non-zero, rather than forwarding the token and letting zig panic uninformatively.
Consequence for scope: the earlier open question "does this token panic for other `-l:libfoo.a` values, not just libpthread" is now MOOT for anything going through this wrapper -- no `-l:` token reaches zig's driver anymore, resolved or not.
OPEN sub-item: `zig-cc-unix.c` still DROPS `-l:libpthread.a`/`-l:libpthread.so*` (`:174`) rather than resolving them the same way, so the two wrappers are now inconsistent in mechanism (unix drops silently and relies on libc providing pthread; nonunix resolves and links explicitly). The unix drop is live, green, and deliberately left alone this round since it is not broken. Converging unix onto the same `-L`-resolution logic as nonunix is a separate, undecided change.
Effort S-M. Risk low (nonunix wrapper only; unix side untouched).
Validation: mingw lane linking a token that reaches this path must exit 0 where it previously exited 3; a deliberately-unresolvable `-l:` token must fail loudly with the new diagnostic, not silently pass through.
Status: DONE, pending CI
Blocked by: nothing (the unix-side convergence noted above is a separate, unscheduled item)

---

### 28. GNU windres `-i <input-file>` form was never translated, on any platform
Problem: the complete windres flag-translation set was exactly one rule, `-o` -> `-fo`; `-i` was forwarded verbatim in both wrappers (`zig-windres-nonunix.c` ~:78 and the `run_windres` path in `zig-cc-unix.c` ~:615). zig's `resinator` follows `rc.exe` semantics, where `-i` names an include DIRECTORY, not an input file -- so a verbatim `-i <file>` made resinator treat the input .rc file as a directory and report "missing input filename". This was NOT a unix/nonunix asymmetry the way item 27 is -- it was a gap present identically in both wrappers. `recipe/testing/test_windres.py` could not have caught it: both its pre-existing tests pass the input file POSITIONALLY, the one input spelling that already worked, so `-i` coverage was structurally absent, not merely unexercised.
Consumer impact, MEASURED by the ocaml-feedstock session: conda-forge/ocaml-feedstock PR 146 win-arm64 was TOTALLY blocked at flexdll `Makefile:220` with `<cli>: error: missing input filename` (job 106541858575). flexdll carries THREE windres invocations selected by `command -v` at build time, so a consumer-side workaround is runner-dependent and cannot be made reliable -- which is why the fix belongs in the wrapper, not in the consumer.
Change: both `zig-windres-nonunix.c` and the `run_windres` path in `zig-cc-unix.c` now translate GNU `-i <file>` into a POSITIONAL input argument, handling both the spaced (`-i <file>`) and concatenated (`-i<file>`) spellings. `recipe/testing/test_windres.py` gained two new cases exercising exactly these two spellings against `-o`/`-fo`, verified to exit 0 with a non-empty output file, reusing the file's existing `.rc` fixture content.
Effort S. Risk low.
Validation: `recipe/testing/test_windres.py` on any lane where the wrapper is exercised, plus the two new `-i` cases; failure signature was `missing input filename` before this change.
Status: DONE, pending CI
Blocked by: nothing

---

### 29. The general `-l:` resolver shipped with no test exercising it

Problem: item 27 added general GNU `-l:<filename>` resolution to `zig-cc-nonunix.c`, but nothing in this recipe emits a `-l:` token, so no lane runs that code. Its only coverage was the zig-cc syntax check plus review. A defect there would surface in a consumer build, never on our board. This is the same shape that produced items 25, 27 and 28: a wrapper capability consumers depend on that the recipe's own build never exercises.

Change: new `recipe/testing/test_l_colon_link.py`, gated `xc_w64 or xc_warm64` so it runs on all four windows-target lanes. It builds a real `libfoo.a` via `<triplet>-zig-cc -c` plus `<triplet>-zig-ar rcs`, then makes four assertions: `-l:libfoo.a` resolves and links against a joined `-L<dir>`; the same against a spaced `-L <dir>`; an unresolvable token WITH a `-L` dir fails non-zero carrying the searched-dirs diagnostic and naming the dir; an unresolvable token with no user `-L` dir fails non-zero carrying the wrapper's own diagnostic rather than a zig driver panic. The fixture symbol `foo_value` exists only inside the archive, so a dropped or mangled token fails the link with an undefined symbol - the link succeeding is what proves the resolved absolute path actually reached the linker.

Note on the fourth assertion: `collect_l_dirs` reads the already-translated argv, so the wrapper may contribute `-L` dirs of its own even when the caller passes none. That check therefore asserts only `-l:libmissing.a not found`, the substring common to both diagnostic spellings, rather than assuming the zero-dirs wording.

Effort S. Risk low (test-only; adds no wrapper code).
Validation: the four checks above on `win_64_xtarget_win-64`, `win_64_xtarget_win-arm64`, `win_arm64_xtarget_win-64` and `win_arm64_xtarget_win-arm64`.
Status: DONE, pending CI
Blocked by: nothing
