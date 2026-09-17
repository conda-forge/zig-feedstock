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
| 6 | Encode patch order in filenames, not comments | M | low-med | DONE (scope narrowed) | PR #186 board, 24/24 green @ 335fdf83 |
| 7 | Adopt -Doptimize=safe (SPECULATIVE) | S | low-med | TODO | - |
| 8 | Retire shipped debug instrumentation | S | low | DONE | PR #186 board, 24/24 green @ 6baeee89 |
| 9 | Replace hand-rolled import libs with upstream's (SPECULATIVE) | L | high | TODO | - |
| 10 | Machine-check patch apply-order via Applies-after headers | M | low | TODO | - |
| 11 | Stop parsing `zig env` output as JSON (upstream emits ZON) | S | low | DONE (uncommitted) | - |
| 12 | Split collapsed libc++.a skip into four arms + named compile timeout | S | low | DONE (uncommitted) | - |
| 13 | Emulated-lane coverage gap in libcxx simulation test | S | med | DONE (uncommitted) | - |
| 14 | Tool-probe checks evaporate when the tool is absent | S | low | DONE (uncommitted) | - |
| 15 | No byte-size floor on generated mingw artifacts | S | low | DONE (uncommitted) | - |
| 16 | Harness cannot express expected-but-absent coverage | M | low | TODO | - |
| 17 | Four disagreeing predicates for "is this lane emulated" | M | med | TODO | - |
| 18 | Langref debug scaffolding and 0.17 full-langref remeasure | M | low | DEFERRED | - |
| 19 | Redundant QEMU env exports | S | low | DONE (2026-09-17, uncommitted) | - |

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

Status: TODO
Blocked by: a ppc64le lane run; do not delete the copy in the same commit that adds the export.

---

### 5. A build-time upstream-assumption ledger

**Problem.** Our upstream dependencies are asserted nowhere and discovered only by failure: the `config.h` define shape, the CRT flag set, the assumption that `zig env` emits JSON (`recipe/testing/test_libcxx_shared.py:141-146` parsed it for `global_cache_dir`; `ci_support/probe_mingw_setjmp.sh:91` parses it for `lib_dir`) -- CORRECTED: upstream's `print_env.zig` uses `std.zon.Serializer` and emits ZON (`.{ .global_cache_dir = "..." }`), there is no JSON path and no `--json` flag, so the assumption was never "has key X", it was the false belief the output is JSON at all. The `test_libcxx_shared.py` half is now FIXED (see item 11); the `probe_mingw_setjmp.sh` half is still broken but is untracked local-only tooling. Remaining unasserted: the six-key libc-file format (`recipe/building/_cross.sh:33-40`), and the `_CRTIMP` regex (`_mingw.sh:489-490`). The `gen_translators.py --check` guard already wired into the recipe is the right precedent.

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

Status: DONE (scope narrowed on measurement) - validated by PR #186 board 24/24 green @ 335fdf83 (2026-09-14)
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

---

### 11. Stop parsing `zig env` output as JSON (upstream emits ZON)

**Problem.** `_find_zig_cache_dir` called `zig env` and did `json.loads(r.stdout)`, reading `global_cache_dir`; the except clause swallowed the JSONDecodeError and returned None. Upstream emits ZON via std.zon.Serializer, so this NEVER worked - the cache dir was always unresolved and the libc++.a lookup fell through to a dead rglob over the installed tree, which ships libcxx as source only. Root cause measured on the 0.16 track and confirmed identical here.

**Change.** Drop the `zig env` subprocess entirely; read the ZIG_GLOBAL_CACHE_DIR environment variable, which `setup_zig_global_cache_dir()` (_test_utils.py:59-77, already called at test_libcxx_shared.py:65) guarantees is set. `import json` removed as the sole consumer.

**Effort.** S. **Risk.** low.

**Validation.** Any lane reaching test_libcxx_shared_simulation; the skip must no longer report an unresolved cache dir.

Status: DONE (uncommitted) - adopted from 0.16 track
Blocked by: nothing

---

### 12. Split collapsed libc++.a skip into four arms + named compile timeout

**Problem.** `_find_libcxx_static` returned a bare Path|None and its single caller emitted one collapsed SKIP string, "could not find libc++.a in zig cache or lib dir". On the 0.16 track that string was PROVEN FALSE in a measured case - the archive existed and a different arm had failed. The cache-warming `zig c++ -shared` compile also used a hardcoded timeout=120 with no named constant.

**Change.** `_find_libcxx_static` returns (path, reason) with four distinct arms - compile timed out / compile returned non-zero / zig cache dir unresolved / no libc++.a archive found. Added `_COMPILE_TIMEOUT_S` = 1800 on emulated lanes, 120 native. Arm wording matches the 0.16 track so the trees converge.

**Effort.** S. **Risk.** low.

**Validation.** The SKIP line must name one specific arm, never the collapsed string.

Status: DONE (uncommitted) - adopted from 0.16 track
Blocked by: nothing

---

### 13. Emulated-lane coverage gap in the libcxx simulation test

**Problem.** `test_libcxx_fallback_static` and `test_libcxx_shared_simulation` were both gated to SKIP on `is_arm64 or is_ppc64le or _is_emulated`, so on this track the emulated lanes never exercised the compile, and the raised `_COMPILE_TIMEOUT_S` from item 12 was inert. The 0.16 track's gate on both its callers (:207-209 and :683-685) is `_is_emulated and not is_ppc64le`, with no `is_arm64` term. On 0.16, riscv64 is emulated and therefore SKIPS under that same gate; ppc64le is the ONLY emulated lane that reaches the compile, which is why its ~937s measurement came from ppc64le alone, not two lanes. The earlier "two emulated lanes" cost estimate in this item was an overestimate.

