# Slice C: move the engine from Firefox 147.0.4 to 159.0

Issue: #29. Status: implemented except the release (see Outcome). Predecessors: slice A (queue), slice B
(consumable engine, `engine-v147.0.4-1`).

## Why

The engine is pinned to `FIREFOX_147_0_4_RELEASE`, about a year old. That pin
was deliberate: it made the fork's replacement behaviour-neutral. That job is
done (the fork is archived, NightMonkey builds from the release). Staying put
now means missing SpiderMonkey and JIT security and correctness fixes, and
every month makes the eventual rebase larger.

## Assessment (read-only, done 2026-11-01)

Upstream `FIREFOX_159_0_RELEASE` exists (`FIREFOX_159_0_BUILD1` is the same
release's build tag; the RELEASE tag is the one `UPSTREAM` uses).

- **Patches:** only 0001, 0004 and 0008 apply cleanly to 159.0. The other nine
  have rejected hunks (checked out of tree with `git apply --reject`, applied in order, so
  some later rejects cascade from earlier ones): 0002 (7 files, e.g.
  `shell/js.cpp`, `moz.build`, `vm/GlobalObject.cpp`, `vm/Runtime.h`), 0003
  (`jsfriendapi.h`, `vm/JSContext.cpp`), 0005 (`shell/js.cpp`), 0006 (7 files
  incl. `PortableBaselineInterpret.cpp`, `BaselineCacheIRCompiler.cpp`), 0007
  (`build/moz.configure/{libraries,toolchain}.configure`), 0009 (18 files incl.
  `Shape.cpp`, `NativeObject.*`, `RealmFuses.*`, `Interpreter.cpp`), 0010 (6
  files), 0011 (`tests/lib/jittests.py`), 0012 (`mfbt/RandomNum.cpp`). Upstream
  changed 88 of the files the patches touch that exist at 147.0.4. Compile breaks beyond the rejects
  are expected and unassessed. (An earlier version of this note said all 12
  applied cleanly; that was a checking error and is corrected here.)
- **Layout changes (certain):** opcodes added `CreateSuppressedError`,
  `AddDisposable`, `TakeDisposeCapability`; removed `IsGenClosing`,
  `CheckResumeKind`, `ForceInterpreter`; numbering shifted. CacheIR ops added
  and removed (e.g. added `DateNow`, `LinearizeString`; removed `ReturnFromIC`,
  which patch 0006 depends on). `Cell.h`, `Shape.h`, `JSObject.h` changed. The
  layout-change rule applies: NightMonkey first, then the queue PR that bumps
  `NIGHTMONKEY_PIN`. (Missed by this assessment and found during the work: 159
  also re-encoded the `Value` tags (`STRING` 0x06 to 0x0e, `SYMBOL` 0x07 to
  0x08, `PRIVATE_GCTHING` 0x08 to 0x07), which the opcode digest does not
  cover, and the removed and renumbered opcodes required
  `JSOP_SEMANTICS_VERSION` 2. Both were handled in NightMonkey #23.)
- **Not assessed:** security-fix delta in the JIT area; new test floors.

## Goals

1. A published `engine-v159.0-1` built from `FIREFOX_159_0_RELEASE` plus the
   queue, passing the same acceptance as `engine-v147.0.4-1` (snapshot
   round-trip, AOT and interpreter jit-test floors).
2. NightMonkey consumes it with its opcode table (and anything else
   layout-dependent) regenerated for 159.
3. New floors in `baseline/jit-floor.txt`, justified (fewer or more tests is
   explained, not just accepted).
4. A written list of what changed that matters to us (patch rebases made,
   upstream behaviour changes that moved tests).

## Non-goals

- Tracking every Firefox release. This is one bump; a cadence is a later
  decision.
- Changing what the patches do. Rebase only; behaviour changes go in their own
  PRs.
- Keeping 147 supported after the cutover beyond the existing release assets.
- Fixing NightMonkey #22 (AOT failures) here. If 159 changes those results,
  record it; do not fold the fix in.

## Anti-goals (would make this a failure even if CI is green)

- Silently lowering a floor, or excluding failing tests, to get green. A justified
  exclusion must record its reason, engine version and lane scope, and its effect
  on the measured floors. (Outcome: NightMonkey #23 added six AOT-only and twelve
  both-lane `ff159` exclusions, each with its reason, and the floors in #33 are
  measured with them applied, so green does not mean every upstream test ran.)
- Regenerated opcode tables landed in NightMonkey out of order with the pin
  (a window where `yurt` and the queue disagree about opcodes).
- Moving the `UPSTREAM` tag without the matching `commit`/`tree` check.

## Order of work (my call, matches what was agreed in chat)

1. **Spike build.** On a branch, set `UPSTREAM` to 159.0 and run the engine
   workflow (dry run, no tag). Output: the list of compile errors, nothing
   merged. This sizes the rebase.
2. **Rebase the queue** (one patch per fix, same series structure, regenerate
   `patches/`). Red/green discipline applies to anything with behaviour.
3. **NightMonkey change first** (superseded, see Outcome): the plan below was to
   regenerate opcode tables and `data/ics` against 159 and gate the consumer on
   `engine/ENGINE_RELEASE` with no dual build. What landed (NightMonkey #23): explicit
   `ff159` engine-version support (regenerated opcodes, Value-tag and magic-value
   changes, lowerings, runtime adaptations) with `ff147` still the default;
   `data/ics` was not regenerated.
   Original text: regenerate opcode tables and `data/ics`
   against 159; NightMonkey must still build against the 147 release until the
   cutover (my call: gate the consumer on `engine/ENGINE_RELEASE`, no dual
   build).
4. **Queue PR:** the rebased patches, new `UPSTREAM`, bumped `NIGHTMONKEY_PIN`
   (full gate).
5. **Floors:** run acceptance on 159, set floors from measured results, and
   explain differences from 12307/12494.
6. **Release:** dry run, then `engine-v159.0-1` (tag push is yours to
   authorise), then NightMonkey bumps `engine/ENGINE_RELEASE`.

## Constraints

- Build only on CI/EC2 (Firefox does not build locally).
- Org rules: draft PRs, red test first, follow-up commits only, dual review,
  merges only on explicit authorisation naming PR and head.
- A moved upstream tag must be rejected: `UPSTREAM` keeps `commit` and `tree`.

## Left to the builder

Exact patch-fix shapes, whether to split the spike into per-patch CI runs, and
how to stage the NightMonkey change so `yurt` stays green at every step.

## Open for the user

- Target `159.0` exactly, or wait for a later 159.0.x / 160 if one lands during
  the work? (My call: 159.0; bumping again is cheap once this one is done.)
- Release number: `engine-v159.0-1`. (My call.)

## Outcome (2026-11-03)

Done in NightMonkey #23 (merge `9d51f64`) and then this repository's #33 (merge
`91b6e92`), in that order (layout-change rule). The order of work above was not
followed step by step:

- **NightMonkey (#23):** `ff159` was added as a second engine version beside
  `ff147` (cargo feature plus `NIGHT_ENGINE_VERSION`; `ff147` stays the default
  until the release bump), rather than gating on `engine/ENGINE_RELEASE` with no
  dual build. Besides the regenerated opcode table it ports the 159 `Value` tag
  encoding (not in the assessment above), the resume protocol and the
  `JSOP_SEMANTICS_VERSION` 2 check. NightMonkey has no IC tables; `data/ics` was
  not regenerated (it is not built into the engine; see PROVENANCE.md).
- **Queue (#33):** the spike, the rebase, `UPSTREAM` at `FIREFOX_159_0_RELEASE`,
  `NIGHTMONKEY_PIN` `9d51f64` and the floors landed as one PR. 0001, 0004 and
  0008 applied unchanged, but 0001 still needed API fixes at compile time.
  Per-patch changes are in PROVENANCE.md ("Rebase onto Firefox 159.0"); review
  findings and dispositions are in #33's comments. The gate and
  `scripts/accept-engine.sh` select NightMonkey's engine version from
  `UPSTREAM`'s tag.
- **Floors:** aot 13451 / interpreter 13641 (`baseline/jit-floor.txt`), the shard
  sums of gate run 41325722684, confirmed at the pinned NightMonkey; about 1150
  more verified tests per lane than 147. 18 version-scoped exclusions
  (NightMonkey `tests/*-ff159.txt`: 6 AOT-only, 12 both lanes), each with its
  reason; all but one are tests 147 does not have (the exception,
  `typedarray/subarray-scalar-replace.js`, gained Atomics cases in 159).
- **Tracked, not fixed:** #34 (`setNeverGCThingFixedSlot` and `Date`),
  NightMonkey #24.
- **Release dry run (2026-11-03):** the first dry run on `main` built and packaged
  the 159 engine, then failed in `release-set prepare` because 159's mach records
  percent-encoded toolchain artifact URLs (`public%2Fbuild%2Fclang.tar.zst`); the fix is
  #35 (open when this was written). Nothing was published; the packaged-release
  acceptance and the snapshot round-trip on 159 did not run (skipped after the failure).
- **Not done yet (Goal 1):** `engine-v159.0-1` is not tagged. Remaining: a passing
  release dry run on `main` after #35 (must report 13451 / 13641, or a floor PR
  comes first), a tag ruleset on `engine-v*` and immutable releases, the tag push,
  then NightMonkey bumps `engine/ENGINE_RELEASE` and its default engine version.
