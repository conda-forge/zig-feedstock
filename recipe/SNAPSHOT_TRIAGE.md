# Snapshot triage methodology (zig 0.17 track)

Generated 2026-09-14 from workflow wf_ea95c57a-438, anchored at snapshot 2127+e90365cd5 (upstream commit e90365cd5).

# Snapshot Triage Methodology (zig-feedstock 0.17)

Purpose: decide, before pushing, whether snapshot `NEW` (e.g. `2127+e90365cd5`) is safe. Baseline `OLD` = the snapshot at `recipe/recipe.yaml:8` before the bump (`2125+0d600e488`); `BASE_SHA`/`NEW_SHA` are the trailing commit hashes.

Conventions used below:
- Upstream file fetch: `curl -fsS https://codeberg.org/ziglang/zig/raw/commit/<SHA>/<path>` (HTTP 200 required; Codeberg is now upstream, GitHub is dead).
- Tree listing: `curl -fsS "https://codeberg.org/api/v1/repos/ziglang/zig/git/trees/<SHA>?recursive=1&per_page=1000&page=N"` (paginate until `total_count` reached; entries carry blob `sha`).
- Never use `build_artifacts/src_cache` as "upstream" for a new snapshot: it holds 2033 and older only.

---

## Step 0 - Fix the inputs (2 min, local)

Checks: that the thing you are triaging exists and is fetchable.

```
curl -fsSI https://ziglang.org/builds/zig-0.17.0-dev.<NEW>.tar.xz
curl -fsSL -o /tmp/zig-<NEW>.tar.xz https://ziglang.org/builds/zig-0.17.0-dev.<NEW>.tar.xz
sha256sum /tmp/zig-<NEW>.tar.xz
```

PASS: 200 + a sha256 you record for `recipe/recipe.yaml:176`.
FAIL: 404 -> `ziglang.org/builds` prunes nightlies; pick a newer snapshot rather than sourcing a tarball from elsewhere (the URL template at `recipe.yaml:175` is `ziglang.org/builds`-only).

## Step 1 - Window inventory: what actually changed (5-10 min, local)

Checks: the full changed-path set between `BASE_SHA` and `NEW_SHA`. This is the only step that bounds all the others.

1. Pull both recursive trees (above), build `{path: blob_sha}` for each.
2. Emit three sets: ADDED, DELETED, MODIFIED.
3. Intersect MODIFIED+DELETED with:
   - the 33 patch target paths (parse them: `grep -h '^--- a/' recipe/patches -r`);
   - the contract files `lib/compiler/Maker.zig`, `lib/compiler/configurer.zig`, `build.zig`, `lib/std/Build.zig`, `lib/std/lang.zig`, `src/Compilation.zig`, `src/link.zig`, `lib/std/zig/LibCInstallation.zig`, `lib/libc/mingw/**`, `lib/libc/mingw/lib-common/*.def*`.

PASS: intersection empty -> skip Steps 3-4, go to Step 2.
ATTENTION: non-empty -> each hit becomes a risk item for Step 5.
Note the asymmetry rule: **anything byte-identical between `BASE_SHA` and `NEW_SHA` is out of scope for this bump**, however alarming the devlog makes it sound. Prove it with blob equality, not prose.

## Step 2 - Patch relevancy / drift (5-15 min per platform, local)

Checks: that all 33 patches still apply, in rattler-build's cumulative order, per platform.

```
recipe/ci_support/check_patch_relevancy.sh linux-64      --snapshot <NEW>
recipe/ci_support/check_patch_relevancy.sh linux-ppc64le --snapshot <NEW>
recipe/ci_support/check_patch_relevancy.sh osx-64        --snapshot <NEW>
recipe/ci_support/check_patch_relevancy.sh win-64        --snapshot <NEW>
recipe/ci_support/check_patch_relevancy.sh win-32        --snapshot <NEW>
```

Run this *before* editing `recipe.yaml` - `--snapshot` skips the sha256 check for exactly this reason. Five platforms cover every selector branch (`unix`/`linux`/`not unix`/`win32`).

