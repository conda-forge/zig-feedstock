# PATCH_MAINTENANCE.md

Tracked method doc under `recipe/`. Per-patch facts live in
`recipe/PATCH_MANIFEST.yaml`; prose rationale lives in `recipe/NOTES.md`.

## 1. Why this exists

A workaround that has become unnecessary produces exactly the same green lane
as one still essential. Success is never evidence of necessity. Patch
regeneration proves the targeted upstream code still EXISTS, never that the
PROBLEM still exists.

## 2. Two justification classes

- **EXTERNAL-CONDITION**: a checkable state of the world. Retirable by
  reading (docs, upstream source, dependency versions) -- no CI required.
- **OBSERVED-FAILURE**: a crash we saw. Retirable only by ablation.
- **UNRECORDED**: neither. Unfalsifiable until ablated.

## 3. The oracle requirement

Ablation is only meaningful against a recorded symptom. Without one, a red
lane tells you nothing -- an unrelated failure looks identical to a confirmed
need. Corollary: ablating an UNDEFENDED patch MANUFACTURES its missing
documentation -- the failure text becomes the symptom field.

## 4. Ablation protocol

Scratch branch on the FORK (origin, MementoRC), never the live PR; an
ablation push replaces a green matrix with deliberate red. One unit per run.
Some symptoms only appear under langref -- ppc64le now runs it (emulated
ppc64le lane, ~1h19m), riscv64 still skips -- those cost more than 25min.
Know which class before queueing.

IMPORTANT -- the fork-branch route does not work for every unit. GHA
(.github/workflows/conda-build.yml) triggers on bare `push:`, so a fork branch
DOES run the linux and win lanes. But osx runs ONLY on Azure
(azure-pipelines.yml -> .azure-pipelines/azure-pipelines-osx.yml), and Azure is
wired to the conda-forge org repo, so a fork push never triggers it. Any unit
needing osx signal (notably the macho/LLD group) must go through a DRAFT PR to
conda-forge:main. That is upload-safe -- conda-forge's upload step is PR-aware
and skips for PR builds; it is a direct push to the ORG repo that is dangerous.

Branch each ablation from the last KNOWN-GREEN commit, not from HEAD. An
untested change already sitting on HEAD gives a red lane two possible causes.

There is no native ppc64le or riscv64 runner. Both lanes run on
ubuntu-24.04-arm with the linux-anvil-aarch64 image, i.e. an aarch64 host
executing a foreign-architecture target under emulation. Timings on those
lanes are QEMU-bound and are floors, not estimates; an ablation that changes
the link path can run materially longer. Emulation also means the
QEMU_EXECVE machinery is in play, so a failure there may originate in the
emulation layer rather than in the thing being ablated -- check the recorded
symptom matches before concluding the workaround is still needed.

## 5. Ablation units

Some workarounds span several files and must be toggled together:

- **(a) macho/LLD group** -- manifest rows 1-5.
- **(b) R_PPC64_REL24** -- cmake/0005 + cmake/0006 + build.sh:116-134 +
  build.sh:248-253 + recipe.yaml:402-404.
- **(c) GCC-driver** -- ppc64le/0002 + 0003-linker-redirect +
  0003-gcc-comprehensive + the binutils_impl/gcc_impl deps.
- **(d) ld-script** -- linux/link.zig-01/02/03.
- **(e) atexit** -- mingw-crtexe-no-atexit + ucrtbase-export-atexit-alias.

These units form a DAG, not a flat list. Retiring an upstream unit can retire
downstream rows for free: unit (c) GCC-driver subsumes ppc64le/0004 PT_PHDR,
because 0004 only exists to survive the static non-PIE that ld.bfd emits.
Check depends_on before queueing a row on its own.

