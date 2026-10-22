# yurt-firefox: SpiderMonkey as a patch queue

## Intent

`YurtOS/firefox` is a fork of the whole Firefox tree (about 1.0M commits, plus
mirrors of main/beta/release/ESR) that exists to carry one thing: a SpiderMonkey
(`js/`) engine with the changes NightMonkey needs. Measured against its base,
`FIREFOX_147_0_4_RELEASE` (`310a0cc30b21`, verified exactly the fork's merge
base), `origin/yurt` at `dff5cf534448` adds about 25k lines in 1,441 files:

- `js/src` hand-written changes (144 files) including the JS Streams builtin
  (`js/src/builtin/streams` + `js/public/Stream.h`, 55 files, ~16.8k lines,
  kept in the queue for byte identity and for the benchmark configs that enable
  `--enable-js-streams`; the shipping mozconfig does not, and see Notes), `js/public`,
  `js/moz.configure`, `js/xpconnect`;
- `build/moz.configure`, `mfbt/RandomNum.cpp` (Yurt musl), `modules/libpref`,
  `testing/web-platform/meta`;
- the collected IC corpus `js/src/ics` (1,232 files, 0.5 MB of blobs);
- vendored `third_party/weval` and `third_party/wizer` headers;
- a `dom/` slice (19 files, 227 lines: webidl/streams plumbing);
- agent, CI and docs files.

A fork makes every Firefox bump a history merge. The queue makes it a rebase of
about 25k lines, of which about 16.8k are the streams builtin; if upstream has
rewritten that subsystem, a bump is dominated by that one patch, so streams
stay as their own patches and conflicts stay local.
We replace it with a patch queue on an unmodified release tag, as `yurt-clang`
does for LLVM, and later publish the built engine so consumers do not rebuild
it. These are two separate changes with different risk, so the work is split
into two slices (below).

Alternatives considered: keep the fork and only pin releases (no bump benefit,
still carries the history); patch queue with source builds only (slice A);
patch queue plus packaged engine (slices A+B). We recommend A first, B second.

## Slices

**Slice A: the queue (this project's first deliverable).** Repo, patches,
pin, strict apply, tree identity, in-repo SpiderMonkey build, CI. Proves that
tag + queue == today's fork. No release a consumer may pin.

**Slice B: the consumable engine.** Relocatable package, release workflow,
NightMonkey switching from "clone firefox and build" to "download engine".
Starts after A is merged and has its own spec section below; no
`engine-v*` tag is published as a consumer pin before B's red tests exist.

## Goals

- `YurtOS/yurt-firefox` containing only our changes as ordered patches, the
  build scripts, CI, and agent docs.
- One supported Firefox version: the latest stable release tag. Moving to a
  newer stable is a rebase of the queue as one change.
- Reproducible: fresh clone of the pinned tag, apply, copy data, build with the
  repo's mozconfig, from a recorded tree identity.
- Comfortable day-to-day engine work (dev loop below).
- (Slice B) A published, checksummed, relocatable engine NightMonkey downloads.

## Non-goals

- The browser, DOM, workers or any non-engine product (no GUI in Yurt). The
  `dom/` slice and other named non-engine paths are excluded from the queue.
- Tracking Firefox main, beta or ESR. Stable release tags only.
- A release per Firefox version, or several versions' queues.
- Changing NightMonkey in slice A, with one named exception: a small separate
  PR in NightMonkey repointing the `engine.yml` source-build from the fork to
  this repo's `build-engine.sh` at a pinned queue commit (needed because the fork
  is frozen). The consumer switch to a downloaded package is slice B.
- Upstreaming (patches should be clean enough, but it is not a deliverable).

## Anti-goals

- A queue that drifts silently (fuzz, leftovers, a moved tag).
- Generated or corpus data stored as patches.
- A release nobody can rebuild, or whose acceptance check cannot fail.

## Test-source tree rule (applies to the gate and the repoint PR)