PASS: exit 0, no `FAIL`, no `HIGHFUZZ`.
REVIEW: `OBSOLETE` -> upstream absorbed it; remove from `recipe.yaml` and from reference doc section 4. `DRIFT`/`HIGHFUZZ` -> regenerate via `/conda-patch-generator`. `OFFSET(n)` with small n -> benign; large n on a deep anchor (e.g. `linux/Sema.zig-shr-exact-safety-downgrade.patch @@ -13260`) -> eyeball the region.
FAIL: any `FAIL` before the first cascade warning is real; results *after* the first `FAIL` are cascade noise - fix the first one and rerun.

## Step 3 - Flag and env-var contract drift (10 min, local)

Checks: every non-`-D` token we hand to `zig build` is still parsed, and every `-D` option is still declared.

1. Extract our tokens (single source of truth): `recipe/build.sh:78-88` plus the conditional appends at `:95,:118,:135,:142,:154,:188-189,:194`, and `recipe/building/build_native.sh:139-155,:168-174,:268-272`.
2. Fetch `lib/compiler/Maker.zig` at `NEW_SHA`; for each maker flag (`--search-prefix`, `--prefix`/`-p`, `--maxrss`, `--libc`, `--libc-runtimes`, `--verbose-link`, `-fqemu`) confirm a `mem.eql(u8, arg, "<flag>")` branch exists.
3. Fetch `build.zig` at `NEW_SHA`; for each `-D` name (`config_h`, `enable-llvm`, `static-llvm`, `strip`, `no-langref`, `use-zig-libcxx`, `version-string`, plus `standardTargetOptions`/`standardOptimizeOption` for `-Dtarget`/`-Dcpu`/`-Doptimize`) confirm a `b.option(...)` declaration. `-Ddoctest-target` comes from our own patch - confirm that patch still applies (Step 2).
4. Confirm no lib-dir flag crept back: `-Dzig-lib-dir`/`--zig-lib-dir` must stay absent from `recipe/` (`ZIG_LIB_DIR_ARGS=()` at `build_native.sh:94,:105` is the deliberate empty shim).

PASS: every token found.
FAIL signature if missed: `error: unrecognized argument: <flag>` (Maker.zig `fatalWithHint`) or `error: invalid option: "<name>"` (configurer.zig), right after `[build_zig_with_zig] ZIG_MAKER_ARGS:`/`ZIG_PKG_OPTS:` and followed by `[build_zig_with_zig] FAILED (exit code 1)` (`recipe/building/_build.sh:28`).

## Step 4 - Build-system shape (2 min, local)

Checks: the configurer/maker split has not moved a flag across the boundary, and `zig build`'s runner API is intact.

```
# md5 both refs
lib/compiler/Maker.zig   lib/compiler/configurer.zig
lib/std/Build.zig        (ExecutableOptions.zig_lib_dir must exist)
```

PASS: `Maker.zig`+`configurer.zig` identical `OLD`->`NEW`, or differing only in branches you verified in Step 3; `zig_lib_dir: ?LazyPath` still declared in `ExecutableOptions` (required by `patches/build.zig-03-compiler-step-zig-lib-dir.patch`).
FAIL: `zig_lib_dir` gone -> `error: no field named 'zig_lib_dir'` while the maker JIT-compiles `build.zig`. If a flag moved sides, the fix is to split `build.sh:78-88` into a `-D` group and a maker-flag group.

## Step 5 - Devlog -> testable risk (15-30 min, local)

Checks: semantic changes the tree diff cannot express (semantics of an unchanged-looking API, new defaults).

Read `https://ziglang.org/devlog/2026/`, take only entries dated after `BASE_SHA`'s committer date (`/api/v1/repos/ziglang/zig/git/commits/<SHA>` gives it). For each entry fill four fields; an entry that cannot be filled is not triaged:

