# PATCH_MAINTENANCE.md

Tracked method doc under `recipe/`. Per-patch facts belong in
`recipe/PATCH_MANIFEST.yaml`; prose rationale belongs in `recipe/NOTES.md`.
Both are companion artifacts landing alongside this doc; a new patch gets
its row/entry there in the same change, or it becomes unfalsifiable
(section 6).

## 1. Why this exists

A workaround that has become unnecessary produces exactly the same green
lane as one still essential. Success is never evidence of necessity. Patch
regeneration proves the targeted upstream code still EXISTS, never that the
PROBLEM still exists.

## 2. Two justification classes

- **EXTERNAL-CONDITION**: a checkable state of the world. Retirable by
  reading (docs, upstream source, dependency versions) -- no CI required.
- **OBSERVED-FAILURE**: a crash we saw. Retirable only by ablation.
- **UNRECORDED**: neither. Unfalsifiable until ablated.

## 3. The oracle requirement

Ablation is only meaningful against a recorded symptom. Without one, a red
lane tells you nothing -- an unrelated failure looks identical to a
confirmed need. Corollary: ablating an UNDEFENDED patch MANUFACTURES its
missing documentation -- the failure text becomes the symptom field.

## 4. Ablation protocol

Scratch branch on the FORK (origin, MementoRC), never the live PR; an
ablation push replaces a green matrix with deliberate red. One unit per
run. Branch each ablation from the last KNOWN-GREEN commit, not from HEAD
-- an untested change already sitting on HEAD gives a red lane two
possible causes.

GHA (`.github/workflows/conda-build.yml`) triggers on bare `push:`, so a
fork branch runs the linux and win lanes. osx runs ONLY on Azure
(`azure-pipelines.yml` -> `.azure-pipelines/azure-pipelines-osx.yml`),
wired to the conda-forge org repo, so a fork push never triggers it. A
unit needing osx signal (notably the macho/LLD group) must go through a
DRAFT PR to conda-forge:main instead -- upload-safe, since conda-forge's
upload step is PR-aware and skips for PR builds.

There is no native ppc64le or riscv64 runner. Both lanes run on
ubuntu-24.04-arm with the linux-anvil-aarch64 image: an aarch64 host
executing a foreign-architecture target under emulation. Timings there
are QEMU-bound floors, not estimates, and QEMU_EXECVE is in play, so a
failure there may originate in the emulation layer rather than the thing
being ablated -- check the recorded symptom matches before concluding the
workaround is still needed.

0.17 skips langref on every lane by default (`skip_langref` derives from
`SKIP_LANGREF`, default `"1"`, recipe.yaml:31). An ablation whose symptom
only shows up under langref must explicitly opt in, and on ppc64le a
langref run is known to cost close to an hour under emulation -- budget
for it and do not treat its absence from a normal green run as coverage.

## 5. Ablation units

Some workarounds span several files and must be toggled together. Do not
queue a lone file from a unit -- retiring part of one without the rest
either does nothing (a redundant sibling still carries the load, see
section 12) or breaks a load-bearing order.

Units grounded on this tree (recipe.yaml patch list, lines 179-251):

- **macho/LLD group** -- `Lld.zig-macho-lld-support`,
  `llvm.zig-lld-ofmt-macho`, `main.zig-fuse-ld-lld-cc-path`,
  `Config.zig-macho-no-auto-lld`. `macho-lld-support` must apply first;
  the other three patch or call code it adds.
- **mingw setjmp/stub ordering** -- `mingw.zig-01-include-setjmp-s` then
  `mingw.zig-02-arm64-stubs`; the `-01`/`-02` ids encode load-bearing
  order on `src/libs/mingw.zig` per the recipe.yaml comment at line 192.
- **mingw atexit pair** -- `mingw-crtexe-no-atexit` removes atexit,
  `ucrtbase-export-atexit-alias` restores it under a different symbol;
  the recipe.yaml comment says explicitly "do not drop one without the
  other". `gccmain-do-global-ctors-guard` in turn consumes the alias the
  second patch exports.

