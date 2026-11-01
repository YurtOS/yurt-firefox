# Provenance of the patch queue

The queue was exported once from the `YurtOS/firefox` fork (slice A migration).
This file records what it was exported from and where each patch came from.

## Recorded revisions (2026-10-22): slice A, Firefox 147.0.4 (historical)

This section and everything below it up to the next level-2 heading about 159 describe the
export of the queue at Firefox 147.0.4. `UPSTREAM` has since moved to 159.0; see "Rebase onto
Firefox 159.0" at the end of this file.

| What | Value |
|---|---|
| Base tag | `FIREFOX_147_0_4_RELEASE` = `310a0cc30b21a4ddf7f0826a67f73bed6b050349` (served at that commit by https://github.com/mozilla-firefox/firefox; it is the fork's merge base) |
| Source | `YurtOS/firefox` `yurt` = `dff5cf5344484c56babebf9b2495c400c03e3538` (checked with `git ls-remote` at export time; the stale local `yurt` branch was not used) |
| NightMonkey | `YurtOS/nightmonkey` `origin/yurt` = `ffb918ff3c26415f69d877f47e622cdf3196ed1a` (merged PR #8) |
| Baseline CI run | https://github.com/YurtOS/nightmonkey/actions/runs/39621345954, engine `dff5cf534448`; details in [baseline/ci-run.md](baseline/ci-run.md) |
| Queue tree | `092cc9d0409ebc66acc52def28a2ed8f30a92b5d` (`UPSTREAM` `tree`) |

## Equality

`scripts/verify-migration.sh dff5cf5344484c56babebf9b2495c400c03e3538` (with
`PQ_YURT_REPO` a clone of `YurtOS/firefox`) passes: tag + `patches/` +
`data/ics` equals the `yurt` tree with each excluded path reset to its tag
content. `git diff --name-only <tag> <yurt>` has 1,441 paths: 1,396 included
(1,231 of them the corpus under `js/src/ics`, carried as `data/ics`), 45
excluded (19 under `dom/`), none in neither list.

## Qualification (Task 10, 2026-10-22)

Full record in [baseline/qualification.md](baseline/qualification.md). The
`dist` file list of the fork build (A, built with NightMonkey's
`scripts/build-spidermonkey.sh` at `ffb918ff3c26`) is identical to the queue
build's (B, `scripts/build-engine.sh`): 2,590 entries, `baseline/dist-files.txt`.
Built at the same path, `lib/*.a` and `bin/js` are byte-identical (sha256 in
the record); built at different paths they differ only by embedded paths.
NightMonkey at `ffb918ff3c26` against B (queue tree as `firefox/`): guest tier
options all PASS, local 131/0 on both lanes, baseline and MIR-stress tiers
131/0, jit-tests 12906 passed / 0 failed (aot strict) and 13095 passed / 0
failed (interpreter), the same totals as the baseline CI run.

## Excluded paths

As in `lists/exclude.txt`: `dom/` (19 files of webidl/streams browser plumbing,
from `71f34b31f32f`), `testing/web-platform/meta` (12 files, from
`71f34b31f32f`), `.github` (fork CI: `e4571c207586`, `6a87a98c8aad`,
`6ce2bf5bb46d`), `.agents`, `.claude/skills`, `docs/agents`, `AGENTS.md`,
`CLAUDE.md` (fork agent guidance: `e4f1ee885027`, `5973320d3cf8`,
`f71f87a3c0d7`).

## Patches

Source history: the 33 non-merge commits of `310a0cc30b21..dff5cf534448`.
Each patch is the union of path-carved pieces of source commits
(`git diff <c>^1 <c> -- <paths>`, never split by hunk), limited to
`lists/include.txt` and never including `js/src/ics`. Every included path of
every source commit is in exactly one piece, and for each file the pieces stay
in history order. The merge commits add no content of their own (the replay
reproduces the `yurt` tree exactly). Author: the author with the most changed
lines in the patch, with the date of their latest source commit in it; every
other author of a piece gets a `Co-authored-by` trailer.

| Patch | Lines | Author (co-authors) | Source commits (paths) |
|---|---|---|---|
| 0001 Add the JS Streams builtin implementation | 17,239 | Trevor Elliott (Till Schneidereit) | `71f34b31f32f` (`js/src/builtin/streams`, `js/public/Stream.h`); `27c3537e91cf` |
| 0002 Wire the JS Streams builtin into the engine and shell | 2,391 | Trevor Elliott | `71f34b31f32f` (other included paths: `js/`, `modules/libpref`, `js/xpconnect`) |
| 0003 Add JSAPI to reset the Math.random seed and to query pending jobs | 102 | Till Schneidereit | `737de343a9be`, `51f29d2cfcf6` |
| 0004 Vendor the weval and wizer headers | 1,106 | Chris Fallin | `1e77c0d2599e` (`third_party/wizer`), `18566eacce39` (`third_party/weval`) |
| 0005 JS shell on WASI: add basic Wizer integration | 389 | Chris Fallin | `1e77c0d2599e` (other paths) |
| 0006 PBL: add weval annotations | 2,339 | Chris Fallin | `18566eacce39` (other paths) |
| 0007 Build fixes for the WASI target and current toolchains | 129 | Chris Fallin (Tomasz Andrzejak) | `f7d679b00ba0`; `164f660a3602` (`build/moz.configure`) |
| 0008 Add system_error to the system headers list | 27 | Chris Fallin | `164f660a3602` (`config/system-headers.mozbuild`) |
| 0009 Add hooks to allow for an external compiler | 2,492 | Chris Fallin | `164f660a3602` (other paths), `f6cb6f9ddc21` |
| 0010 Add external slot and object fuse compiler hooks | 1,391 | sunnymar (`@smarcd`) | `95b9f31de072`, `a1d957648b20`, `a2e0c4dc9fd0`, `ff2bc3770cef`, `ec6c586a7e18`, `1df0e02d6c95`, `65e96085dce8`, `2b415d0e5bc5`, `a92a5b2dc24c`, `e57dacabd598`, `f850071eda00` (all but `js/src/tests/lib`) |
| 0011 jit-test harness: fail interrupted runs and mismatched expected errors | 96 | sunnymar (`@smarcd`) | `b6bf683e9267`, `0c38bedd68b3`, `f1715f0fe944`, `04031a147589` (`js/src/tests/lib`) |
| 0012 Build fixes for wasm32-yurt-linux-musl (Yurt) | 78 | sunnymar (`@smarcd`) | `08e2eae2c260`, `c0fb41d8ebcd` (the musl hunks: `JSONPrinter`, `RandomNum`) |

Each patch keeps the author attribution of its source commit.

Source commits with no queue content: `34ecc9174ff4` (the IC corpus, now
`data/ics`), and the excluded-path commits listed above.

`data/ics/` is `js/src/ics` at `dff5cf534448` (1,232 files, including the two
executable helper scripts; one of them, `remove-duplicates.py`, is unchanged
from the tag).

No sorting patch for `GenerateCacheIRFiles.py`: the migration must be
byte-identical to `yurt`, and the shipping configuration leaves
`--enable-aot-ics` off, so the corpus is not read there. Making the generator
order-insensitive is a later queue change.

## bytecodealliance/firefox:wasi-ff147

`wasi-ff147` is at `f0c060c52260d41fc631a14cda05372ad1c2cbe1`, the merge of
cfallin's external-compiler PR into the fork. GitHub's compare of
`wasi-ff147...YurtOS:firefox:dff5cf534448` reports `ahead 23, behind 0` with
that commit as merge base: everything on `wasi-ff147` is in `yurt` and so in
this queue (patches 0001-0009). Disposition: nothing to carry; no difference.

NightMonkey branches that still name it (2026-10-22): `ci/project-gates`
(`2be1ac5abef6`) pins `bytecodealliance/firefox` `wasi-ff147` in `engine.yml`;
`ci.yml` on `cfallin/nightmonkey`, `chore/agent-guidance`,
`claude/jit-dynamic-loading-prs-su4jqh`, `fix/generated-quality-gates` and
`yurt-host` mentions `bytecodealliance/firefox` or `wasi-ff147`. NightMonkey `yurt` pins `YurtOS/firefox` `yurt`.

## Rebase onto Firefox 159.0 (slice C, 2026-11-01)

| What | Value |
|---|---|
| Base tag | `FIREFOX_159_0_RELEASE` = `9a2dc53c369c7ae5172018b35988e1d2ffeff402` |
| Queue tree | `dd0c671f0e78fa0a4ba0fb09d76c65ee246f65d6` (`UPSTREAM` `tree`, computed with `scripts/lib/patch-queue.sh` `pq_apply`/`pq_tree` over this queue plus `data/ics`) |
| NightMonkey | `YurtOS/nightmonkey` `yurt` = `9d51f6430ef3ccaa16c51782f8e4a0a1afdafda5` (merge of #23, the `ff159` engine version) |
| Design | `docs/superpowers/specs/2026-11-01-slice-c-firefox-159-design.md` (PR #32); issue #29 |
| Gate evidence | run 41325722684 on PR #33: all four shards, both lanes, 0 failures, with NightMonkey `ff159` |

The twelve patches were rebased with their intent unchanged; nine of them had rejected hunks on 159
and three applied as they were. What moved, and what was added to keep behaviour:

- **0002** streams: re-added the `byteLength` atom 159 deleted; adapted to the removed
  `ShadowRealm.h`, `weakCaches_` and the `JSAPIRuntimeTest` rename.
- **0003** `HasJobsPending` now answers `JS::HasAnyMicroTasks(cx)` (159 removed `JobQueue::empty`).
- **0005** a plain `return 1;` in `ShellMain` became `AsVariant(1)` (explicit `Variant` constructor).
- **0006** PBL: 159 removed `ReturnFromIC` in favour of a `PblReturn` pseudo-op; the reader is built
  with a real end pointer (`code + stubInfo->codeLength()`).
- **0007** mostly superseded by 159 (it already skips the pthread check on WASI and renames the
  clang target); the `target_triple` logic is kept.
- **0009** the external word moved into `shadow::NativeObject`; the swap hook moved to
  `ProxyObject::swap`, `assignSource` to `ExclusiveSourceData`; the foreign-generator hook is also
  applied at the top of `js::ResumeGenerator` (159 resumes async code from C++, skipping the
  interpreter's `JSOp::Resume`), with recursion and Debugger no-execute checks and module
  generators excluded; `JSOP_SEMANTICS_VERSION` is 2; the private-header exporter joins the
  list-valued `CC`/`CXX` of 159 back into one command string.
- **0010** `PermutedSlots` moved from `ObjectFlag` bit 18 to 19 (159 took 18); two spread guards in
  `CopyDataPropertiesNative` (159 added a copy fast path); `NativeObjectSlotSpanForTracing` is
  permuted-slot aware with a tracing-safe walk.
- **0011** shrank: 159 already fixes the expected-error status upstream.
- **0012** only the arc4random condition is kept.

Reviewed in three rounds by Claude and Codex (each read-only), which found, among others, the
`ReturnFromIC` reader end pointer, the async-resume hook bypass, module generators reaching the
hook, and an unsafe flag read on the concurrent marking thread. `data/ics` is still the corpus from
the 147 era; it is not built into this engine (no `--enable-aot-ics`) and is carried only so the
tree hash stays byte-identical.

