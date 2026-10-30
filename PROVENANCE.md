# Provenance of the patch queue

The queue was exported once from the `YurtOS/firefox` fork (slice A migration).
This file records what it was exported from and where each patch came from.

## Recorded revisions (2026-10-22)

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

sunnymar appears under two e-mail addresses in the source; each patch keeps
the address of its source commits.

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