NightMonkey's `ci-suite.sh` runs `run-jit-tests.sh`/`run-jstests.sh` against
`$here/firefox`, i.e. the patched `js/src/jit-test/jit_test.py`, `jstests.py`
and `external-compiler/` tests, while `-DSPIDERMONKEY_DIST` supplies only
headers and libs. Therefore: the patched tag+queue+`data/ics` tree that produced
`SPIDERMONKEY_DIST` is placed at NightMonkey's `firefox/` path.
`build-engine.sh` at the pinned queue commit leaves that same tree at
`$GITHUB_WORKSPACE/firefox`, and both the gate and the `engine.yml` repoint use
it. Forbidden: an unmodified tag, the frozen fork after queue drift, or a
dist-only checkout.

## Slice A design

### Layout (my call)

```
UPSTREAM                    # key=value: url, tag, commit SHA, tree hash
patches/NNNN-*.patch        # flat, sorted; one supported version
data/ics/                   # IC corpus, copied into js/src/ics after patching
mozconfig                   # the one supported engine configuration
scripts/lib/patch-queue.sh  # only reader of UPSTREAM; the apply logic
scripts/build-engine.sh     # checkout -> apply -> data -> verify -> build
scripts/export-patches.sh   # dev loop: patched tree commits -> patches/
scripts/check-queue.sh      # fresh clone, strict apply, tree identity, fixtures
.github/workflows/ docs/ AGENTS.md CLAUDE.md
```