**Change.** Adopted the 0.16 carve-out at both sites: `is_arm64 or is_ppc64le or _is_emulated` -> `is_arm64 or (_is_emulated and not is_ppc64le)`. We keep our `is_arm64` disjunct deliberately - the 0.16 track has no evidence on it and we are not dropping it for parity. This opens exactly ONE lane, linux-ppc64le; riscv64 still skips (emulated and not ppc64le), aarch64 and osx-arm64 still skip via `is_arm64`, and linux-64/osx-64/win-64 are unchanged. 0.16's `_COMPILE_TIMEOUT_S = 900` is unconditional (its :94) and its own raise is proposed-not-applied, so 900 is what produced its ~937s timeout arm. Ours is already 1800 on emulated lanes (item 12). Opening ppc64le here with 1800 is therefore a live experiment the 0.16 track cannot run: if the timed-out arm stops firing under our 1800s ceiling, that confirms 900 was the whole story on 0.16.

**Effort.** S. **Risk.** med (adds wall-clock to one emulated lane).

**Validation.** linux-ppc64le wall-clock delta and pass/timeout outcome on the next board; expected observation is recorded above.

Status: DONE (uncommitted) - needs a board; expected cost is added wall-clock on linux-ppc64le only
2026-09-16: maintainer decision - emulated carve-out removed, riscv64 runs linking tests too (gate now `is_arm64` only); prior board 35158476859 showed riscv64 0p/3s under the carve-out, and under the old inert gate 3p/1w/3s with 120s timeout.
Blocked by: nothing

---

### 14. Tool-probe checks evaporate when the tool is absent
Problem: two `shutil.which(...)` probes in test_libcxx_shared.py had no else-branch - `nm` at :291-302 and `strings` at :364-375. With the tool absent, neither PASS nor FAIL nor SKIP was recorded and the check vanished from the report entirely. Raised by the 0.16 track, which found the `strings` instance in its own tree; we have TWO sites, not one. This is the silent-degradation theme in the one form the item-1 assertion work cannot catch, because nothing fails and nothing is skipped.
Change: both probes now record a SKIP naming the missing tool.
Effort S, Risk low.
Validation: any lane lacking nm or strings must now show a SKIP line instead of silence.
Status: DONE (uncommitted) - raised by 0.16 track, extended here
Blocked by: nothing

---

### 15. No byte-size floor on generated mingw artifacts
Problem: `_mingw.sh` (730 lines) asserts a COUNT floor on generated import libs (`_gen_count_floor=2200` at :355, checked :371-372) but has NO byte-size assertion on any generated artifact - only `[[ -s ... ]]` non-empty tests at :190 and :278. A truncated-but-non-empty artifact passes both. The 0.16 track carries a real byte-size floor at its `_mingw.sh:680` that we lack; conversely it lacks our count floor. The two assertions are independent and neither subsumes the other.
Change: artifact is `libmingw32.lib`, harvested per target triple inside the cache-warm loop. Floor 1000000 bytes, measured with `wc -c`. Adapted NOT copied: our warm loop already had `_warm_failed_count`/`_warm_failed_list` (declared :632-633) with a post-loop FATAL at :722, so the existing counter was reused rather than adding a parallel one. Inserted at :691-699, inside `generate_mingw_import_libs` (function spans :8-743), after the `_warm_lib` existence check at :679-680. Deliberate deviation from the 0.16 shape: the measured size is logged UNCONDITIONALLY, pass or fail. The 1000000 figure is a round number roughly 10x below the 0.16 track's observed 10.8-11.4MB archives, and we have never measured ours. Logging every size puts our real numbers on the next board so the floor can be tightened on evidence. Reference doc section 5 updated in the same change.
Effort S, Risk low.
Validation: win-64 native (the only lane that sources _mingw.sh for generation).
Status: DONE (uncommitted) - needs a win-64 native board to record our actual sizes
Blocked by: nothing

---

### 16. Harness cannot express expected-but-absent coverage
Problem: raised by the 0.16 track and it generalises item 14. Our harness test files end `return 1 if n_fail > 0 else 0`; SKIP and WARN never affect the exit code. So at the exit-code level a check that EVAPORATED, a check legitimately SKIPPED, and "nothing to test on this lane" are indistinguishable. Item 14 converted two evaporating probes into SKIPs, which is honest but still invisible to anything automated - the board cannot tell you coverage went missing. This is the general form of the whole batch-1 silent-degradation theme.
Change: assert a minimum expected check count per test file, or an expected-coverage manifest keyed by lane, so a vanished check FAILS the board rather than quietly shrinking it. Not designed yet.
Effort M, Risk low.
Validation: deliberately delete a probe locally; the board must go red, not merely quieter.
Status: TODO - raised by 0.16 track
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
Status: DONE (2026-09-17, uncommitted) - verify on next board
Facts (qemu-execve 11.0.3 build 12): activation always exports `QEMU_EXECVE=${CONDA_PREFIX}/bin/qemu-execve-<arch>`; activation never sets `QEMU_EXECVE_NATIVE_PASSTHROUGH`, and the C code defaults passthrough ON unless the value is exactly `"0"`.
Change: removed 8 `export QEMU_EXECVE="${QEMU_EXECVE:-$(command -v qemu-execve-...)}"` and 11 `QEMU_EXECVE_NATIVE_PASSTHROUGH` sites (8 `export ...=1` in recipe.yaml plus 3 `env ...=1` prefixes in build.sh/_langref.sh). Pin -> `version="==11.0.3", build_number=">=12"` (converges with 0.16 track).
Validation: emulated lanes still print `QEMU_EXECVE=... exists=yes` in diag, resolve `qemu-execve` 11.0.3 build >=12, and `test/langref-critical` counts unchanged.