Unit (b) R_PPC64_REL24 is NOT monolithic: cmake/0005 (-mlongcall on our own
objects) and cmake/0006 (bundle, caused by upstream lld's build flags) have
independent causes and must be assessed separately.

## 6. Recording rule

New patches land with their verbatim symptom in the manifest, or they become
permanently unretirable. A description of WHAT the patch changes is not a
WHY.

## 7. Coverage caveat

ppc64le carries the most workarounds and the least verification: four test
exclusions ride on it (recipe.yaml:455 DT_NEEDED, :563 -fuse-ld=lld ELF, :586
lld test, :155 langref) against one ppc64le-specific test added back
(:479-486 PT_PHDR). Green means less on ppc64le than anywhere else.

## 8. Promotion

This system is tracked under `recipe/`: `PATCH_MAINTENANCE.md` and
`PATCH_MANIFEST.yaml` ship with the feedstock. Prose patch rationale that a
manifest `ref:` field cites lives in `recipe/NOTES.md`.

## 9. Writing a drop-when condition

Some patches already carry a `Drop-when:` header. Keep that convention and
make it universal -- but write the condition against the SYMPTOM
DISAPPEARING, never against a predicted upstream remedy.

Worked example. cmake/0005 says "Drop-when: conda-forge ppc64le LLVM static
archives compiled with -mlongcall". Measured 2026-09-08, conda-forge fixed
the identical R_PPC64_REL24 problem a different way -- stripping -fno-plt and
using -fuse-ld=bfd -mcmodel=medium, i.e. PLT indirection rather than long
calls. The stated condition therefore can never become true even though the
underlying problem may already be solved, which makes the patch permanently
unretirable by its own text.

Correct form: "drop when linking conda-forge's ppc64le liblld*.a no longer
produces 'R_PPC64_REL24 relocation truncated to fit'". A symptom-shaped
condition stays checkable no matter how upstream chooses to fix it.

Rule: a drop-when naming a specific upstream implementation is a bug. Name
the observable failure whose absence retires the patch.

## 10. The test suite is a third source of justification

A patch's WHY can live in three places, not two: the patch file, the
reference doc, and THE RECIPE'S OWN TEST SUITE. A patch with a dedicated
test is defended -- the test is the symptom, encoded executably, and it is
the strongest form because it re-checks itself every lane, every run.

Two rows were misscored UNDEFENDED by ignoring this:
Lld.zig-prefer-shared-libcxx is covered by recipe/testing/test_libcxx_shared.py,
and main.zig-fuse-ld-lld-cc-path is covered by the -fuse-ld=lld test at
recipe.yaml:563-572. Both run on every applicable lane.

Consequence for ablation design: a patch with a live test CANNOT be bundled
into another unit's ablation, because removing it reddens every lane running
that test and drowns the signal you were actually after. Check for a
covering test before grouping.

## 11. Verify the ablation actually removed the thing

Before interpreting ANY ablation result, grep the build log to confirm the
thing under test is genuinely absent. A green lane from an ablation that did
not actually ablate is indistinguishable from a real retirement, and reads as
a confident result.

Worked example, 2026-09-08. An ablation removed cmake/0005-ppc64le-mlongcall
from recipe.yaml and the ppc64le lane went green. The result was VOID: the
mitigation had two independent implementations -- the cmake patch via
target_compile_options, and build.sh:117-118 via global CFLAGS -- and only the
first was removed. Log line 1837 still showed `-mlongcall -mcmodel=large` on
the zigcpp compile. The build.sh comment even said "defense in depth", i.e.
the redundancy was deliberate and documented.

Procedure: identify a specific log line that carries the thing (here, the
zigcpp compile command), confirm it BEFORE the ablation, and confirm its
absence AFTER. Only then read the lane colour. The re-run's line 1830 showed
the flags gone, which is what made its green mean something.

Corollary: a mitigation described as "defense in depth" has more than one
implementation by design. Find them all before scoping the unit.

## 12. A workaround has three states, not two

Needed-and-running; needed-but-INERT because a redundant sibling silently
carries the load; and not-needed. The middle state is invisible: it passes
every lane, and nothing distinguishes it from the first.

Measured on the 0.17 track and reported 2026-09-08: their bootstrap setjmp.h
_CRTIMP strip in _mingw.sh had NEVER EXECUTED on Windows CI across two
attempts -- first because it required grep and sed, absent from the win
runners, then because its python fallback was also uncallable (PR #181
commit ac523b5b, win-64 lane, log line 1507, verbatim: "WARN: [_mingw]
grep/sed and python both unavailable; _CRTIMP strip on bootstrap setjmp.h
SKIPPED"). Green held the whole time because an independent second
implementation -- the source-tree patch on the shipped zig -- carried it.

Same shape as our own -mlongcall void run, from the opposite direction:
there the ablation failed to remove the mechanism; here the mechanism never
ran. In both cases lane colour said nothing about whether the mechanism was
live.

RULE: assert that a mechanism EXECUTED, not merely that the lane is green.
Emit an unconditional log line when it runs, and check for that line. The
0.17 track's corollary is sharper still: a diagnostic gated behind a debug
flag CI never sets is not a diagnostic. Ours is DEBUG_ZIG_BUILD, measured
SET:0 in CI -- anything gated on it is unseen.

The rule applies to the REPAIR as well as the original. The 0.17 track
shipped the same _CRTIMP fix TWICE and both attempts were inert -- first
guarded on grep and sed, absent from the win runners, then on a python
fallback that was also uncallable. Two ships, two SKIPPED lines, green
throughout. Shipping a fix is not evidence the fix executes; check the new
code with the same unconditional-line discipline you apply to the old.

Do not reach for "just turn the debug flag on in CI" as the cure. Measured
on both tracks independently: flipping DEBUG_ZIG_BUILD's recipe default to
"1" does enable xtrace, but it re-breaks the step summary -- GITHUB_STEP_SUMMARY
has a 1024k ceiling, and exceeding it emits an ##[error] annotation on an
otherwise SUCCESSFUL job. That argues for promoting a few high-value lines to
unconditional rather than un-gating everything.

## 13. The fifth source: maintainer knowledge

Four sources are written down: patch file, tracked prose (`recipe/NOTES.md`),
test suite, recipe.yaml comments. A fifth is not written down anywhere --
what the maintainer knows. The ld-script trio (link.zig-01/02/03) is
DEFENSIBLE because conda-forge's glibc 2.17 ships libc.so as a GNU ld
script, and that fact appears in NO source in this repo.

Unwritten justification is the most fragile kind: it survives exactly as
long as the person does. The destination is NOT a recipe.yaml comment --
comment-only deletions from recipe.yaml are deliberate, and new comments
there must stay short -- prose justification belongs in `recipe/NOTES.md`.
So the move is source five -> the tracked prose doc, not source four.

Not every local artifact here is promoted, and that is deliberate:
`check_patch_relevancy.sh` stays local-only at the repo root by design, not
as a leftover of an old untracked layout.

(Correction credit: the 0.17 track flagged the maintainer-knowledge
constraint, 2026-09-08; both tracks share it.)

## 14. Retirement is not monotonic -- it can orphan neighbours

Removing a workaround can CREATE a new undefended item. Anything that shipped
alongside it, inside the same block or under the same comment, may have had no
rationale of its own -- only proximity to the thing you just deleted. After any
retirement, ask what else lived in that block and whether its justification
died with the neighbour.

Worked example, 2026-09-08. Retiring the ppc64le R_PPC64_REL24 mitigation left
-fno-partial-inlining, -fno-ipa-cp-clone and -Wl,--stub-group-size=0 in
build.sh. They were deliberately retained during the ablation -- which is
correct experimental design, since it bounds what the green result covers --
but it means the measurement was taken WITH them present and says nothing
about them, while the comment that explained why they existed is now deleted.
They went from documented-by-association to undefended in a single cleanup.

Two consequences. Record the new item immediately, in the same change as the
retirement, or it is invisible from the next session onward. And do not ablate
it on top of an unvalidated base: the follow-up experiment must wait until the
retirement that created it has itself gone green in CI, or a red lane has two
candidate causes.