`UPSTREAM` schema: `url`, `tag`, `commit` (the tag's SHA; a moved tag fails),
`tree` (hash of the fully patched tree including `data/ics`).

### What is in the queue (decided)

Included: everything under `js/` (including streams), `build/moz.configure`,
`mfbt/RandomNum.cpp`, `modules/libpref`, `third_party/weval`,
`third_party/wizer`, `config/system-headers.mozbuild` (`system_error` for the WASI
system-wrapper generation). Excluded and named: `dom/` (all 19 files),
`testing/web-platform/meta` (browser-only WPT expectations; the engine build and
NightMonkey's lanes do not read them), `.github`, `.agents`, `docs/agents`,
`.claude/skills` (symlink to `.agents/skills`), `AGENTS.md`, `CLAUDE.md`. A leftover
computation over `tag..yurt` against the include and exclude lists must be empty;
`check-queue.sh` repeats it. The exclusion list is recorded in the repo and is the
only difference allowed in the migration equality check. Patch split is the
builder's call (build/WASI target; external compiler hooks and external slots;
streams; engine behaviour; vendored headers), authorship cannot
follow a thematic split of merged history, so each patch carries the dominant
author from `git log` over its files, `Co-authored-by` trailers for other
substantial authors, and a `PROVENANCE.md` maps patches to the source commits
in `YurtOS/firefox`. The musl hunks already in `yurt` (`JSONPrinter`, `RandomNum`) are
queue content; issue YurtOS/firefox#1 (native `wasm32-yurt-linux-musl` target)
moves over as a later patch/issue, not treated as landed.

### Apply and verify (two loops)

- **CI/reproduce**: fresh shallow fetch of the pinned tag, confirm its SHA,
  `git apply --index` (no `--3way`, `--reject`, `--ignore-whitespace` or
  `--unidiff-zero`; `git apply` has no fuzz, so the safeguards are the SHA
  check, the tree check, and failure on any reject), copy `data/ics`, **`git add -- js/src/ics`
  (that path only) so the corpus is in the index**, then compare `git write-tree` with
  `UPSTREAM` `tree`. A fixture fails if the corpus is dropped, so the hash
  cannot silently exclude it. Equality is tag + patches + corpus; the copy happens before the
  hash. A caller-supplied source tree is validated, never reset, cleaned or
  checked out.
- **Dev**: `git am --no-3way` on a scratch checkout so authors and messages
  round-trip; edit and commit normally; `export-patches.sh` uses the same apply -> copy -> add -> hash path, fails if any
  exported commit touches `js/src/ics`, and runs
  `git format-patch --binary` back into `patches/` and updates the tree hash.
  A fixture asserts the `git am` tree and the `git apply --index` tree are
  identical (EOL/whitespace config cannot make them diverge). `UPSTREAM.tree`
  changes with every queue change; concurrent PRs conflict on it, so CI
  regenerates and checks it and the rebase procedure is "re-run
  `export-patches.sh`".
- Fixture queue in `check-queue.sh`: apply -> edit/commit -> export -> fresh
  apply; two patches changing the same lines; one deleting a file added by the
  previous patch. All must pass. There is no per-hunk post-image check (later
  patches may rewrite earlier ones); a per-patch check is diagnostic only.

### Build

`build-engine.sh` prepares the tree and runs `./mach build` with the repo's
mozconfig (moved from NightMonkey's `spidermonkey/mozconfig`; NightMonkey keeps
its copy until slice B, then deletes it; benchmark variants in NightMonkey's
`configs/` remain source-built and are out of this repo's scope). Toolchain
bootstrap uses `mach artifact toolchain` against the **unpatched** pinned tag
(it needs no patches) for host clang and `sysroot-wasm32-wasi`, plus Rust 1.98.1
from `rust-toolchain.toml`. Taskcluster resolves those artifacts, so the repo
does not pin them by URL; instead the build records the resolved artifact
names and digests in the build manifest, and slice B's package pins those.

### IC corpus

Kept as data (`data/ics/`) for byte-identity, and its hash goes in the
manifest. Open fact the plan's first task must settle by experiment: does the
build read `js/src/ics` when `--enable-aot-ics` is off (as in the shipping
mozconfig), and is `GenerateCacheIRFiles.py`'s output sensitive to directory
read order? Outcomes: not read when off -> carrying it is only for
byte-identity and re-collection at a bump is needed only for configs that enable
AOT ICs; read -> the generator is made order-insensitive (sorted) by a patch
and the corpus affects output, so re-collection is mandatory at a bump.

### CI (slice A)

Every PR: `check-queue.sh` (including fixtures) and the engine build, on Linux
x86_64, CI and the EC2 box only (Firefox builds are not run on the laptop). Budget:
target under 90 minutes with a cached `~/.mozbuild` and a cached shallow clone
keyed by the pinned tag SHA, plus a cache for the objdir keyed by tag SHA, queue
hash and mozconfig hash. Smoke:
the built plain SpiderMonkey shell (`dist/bin/js`, a wasm32-wasi module) runs
under a pinned `wasmtime` (version and digest pinned in the repo, installed by
the workflow) as `wasmtime run --dir=. dist/bin/js -e 'print(6*7)'` and a
small script file; the output must be `42` and the exit status 0. The
in-process path (`js-inproc`, guest compiler, `wasm-jit-runner`) needs
NightMonkey's CMake build, which this repo does not have; it is exercised only
in migration acceptance (step 3, at the pinned NightMonkey SHA) and in slice B.

### Migration (slice A)

Record before any work: `YurtOS/firefox` `yurt` SHA (`dff5cf534448` at the time of
writing; do not export a stale local `yurt`), `FIREFOX_147_0_4_RELEASE` SHA,
NightMonkey `origin/yurt` SHA, and any branch still pinning
`bytecodealliance/firefox:wasi-ff147`; diff those revisions and record the
disposition of any difference.
1. Create `YurtOS/yurt-firefox` (explicit user approval first).
2. Export the delta against the tag into split patches + `data/ics`. Equality:
   the whole tree of tag + queue + data equals the recorded `yurt` SHA's tree,
   excluding exactly the named exclusion list. Anything else fails.
3. Build; verify against the baseline: same `dist` file list/layout, and
   NightMonkey's engine lane at its recorded SHA passes both jit-test lanes
   (nonempty, passing), local regressions, guest-option checks and the
   baseline/MIR-stress steps. Pin the baseline to a named CI run (log URL,
   NightMonkey SHA, engine SHA); counts alone do not identify one.
4. Freeze: take the export from the recorded SHA, re-diff against `yurt`'s tip
   before finishing, add any new commits as patches and **re-run step 3 after any such update**. **Cutover before freeze:** the
   NightMonkey `engine.yml` repoint PR (the named slice A exception; on
   NightMonkey `yurt` the workflow pins `YurtOS/firefox:yurt`, older branches
   `bytecodealliance/firefox:wasi-ff147`) is opened against the queue commit
   and must pass both lanes (jit-test, local regressions, guest-option checks,
   baseline/MIR-stress) building from that pinned queue commit **before** the
   fork is frozen. **Single source of truth:**
   once that PR is merged and green, `YurtOS/firefox` `yurt` is frozen (branch protection,
   README notice); engine changes go to the queue only. Until slice B,
   NightMonkey's source-build fallback builds from a checkout produced by this
   repo's `build-engine.sh` at a pinned queue commit, not from the fork.
5. Semantic gate after migration: a dispatch- and nightly-triggered workflow
   in **this repo** checks out NightMonkey at the pinned SHA and builds it with
   `-DSPIDERMONKEY_DIST=<queue-built dist>` (already accepted by NightMonkey's
   CMake, so no NightMonkey change), running both jit-test lanes against the
   queue head. Rollback: unfreezing the fork also reverts the repoint PR. If the queue proves wrong after the freeze, the user
   decides to unfreeze the fork (the freeze is branch protection, lifted by the
   user, not an agent). So a bad patch is caught before slice B. A queue PR
   that touches engine behaviour may also trigger it by label.
6. `YurtOS/firefox` is not archived until slice B's fallback works. I will ask
   before closing any issue or PR.

## Slice B design (spec detail required before its plan)

- **Package contract.** A real `SPIDERMONKEY_DIST` has `include/` as ~350
  producer-tree symlinks (one relative out of `dist/` for `js-config.h`), and
  `lib/*.a` (`libjs_static`, `libjsrust`, `libjsshell`, `libpure_virtual`) as
  relative symlinks out of `dist/` into the objdir. The package materializes
  every file under `include/**` and `lib/*.a`, rewrites `js-build-config.json`,
  and the packager fails if any symlink or absolute path points outside the
  archive. `include-private/` is already real files.
- **Also materialize** `dist/system_wrappers` (a json `include_dirs` entry
  NightMonkey prefixes with `SPIDERMONKEY_DIST`), and keep the non-path remainder
  of `cc`/`cxx` (`--target`, language standard, WASI driver args), which
  NightMonkey uses for both compile and link; provisioning clang and sysroot
  alone would drop them.
- **Config and toolchain.** NightMonkey's CMake takes `cc`/`cxx` (and
  `--sysroot`) from the config as `CMAKE_C(XX)_COMPILER` and flags, and prefixes
  `include_dirs`/`libraries` with `SPIDERMONKEY_DIST`. Contract chosen: the
  archive's config contains only package-relative fields; compilers and sysroot
  are not bundled and not read from the config; NightMonkey's CMake takes a
  provisioned `clang`/sysroot from explicit variables (pinned by URL and
  digest), with the archive's manifest recording the exact toolchain
  identities. This is a NightMonkey CMake change and is slice B's follow-up,
  with its own red test. The release asset is Linux x86_64 and CI/EC2 only; a
  Mac consumer needs a separate asset and is out of scope.
- **Test sources.** NightMonkey's jit-test/jstests lanes run the patched
  `jit_test.py`/`jstests.py` and `js/src/jit-test/tests/external-compiler/`.
  The release therefore ships a versioned test-source bundle (or a documented
  patched checkout) bound to the engine identity; "stop building Firefox" is
  not "stop obtaining Firefox test sources".
- **Red tests (committed first).** A packager contract test on a fixture dist
  (leftover absolute path or symlink out of the archive fails; missing
  `lib/*.a` fails). Then the acceptance: extract the archive in a different
  directory on a machine without the producer checkout or `~/.mozbuild`, build
  NightMonkey from it with provisioned toolchain, run both jit-test lanes. A
  check that can pass on the producer host proves nothing.
- **Order.** The NightMonkey consumer change (CMake taking the package plus
  provisioned toolchain, with its red test) lands first; the first release is
  gated on a NightMonkey SHA that contains it.
- **Release.** Tag `engine-v<firefox-version>-<n>`, asset
  `spidermonkey_<ver>-<n>-wasm32-wasi.tar.zst` + `.sha256` + manifest (Firefox
  tag/SHA, queue hashes, mozconfig, corpus hash, toolchain digests, test-source
  identity). Publishing is gated on the packaged artifact passing the
  relocated NightMonkey run at a pinned NightMonkey SHA (jit-test both lanes
  nonempty, plus a representative `main()` snapshot round-trip). The release
  workflow has `contents: write` only on the publish job, refuses asset
  overwrites, and requires the tag to be an ancestor of the default branch
  (copy `yurt-clang`'s `require-ref-on-main.sh`). Default branch: `main`.
- **NightMonkey follow-up.** `engine.yml` downloads the asset; the engine bump
  procedure also regenerates opcode tables (`scripts/gen_opcodes.py` from
  `vm/Opcodes.h`, CMake digest) and keeps its source-build fallback until the
  downloaded asset has been green on `origin/yurt`.
- **Visibility.** `YurtOS/firefox` and `YurtOS/nightmonkey` are public;
  `yurt-clang` and `yurt-ports` are private, so there is no precedent for
  either. Recommend public (MPL-licensed engine source, CI downloads without
  credentials); this is the user's decision when the repo is created. If it
  stays private, the NightMonkey repoint in slice A already needs a token for the
  cross-repo checkout (or the repo must be public before the repoint merges),
  and B must specify authenticated download.

## Notes on configurations

The shipping `spidermonkey/mozconfig` does not pass `--enable-js-streams`; the
ion, ion-jitdump, weval and native benchmark configs do, and ReadableStream
tests skip when the global is absent. Streams stay in the queue for byte
identity and those configs; the supported WASI lane does not necessarily
execute them. The migration records the SHA-256 of NightMonkey's
`spidermonkey/mozconfig` at the pinned NightMonkey SHA, and CI fails if this
repo's `mozconfig` differs from it until slice B deletes NightMonkey's copy.

## Queue changes after cutover

- NightMonkey pins a queue commit. A queue change that should reach NightMonkey
  is followed by a NightMonkey PR bumping that pin, which runs both lanes; the
  nightly gate is a backstop, not the only signal.
- A queue patch that changes opcodes or layout (`vm/Opcodes.h` feeds
  NightMonkey's generated tables) fails the pinned-SHA gate by design: the
  NightMonkey change merges first, then the queue PR bumps the gate's NightMonkey
  pin.

## Licensing

The repo carries Firefox's MPL-2.0 `LICENSE` text, the licence files for
`third_party/weval` and `wizer` inside their patches, and a top-level `NOTICE`
listing them; patches touching MPL files keep their file headers.

## Constraints

Org policy as in every YurtOS repo: red test committed first, no amend or
force-push of open-PR branches, draft PRs during review loops, merge only on
explicit instruction. Firefox builds are heavy: CI and the EC2 box, not the
laptop.

## Left to the builder

Exact patch split and commit messages, script details, tooling, workflow
structure, smoke script content.

## My calls to check

- Two slices; no consumer pin before slice B's red tests.
- Flat `patches/` with `UPSTREAM` (tag, SHA, tree hash).
- JS Streams stay in the queue; `dom/` and the named non-engine paths do not.
- IC corpus is data, copied and staged before the tree hash; the re-collection
  rule is decided by the plan's first task (the corpus experiment), which gates
  the patch split: a generator-sorting patch, if needed, is in the queue from
  the start.
- NightMonkey `engine.yml` repoint is the one slice A exception (own PR).
- `git apply --index` in CI, `git am --no-3way` for dev.
- Migration stays on 147.0.4; version bump is a later change.
- Public repo recommended; your decision at creation.
- Linux x86_64 asset only; benchmark mozconfigs stay source-built.
