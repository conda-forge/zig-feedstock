# Recipe improvements ledger (zig 0.17 track)

Generated 2026-09-14 from workflow wf_ea95c57a-438, anchored at snapshot 2127+e90365cd5. This file is the STATE of the improvement work and must be updated in the SAME commit as each change. Improvements ride the CURRENT nightly snapshot-bump branch by policy (amended 2026-09-14): separate improvement PRs get no review and cost more than they return, so the nightly snapshot PR doubles as the merge vehicle and work leap-frogs forward on each night's branch. WARNING: the bot cuts each nightly snapshot PR from `dev`, not from the previous snapshot branch -- a snapshot PR that does not merge before the next is cut strands its accumulated improvements and needs a manual merge (precedent: #186 cut from dev at 6c00f159 ~70 min before #185 merged, hence merge commit 8f80f319).

**Note.** Batches 1 and 2 (items 1, 2, 3, 8, and 6) both landed on `snapshot/dev-2127+e90365cd5` (PR #186) under the amended rule above.

## Status table

| ID | Title | Effort | Risk | Status | Validated by |
|----|-------|--------|------|--------|---------------|
| 1 | config.h mutation assert instead of silent no-op | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 2 | Split EXTRA_ZIG_ARGS along maker/configurer boundary | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 3 | Stop mingw layer degrading silently | S-M | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 4 | Use ZIG_LIB_DIR instead of argv[0]/lib-copy workaround (SPECULATIVE) | S-M | med | TODO | - |
| 5 | Build-time upstream-assumption ledger | M | low | TODO | - |
| 6 | Encode patch order in filenames, not comments | M | low-med | DONE (scope narrowed on measurement; board pending) | - |
| 7 | Adopt -Doptimize=safe (SPECULATIVE) | S | low-med | TODO | - |
| 8 | Retire shipped debug instrumentation | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 9 | Replace hand-rolled import libs with upstream's (SPECULATIVE) | L | high | TODO | - |
| 10 | Machine-check patch apply-order via Applies-after headers | M | low | TODO | - |

## Batches

- **Batch 0 (infrastructure)**: restructure `recipe/SNAPSHOT_TRIAGE.md` into invariant-procedure vs anchor-table, create this ledger, create the thin triage skill. Touches no recipe logic. - DONE 2026-09-14
- **Batch 1 (silent-degradation sweep)**: items 1, 2, 3 and optionally 8. One theme, all small, one CI board validates all of them. - DONE 2026-09-14
- **Batch 2**: item 6 (patch order in filenames). Scope narrowed to two-file rename (mingw.zig-01/-02); own board pending. - DONE 2026-09-14
- **Batch 3**: spikes for items 4 and 7 - investigate and decide, not implementation.
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

Status: TODO
Blocked by: a ppc64le lane run; do not delete the copy in the same commit that adds the export.

---

### 5. A build-time upstream-assumption ledger

**Problem.** Our upstream dependencies are asserted nowhere and discovered only by failure: the `config.h` define shape, the CRT flag set, `zig env`'s JSON keys (`recipe/testing/test_libcxx_shared.py:141-146` needs `global_cache_dir`; `ci_support/probe_mingw_setjmp.sh:91` needs `lib_dir`), the six-key libc-file format (`recipe/building/_cross.sh:33-40`), and the `_CRTIMP` regex (`_mingw.sh:489-490`). The `gen_translators.py --check` guard already wired into the recipe is the right precedent.

**Change.** One `building/_assert_upstream.sh`, sourced once early, that checks each assumption against the extracted source and the bootstrap binary and fails with a named assumption id. Mirror the list into `ZIG_RECIPE_LLM_REFERENCE.md` so the doc and the check share one inventory.

**Effort.** M. **Risk.** low.

**Validation.** Runs on all lanes; signature `ASSUMPTION FAILED: A07 zig env lacks key 'lib_dir'` before any compilation.

Status: TODO
Blocked by: nothing

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

Status: DONE (scope narrowed on measurement; board pending)
Blocked by: nothing

---

### 7. Adopt `-Doptimize=safe` (SPECULATIVE)

**Problem.** `-Doptimize=ReleaseSafe` at `recipe/build.sh:83` and `recipe/building/build_native.sh:173`, `:271` survives only via `std.lang.Optimize.fromString`, marked `Deprecated, to be removed after 0.18.0`.

**Change.** Switch all three together to `-Doptimize=safe`.

**Effort.** S. **Risk.** low-med -- SPECULATIVE: that `standardOptimizeOption` accepts the bare tag `safe` is UNVERIFIED here.

**Validation.** One linux-64 native build; failure is immediate (`expected -Doptimize to be of type ...`).

Status: TODO
Blocked by: confirming the tag spelling against `lib/std/Build.zig` at the pinned snapshot.

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

**Problem.** Four measured apply-time edges are expressible only in prose or ad-hoc patch headers, and three of them cross selector groups where filenames cannot help:
- `src/link/Lld.zig`: `prefer-shared-libcxx` (1210-1222) vs `linux/Lld.zig-no-unconditional-as-needed` (1224-1241), 2-line gap, crosses groups
- `build.zig` on windows: `non_unix/build.zig-03-msvc-crt-dynamic` (886-901) vs `non_unix/build.zig-01-maxrss` (900-906), overlap, currently undocumented anywhere
- `lib/libc/mingw/lib-common/api-ms-win-crt-runtime-l1-1-0.def.in`: `mingw.zig-02-arm64-stubs` vs `ucrtbase-export-atexit-alias`, same file, crosses groups, undocumented
- `src/link.zig`: `link.zig-01` vs `link.zig-03` overlap at 1226-1229 (currently carried only by the filename ids)

The `Applies-after:` header convention already exists in `recipe/patches/linux/Lld.zig-no-unconditional-as-needed-glibc-bundled.patch`, which carries `Applies-after: Lld.zig-macho-lld-support.patch, Lld.zig-prefer-shared-libcxx.patch`.

The reference doc section 5 dependency map currently documents a deleted patch (`ppc64le/0003-gcc-linker-comprehensive-Lld.zig.patch`) and cites recipe.yaml line markers (:179, :182, :231) that no longer resolve -- line-number markers rot, which is the argument for header-encoded edges.

**Change.** Make the `Applies-after:` header universal for measured edges. Add a checker that parses the headers and validates them against recipe.yaml patch order, same shape as the existing `gen_translators.py --check` gate at `recipe.yaml:783`. Demote the recipe.yaml prose comments to semantic-only notes.

**Effort.** M. **Risk.** low.

**Validation.** not recorded.

Status: TODO
Blocked by: nothing