If you cannot point to the recipe.yaml lines that couple two patches,
treat them as independent rows, not a unit.

## 6. Recording rule

New patches land with their verbatim symptom in the manifest, or they
become permanently unretirable. A description of WHAT the patch changes
is not a WHY.

## 7. Coverage caveat

ppc64le carries a dedicated 2-patch group (`ppc64le/0001-arch-support`,
`ppc64le/0002-build-config`, both gated `if: linux`) plus version-floored
deps not needed elsewhere (`binutils_impl_*` >=2.45, `gcc_impl_*` >=14.3,
recipe.yaml:389-390, 630-633, 646-649, and `libclang-cpp` in the
cross-shim test, line 740-742). The DT_NEEDED test (lines 459-466) and
the PT_PHDR test (lines 482-489) run on ppc64le as a `linux` variant, so
those two are covered there. langref, ppc64le's main extra coverage on
0.16, is OFF by default on every 0.17 lane (section 4) -- a normal green
ppc64le run says less here than elsewhere, and less than it used to.

## 8. Where this system lives

TRACKED under `recipe/`, shipping with the feedstock: `PATCH_MAINTENANCE.md`
(this file), `NOTES.md` (prose rationale a manifest `ref:` field cites),
`PATCH_MANIFEST.yaml` (per-patch facts).

UNTRACKED and deliberately local, never committed: `ZIG_RECIPE_LLM_REFERENCE.md`
(repo root), `recipe/SNAPSHOT_TRIAGE.md`, `recipe/IMPROVEMENTS.md`. Same
reasoning as `check_patch_relevancy.sh` staying local-only (section 13):
these are working documents, not shippable method or fact records.

## 9. Writing a drop-when condition

Some patches already carry a `Drop-when:`-shaped comment. Keep that
convention and make it universal -- but write the condition against the
SYMPTOM DISAPPEARING, never against a predicted upstream remedy.

Grounded example already in this recipe: `target.zig-glibc-needs-libunwind.patch`
is commented "Drop when conda-forge linux glibc floor reaches a version
that no longer forces libunwind" (recipe.yaml:206), and
`target.zig-ppc64le-glibc-2.17-min.patch` similarly names "conda-forge
ppc64le glibc floor reaches 2.18 or higher" (recipe.yaml:209). Both name
an external, checkable floor, not an implementation -- copy that shape. A
condition naming a specific upstream implementation detail instead can
end up permanently unretirable even after the underlying problem is
solved a different way.

## 10. The test suite is a third source of justification

A patch's WHY can live in three places: the patch file, the reference
doc, and THE RECIPE'S OWN TEST SUITE. A patch with a dedicated test is
defended -- the test is the symptom, encoded executably, re-checked every
lane, every run.

Grounded on this tree: `Lld.zig-prefer-shared-libcxx` is covered by
`testing/test_libcxx_shared.py` (recipe.yaml:441), and
`main.zig-fuse-ld-lld-cc-path` is covered by the `-fuse-ld=lld` test at
recipe.yaml:546-570. Both run on every applicable lane.

Consequence for ablation design: a patch with a live test CANNOT be
bundled into another unit's ablation, because removing it reddens every
lane running that test and drowns the signal you were actually after.
Check for a covering test before grouping.

## 11. Verify the ablation actually removed the thing

Before interpreting ANY ablation result, grep the build log to confirm
the thing under test is genuinely absent. A green lane from an ablation
that did not actually ablate is indistinguishable from a real retirement,
and reads as a confident result.

Procedure: identify a specific log line that carries the thing, confirm
it BEFORE the ablation and its absence AFTER, then read the lane colour.
A mitigation described in a comment as "defense in depth" is a
particular hazard -- more than one implementation by design, so removing
only one leaves the effect fully present while the lane still reads
green. No 0.17-specific incident of this kind is recorded yet; apply the
procedure from first principles until one is.

## 12. A workaround has three states, not two

