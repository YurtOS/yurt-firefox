# Slice C: move the engine from Firefox 147.0.4 to 159.0

Issue: #29. Status: draft for approval. Predecessors: slice A (queue), slice B
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

- **Patches:** all 12 apply to 159.0 with `git apply --reject` and no rejected
  hunks. Applying cleanly is not building: upstream changed 88 of the files
  the patches touch (`jit/CacheIR*`, `CacheIRCompiler.cpp`, `shell/js.cpp`,
  `gc/GC.cpp`, `jsfriendapi.h`, `build/moz.configure/*`). Compile breaks are
  expected and unassessed.
- **Layout changes (certain):** opcodes added `CreateSuppressedError`,
  `AddDisposable`, `TakeDisposeCapability`; removed `IsGenClosing`,
  `CheckResumeKind`, `ForceInterpreter`; numbering shifted. CacheIR ops added
  and removed (`DateNow`, `DateParse`, `LoadFixedSlotFromOffsetResult`,
  `LinearizeString`, ...). `Cell.h`, `Shape.h`, `JSObject.h` changed. The
  layout-change rule applies: NightMonkey first, then the queue PR that bumps
  `NIGHTMONKEY_PIN`.
- **Not assessed:** security-fix delta in the JIT area; new test floors.

## Goals

1. A published `engine-v159.0-1` built from `FIREFOX_159_0_RELEASE` plus the
   queue, passing the same acceptance as `engine-v147.0.4-1` (snapshot
   round-trip, AOT and interpreter jit-test floors).
2. NightMonkey consumes it with its opcode and IC tables regenerated.
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

- Silently lowering a floor, or excluding failing tests, to get green.
- Regenerated opcode tables landed in NightMonkey out of order with the pin
  (a window where `yurt` and the queue disagree about opcodes).
- Moving the `UPSTREAM` tag without the matching `commit`/`tree` check.

## Order of work (my call, matches what was agreed in chat)

1. **Spike build.** On a branch, set `UPSTREAM` to 159.0 and run the engine
   workflow (dry run, no tag). Output: the list of compile errors, nothing
   merged. This sizes the rebase.
2. **Rebase the queue** (one patch per fix, same series structure, regenerate
   `patches/`). Red/green discipline applies to anything with behaviour.
3. **NightMonkey change first:** regenerate opcode tables and `data/ics`
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