| field | rule |
|---|---|
| `our_surface` | exact `file:line` in `recipe/` (or "none"). Not "the linker" - a line. |
| `evidence` | verbatim upstream fragment at `NEW_SHA` plus our verbatim line. Blob equality `OLD`==`NEW` closes the item as out-of-window. |
| `failure_mode` | the literal log line CI would print, and which lane prints it. If you cannot name the line, you have not understood the risk. |
| `verdict` | `NOT-AFFECTED` / `AT-RISK` / `AFFECTED`, plus confidence. |

Special attention: new opt-in defaults. Two lines are worth re-reading every bump because flipping them would silently bypass all five `src/link/Lld.zig` patches: `src/Compilation/Config.zig` must still end the `use_new_linker` block with `break :b options.incremental;` (with `incremental: bool = false`), and `build.zig` must still read `exe.use_new_linker = b.option(bool, "new-linker", "Use the new linker");` with no `orelse true`. If either flips, pass `-fno-new-linker` / `-Dnew-linker=false` rather than re-deriving the linker story.

## Step 6 - Bootstrap pin satisfiability (5 min, network)

Checks: the self-hosting dep resolves. `recipe.yaml:366` requests `zig_impl_${{ build_platform }}` under the pin at `:11`, built from `snapshot_ref` (`:9`) and `build_ref` (`:10`) - **not** from `snapshot`. The pin must lag: `zig_impl_<build_platform>` is never built in its own lane.

```
conda search -c conda-forge/label/zig_dev --subdir <build_platform> "zig_impl_<build_platform>"
```

PASS: a build string matching `*_<snapshot_ref>_*` with build number >= `build_ref` exists on every `build_platform` in `conda-forge.yml` (build strings are `varianthash_snapnum_snaphash_buildnum`; the variant hash is unpredictable, hence the wildcard).
FAIL: unsatisfiable -> leave `snapshot_ref` alone this bump; do not derive it from `snapshot`.

## Step 7 - Go / no-go gate (before push)

All must hold:

1. Step 0 sha256 recorded at `recipe.yaml:176`, `snapshot` updated at `:8`.
2. Step 2 exit 0 on all five platforms; no `FAIL`, no `HIGHFUZZ`; `OBSOLETE` patches removed from `recipe.yaml` and from disk.
3. Steps 3+4 clean, or a recipe change landed that makes them clean.
4. Step 5: zero `AFFECTED` without a mitigation; every `AT-RISK` has a named failure line and a lane.
5. Step 6 pin resolves.
6. `ZIG_RECIPE_LLM_REFERENCE.md` updated in the same change (section 4 for patch churn, section 7 for refuted hypotheses, header anchor for version/build/LLVM), per its section 9 trigger map.
7. Zero orphan patches: every file under `recipe/patches/` appears in `recipe.yaml:177-248` and vice versa.

Any miss -> fix locally and rerun the affected step. Pushing on a red Step 2 wastes a full matrix.

## What genuinely needs CI (do not pretend otherwise)

Local triage proves *applicability and contract*, never *buildability*. These can only fail in CI:

- **Compilation of the patched tree** against LLVM 22 - a patch can apply cleanly and still not compile (type/signature changes upstream).
- **LLD/linker behaviour**: `-fplt` on ppc64le, `R_PPC64_REL24` range, `--no-as-needed` glibc bracketing (`test_dtneeded.py`), shared-libc++ selection (`test_libcxx_shared.py`).
- **Emulated lanes** (ppc64le, riscv64 under `qemu-execve`): timeouts, wall clock, langref.
- **Windows import-lib generation** (`_mingw.sh`): the 783-def layer, `_gen_count_floor=2200`, and the `[[ -f .../crtexe.c ]]` guards at `_mingw.sh:444/450/456`, which turn an upstream deletion into a **silent skip** with a green build - local triage cannot see that, only Step 1's DELETED set can warn you.
- **osx lanes** (Azure only): absence from check-runs means no build ran, not green.
- **The downstream wrapper contract** (CC/CXX/AR, `print-search-dirs`) and any behaviour of the shipped binary.

Local triage cost is roughly 40-70 minutes wall clock, almost all of it in Step 2's five extractions; a full CI matrix is hours. The gate exists to convert that ratio.