Needed-and-running; needed-but-INERT because a redundant sibling silently
carries the load; and not-needed. The middle state is invisible: it
passes every lane, and nothing distinguishes it from the first.

Measured on this track, reported 2026-09-08: the bootstrap setjmp.h
_CRTIMP strip in `_mingw.sh` had NEVER EXECUTED on Windows CI across two
attempts -- first because it required grep and sed, absent from the win
runners, then because its python fallback was also uncallable (PR #181
commit ac523b5b, win-64 lane, log line 1507, verbatim: "WARN: [_mingw]
grep/sed and python both unavailable; _CRTIMP strip on bootstrap
setjmp.h SKIPPED"). Green held the whole time because an independent
second implementation -- the source-tree patch on the shipped zig --
carried it. The same fix shipped TWICE and both attempts were inert.
Shipping a repair is not evidence the repair executes; check new code
with the same unconditional-line discipline as the old.

RULE: assert that a mechanism EXECUTED, not merely that the lane is
green. Emit an unconditional log line when it runs, and check for that
line. A diagnostic gated behind a debug flag CI never sets is not a
diagnostic. `DEBUG_ZIG_BUILD` defaults to `"0"` in this recipe
(recipe.yaml:341 and :622, both `env.get("DEBUG_ZIG_BUILD", default="0")`),
and CI does not override it -- so anything gated on it is unseen there.

WARNING, 0.17-specific and do not "fix" it: never run errexit and xtrace
together in this recipe's shell code (brush 0.4.0, upstream issue #1245,
no released fix). Unlike the 0.16 track, `DEBUG_ZIG_BUILD` on 0.17 gates
diagnostic OUTPUT only, never xtrace. `build.sh` carries an unconditional
`set +x` that exists specifically to keep this safe -- do not remove it,
and do not collapse the build prologue into a single `set -euxo pipefail`.
Flipping `DEBUG_ZIG_BUILD`'s default to enable xtrace in CI is not a
route back to that diagnostic; it also re-breaks the step summary
(`GITHUB_STEP_SUMMARY` has a 1024k ceiling, and exceeding it emits an
`##[error]` annotation on an otherwise successful job). Promote specific
high-value log lines to unconditional instead of un-gating everything.

## 13. The fifth source: maintainer knowledge

Four sources are written down: patch file, tracked prose (`recipe/NOTES.md`),
test suite, recipe.yaml comments. A fifth is not written down anywhere --
what the maintainer knows. The ld-script trio (`link.zig-01/02/03`,
`if: linux`, recipe.yaml:203-205) is DEFENSIBLE because conda-forge's
glibc ships `libc.so` as a GNU ld script, and that fact appears in NO
source in this repo.

Unwritten justification is the most fragile kind: it survives exactly as
long as the person does. The destination is NOT a recipe.yaml comment --
comment-only deletions from recipe.yaml are deliberate, and new comments
there must stay short -- prose justification belongs in `recipe/NOTES.md`.
So the move is source five -> the tracked prose doc, not source four.

Not every local artifact here is promoted, and that is deliberate:
`check_patch_relevancy.sh` stays local-only at the repo root by design,
not as a leftover of an old untracked layout.

## 14. Retirement is not monotonic -- it can orphan neighbours

Removing a workaround can CREATE a new undefended item. Anything that
shipped alongside it, inside the same block or under the same comment,
may have had no rationale of its own -- only proximity to the thing you
just deleted. After any retirement, ask what else lived in that block and
whether its justification died with the neighbour.

This tree already has two comment-coupled pairs where that risk is live:
the mingw setjmp/stub ordering pair and the mingw atexit pair (section 5).
Retiring either half without checking the paired comment leaves the
survivor's constraint undocumented even though the patch itself is
unchanged.

Two consequences. Record the new item immediately, in the same change as
the retirement, or it is invisible from the next session onward. And do
not ablate an orphaned neighbour on top of an unvalidated base: wait until
the retirement that created it has itself gone green in CI, or a red lane
has two candidate causes.
