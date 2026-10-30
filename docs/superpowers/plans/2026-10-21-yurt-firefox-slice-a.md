# yurt-firefox Slice A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `YurtOS/firefox` `yurt` fork with `YurtOS/yurt-firefox`, a strict patch queue on `FIREFOX_147_0_4_RELEASE` that builds the same SpiderMonkey WASI engine, and cut NightMonkey's source build over to it.

**Architecture:** Bash scripts around `git`: `UPSTREAM` pins tag, commit and patched-tree hash; `patches/*.patch` + `data/ics/` are applied to a fresh shallow clone with `git apply --index`; the resulting index tree must hash to `UPSTREAM.tree`. A dev loop uses `git am` + `git format-patch`. CI checks the queue, builds the engine, smoke-tests it, and a nightly gate runs NightMonkey's engine lane against the queue head.

**Tech Stack:** bash, git, GitHub Actions, Firefox `mach`/mozconfig, wasmtime, NightMonkey's CMake/`ci-suite.sh`.

**Spec:** `docs/superpowers/specs/2026-10-21-yurt-firefox-design.md` (committed as the repo's first file).

## Global Constraints

- Base: tag `FIREFOX_147_0_4_RELEASE` = commit `310a0cc30b21` (full SHA recorded in `UPSTREAM`; a moved tag must fail).
- Equality: `FIREFOX_147_0_4_RELEASE` + `patches/` + `data/ics` == the recorded `YurtOS/firefox` `yurt` tree (`dff5cf534448` when written), excluding exactly the named exclusion list and nothing else; leftover computation over `git diff --name-only <tag> <yurt>` must be empty.
- CI apply: `git apply --index --whitespace=nowarn` (the tree hash guarantees byte identity, and a context mismatch already fails apply; vendored and generated content may legitimately have trailing whitespace, so a whitespace failure would mean widening policy, never editing content); offsets are accepted (an offset-applied patch yields an identical tree, so the tree hash is the backstop, not a separate offset check); forbidden flags: `--3way`, `--reject`, `--ignore-whitespace`, `--unidiff-zero`. Corpus: copy `data/ics`, then `git add -- js/src/ics` (that path only), then `git write-tree`.
- Dev loop: `git am --no-3way`; export with `git format-patch --binary`; exported commits must not touch `js/src/ics`; the `git am` tree must equal the `git apply --index` tree.
- Included: all of `js/` (incl. `js/src/builtin/streams`, `js/public/Stream.h`), `build/moz.configure`, `mfbt/RandomNum.cpp`, `modules/libpref`, `third_party/weval`, `third_party/wizer`, `config/system-headers.mozbuild`. Excluded and named: `dom/` (19 files), `testing/web-platform/meta`, `.github`, `.agents`, `.claude/skills`, `docs/agents`, `AGENTS.md`, `CLAUDE.md`.
- Layout: `UPSTREAM` (keys `url`, `tag`, `commit`, `tree`), flat `patches/NNNN-*.patch`, `data/ics/`, `mozconfig`, `scripts/lib/patch-queue.sh`, `scripts/{build-engine,export-patches,check-queue,verify-migration,check-mozconfig-drift}.sh`, `NIGHTMONKEY_PIN` (created in Task 8), `baseline/`, `lists/`, `.gitignore` (ignores `firefox/`).
- `build-engine.sh` leaves the patched tree at `$GITHUB_WORKSPACE/firefox`; it is the tree NightMonkey's `ci-suite.sh` uses for `jit_test.py`/`jstests.py`. Forbidden test-source trees: unmodified tag, frozen fork after drift, dist-only.
- Toolchain bootstrap (`./mach artifact toolchain`) runs on the **patched** tree (patches touch `build/moz.configure` and `config/`, so resolution could differ on the bare tag).
- Smoke: `wasmtime run --dir=. dist/bin/js -e 'print(6*7)'` prints `42`, exit 0; `wasmtime` pinned by version and digest in the repo.
- Build budget target under 90 minutes with caches (`~/.mozbuild`, shallow clone keyed by tag SHA, objdir keyed by tag SHA + queue hash + mozconfig hash).
- Linux x86_64 only; Firefox builds on CI or on a Linux x86_64 build host, never the laptop. Wherever the plan says "the EC2 box" it means such a host; use the smallest type that does the job, stop it the moment the job is done and results are copied back, pull code from GitHub, and keep no secrets on it.
- Org policy (`docs/agents/org.md`): red test committed first; never amend or force-push an open-PR branch; draft PRs during review loops; merge only on explicit user instruction naming the PR, with `--match-head-commit`; ask before closing PRs/issues.
- Creating `YurtOS/yurt-firefox` needs the user's explicit go-ahead (Task 2). Freezing `YurtOS/firefox` is lifted only by the user.
- Commits end with the attribution lines the executing session is given (this planning session used `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and its own `Claude-Session:` URL); PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Licensing: MPL-2.0 `LICENSE`, `NOTICE` (lists `third_party/weval`, `wizer`), MPL file headers kept in patches.

## Review Focus

1. A corpus file missing, extra or unstaged: the tree hash must change (Task 4 fixture).
2. A patch whose context no longer matches: apply must fail; offset-only application is harmless because the tree hash is unchanged (Task 4).
3. Moved/force-updated upstream tag or shallow clone of the wrong ref: fails on commit mismatch (Task 4).
4. Overlapping patches (same lines) and a patch deleting a file added by the previous one: apply and export must round-trip (Tasks 4, 5).
5. `data/ics` entry order differing between copies (APFS vs ext4): output must not depend on it (Task 1 decides how).

## File Structure

- `UPSTREAM` — pin; only `scripts/lib/patch-queue.sh` reads it.
- `NIGHTMONKEY_PIN` — NightMonkey SHA used by the drift check and the gate.
- `baseline/` — `dist-files.txt` and the recorded baseline CI run (Task 7).
- `scripts/verify-migration.sh`, `scripts/check-mozconfig-drift.sh`.
- `.gitignore` — ignores `firefox/`.
- `scripts/lib/patch-queue.sh` — `pq_read_pin`, `pq_fetch`, `pq_apply`, `pq_tree`, `pq_classify` (include/exclude).
- `scripts/check-queue.sh` — fresh-clone check; `--fixtures` runs the self-tests against a synthetic upstream.
- `scripts/export-patches.sh`, `scripts/build-engine.sh`.
- `lists/include.txt`, `lists/exclude.txt` — path prefixes for `pq_classify`.
- `tests/` — `fixture-upstream.sh` (builds a tiny git repo with tagged commit), `test-*.sh`.
- `.github/workflows/queue.yml`, `engine.yml`, `gate.yml`.
- `docs/` (org policy copy, spec, plan), `AGENTS.md`, `CLAUDE.md`, `NOTICE`, `PROVENANCE.md`, `LICENSE`.

---

### Task 1: Corpus experiment (decides the patch split)

Done in a scratch checkout of `YurtOS/firefox` `yurt` before any repo exists; builds only on the EC2 box and only if code reading is inconclusive. Evidence goes in the spec.

**Files:** scratch only; results appended to the spec's "IC corpus" section.

**Interfaces:** Produces: decision `CORPUS_MODE` ∈ {`inert-when-off`, `sorted-patch-needed`, `order-insensitive`} used by Task 7 (patch split).

- [ ] **Step 1: Read `js/src/jit/GenerateCacheIRFiles.py` and `js/src/moz.build`/`js/src/jit/moz.build` for every reference to `ics`, `AOT_ICS`, `scandir`, `listdir`; record file:line.**
- [ ] **Step 2: Only if Step 1 is inconclusive: build twice with the shipping `mozconfig` (flag off), once with `data/ics` entries shuffled (copy in reverse and random order); compare generated headers (`obj-*/js/src/jit/*Generated*`) with `sha256sum`.** Expected: identical, else `CORPUS_MODE` is not `inert-when-off`.
- [ ] **Step 3: The weval config (`--enable-aot-ics`) is the case that matters: determine, by reading first and building if needed, whether its output differs by read order.** Expected result recorded verbatim.
- [ ] **Step 4: Write the decision and evidence into the spec; if a sorting patch is needed, note it as patch 0001 candidate.**
- [ ] **Step 5: Commit the spec change when the repo exists (Task 2).**

### Task 2: Create the repo (explicit user approval required)

- [ ] **Step 1: Ask the user for the go-ahead and visibility (public recommended; spec says if private the repoint needs a token).** Do nothing until given.
- [ ] **Step 2: `gh repo create YurtOS/yurt-firefox --<visibility> --description "SpiderMonkey patch queue on a Firefox release tag"`; default branch `main`; push an initial commit holding the spec, plan, `LICENSE`, org policy copy, `AGENTS.md`/`CLAUDE.md`.**
- [ ] **Step 3: Enable branch protection on `main` (no force-push). Verify with `gh api repos/YurtOS/yurt-firefox/branches/main/protection`.**

### Task 3: Fixture upstream and test harness (red)

**Files:** Create `tests/fixture-upstream.sh`, `tests/lib.sh`; Test: `tests/test-fixture.sh`.

**Interfaces:** Produces: `make_fixture_upstream <dir>` creates a git repo with files `js/a.txt`, `js/ics/README`, `other/b.txt`, one commit tagged `V1`; prints the tag's commit SHA. `run_test <name> <fn>` and `assert_eq/assert_fails` in `tests/lib.sh`.

- [ ] **Step 1: Write `tests/test-fixture.sh` asserting `make_fixture_upstream` yields tag `V1` whose tree contains `js/a.txt`.** Run: `bash tests/test-fixture.sh` Expected: FAIL (script missing).
- [ ] **Step 2: Implement the two helper files.**
- [ ] **Step 3: Run; expected PASS. Commit.**

### Task 4: `patch-queue.sh` apply + tree identity (red tests first)

**Files:** Create `scripts/lib/patch-queue.sh`, `UPSTREAM.example`; Test: `tests/test-apply.sh`.

**Interfaces:**
- Consumes: Task 3 helpers.
- Produces (bash functions, all take an explicit repo dir; none touch a caller's tree):
  - `pq_read_pin <upstream-file>` sets `PQ_URL PQ_TAG PQ_COMMIT PQ_TREE`.
  - `pq_fetch <dest>` shallow-fetches `PQ_TAG`, fails if `rev-parse HEAD != PQ_COMMIT`.
  - `pq_apply <worktree> <patches-dir> <data-ics-dir>`: guard (HEAD equals `PQ_COMMIT`, `git status --porcelain` empty, path is not the caller's repo toplevel; so it works on `pq_fetch`'s clone and `$GITHUB_WORKSPACE/firefox`); applies each `*.patch` in sorted order with `git apply --index --whitespace=nowarn` (no forbidden flags; any failure aborts); copies `data/ics/` over `js/src/ics/` (fixture: `js/ics/`; no `--delete`, since the tag already has `js/src/ics/README.md` and `remove-duplicates.py`), runs `git add -- js/src/ics`.
  - `pq_tree <worktree>` prints `git write-tree`.
  - Environment variable `PQ_ICS_PATH` (default `js/src/ics`) lets the fixture use `js/ics`.

- [ ] **Step 1: Write `tests/test-apply.sh` with these cases (each must fail first):**
  - `applies_clean_queue_and_tree_matches_pin`: queue of 2 patches + 2 corpus files; `pq_tree` equals pin's tree.
  - `rejects_moved_tag`: tag re-pointed after pin; `pq_fetch` exits non-zero.
  - `rejects_context_drift`: a patch with altered context fails with a non-zero status; a patch with trailing whitespace applies unchanged; a patch applying only with a line offset succeeds and yields the expected tree.
  - `corpus_in_hash`: deleting one corpus file or leaving it unstaged changes `pq_tree`.
  - `overlap_and_delete`: patch 2 edits lines added by patch 1; patch 3 deletes a file added by patch 2; final tree equals expected.
  - `forbidden_flags_absent`: no non-comment line in `scripts/` or `.github/workflows/` matches `--(3way|reject|ignore-whitespace|unidiff-zero)`.
  - `guard`: `pq_apply` refuses a tree whose HEAD is not `PQ_COMMIT`, a dirty tree, and the caller's repo toplevel; accepts a clean `pq_fetch` clone in a non-temp path.
- [ ] **Step 2: Run `bash tests/test-apply.sh`; expected FAIL for all.**
- [ ] **Step 3: Implement the five functions; shallow fetch via `git init` + `git fetch --depth 1 <url> tag <tag>` + `git checkout --detach FETCH_HEAD`.**
- [ ] **Step 4: Run; expected PASS (7 cases). Commit red tests and implementation as separate commits (tests first).**

### Task 5: Include/exclude census and `check-queue.sh`

**Files:** Create `lists/include.txt`, `lists/exclude.txt`, `scripts/check-queue.sh`; add `pq_classify` to `scripts/lib/patch-queue.sh`; Test: `tests/test-classify.sh`, `tests/test-check-queue.sh`.

**Interfaces:**
- Produces: `pq_classify <path>` prints `include` or `exclude` or exits 2 (unclassified); `check-queue.sh [--fixtures]` runs fresh clone, apply, tree compare, and `pq_leftover <tag-ref> <yurt-ref>` (unclassified paths in `git diff --name-only <tag> <yurt>`, must be empty; also asserts the `dom/` file count equals 19).

- [ ] **Step 1: Write `tests/test-classify.sh`: each Global Constraints include/exclude prefix classifies as stated (`config/system-headers.mozbuild` include, `.claude/skills` exclude, `testing/web-platform/meta/x.ini` exclude, `js/src/builtin/streams/a.cpp` include); `something/new.c` exits 2.** Expect FAIL.
- [ ] **Step 2: Write `tests/test-check-queue.sh --fixtures`: builds the fixture upstream, runs the Task 4 cases and the census; Task 6 later adds the dev-loop round trip to this runner.** Expect FAIL.
- [ ] **Step 3: Implement lists, `pq_classify` (longest-prefix match), `pq_leftover`, `check-queue.sh`.**
- [ ] **Step 4: Run both; expected PASS. Commit.**

### Task 6: Dev loop `export-patches.sh` (red first)

**Files:** Create `scripts/export-patches.sh`; Test: `tests/test-export.sh`.

**Interfaces:** `export-patches.sh <scratch-dir>` — creates the scratch checkout if absent (`pq_fetch` then `git am --no-3way patches/*.patch`, then copies the corpus **untracked**, listed in the scratch clone's `.git/info/exclude`, so plain `git commit`/`am`/rebase never see it); after the user commits edits, `export-patches.sh --write <scratch-dir>` runs `git format-patch --binary --no-signature --zero-commit --no-numbered --abbrev=12 <tag>..HEAD` into `patches/` (deterministic output), refuses if any commit touches `js/src/ics`, recomputes the tree via the same apply → copy → add path from a fresh clone (the only place the corpus is staged) and rewrites `UPSTREAM` `tree`.

- [ ] **Step 1: Write `tests/test-export.sh` cases:** (a) apply → edit/commit → export → fresh `pq_apply` tree == pin; (b) authors and subjects survive; (c) a commit touching `js/src/ics` is refused; (d) the `git am` tree, after staging `data/ics` on that side, equals the `git apply --index` tree for the same queue; (e) a binary file hunk survives; (f) re-exporting unchanged commits yields byte-identical patches; (g) the dev-loop round trip is added to `check-queue.sh --fixtures`. Expect FAIL.
- [ ] **Step 2: Implement; run; expected PASS. Commit.**

### Task 7: Migration export (the real queue)

Runs on the EC2 box with `YurtOS/firefox` and `FIREFOX_147_0_4_RELEASE` fetched.

**Files:** Create `patches/0001-…` ..; `data/ics/*`; `UPSTREAM`; `PROVENANCE.md`; `NOTICE`.

- [ ] **Step 1 (red): add `scripts/verify-migration.sh <yurt-sha>` which asserts leftover empty and that the queue tree equals the yurt tree with every excluded path reset to its tag-state content (temporary index: `read-tree <yurt-sha>`, then `update-index` each excluded path back to the tag's blob, or removal if absent at the tag); the red test covers a `dom/` change in yurt (must not count as a difference) and a non-excluded change (must). Run it with an empty queue.** Expected: FAIL listing the delta.
- [ ] **Step 2: Record SHAs in `PROVENANCE.md`, and capture the baseline while the old build still exists: the named NightMonkey `origin/yurt` engine CI run (URL, NightMonkey SHA, engine SHA, jit-test totals) and the `dist` file list of that build (`find . | sort`, stored as `baseline/dist-files.txt`). Also record the `yurt` SHA (dff5cf534448 or tip), the tag commit, NightMonkey `origin/yurt` SHA, and any branch pinning `bytecodealliance/firefox:wasi-ff147`; diff `bytecodealliance/firefox:wasi-ff147` against `yurt` and record the disposition.**
- [ ] **Step 3: Split the `js/` delta by concern into patches (streams separate; WASI/build; external compiler hooks/external slots; engine behaviour; weval/wizer headers; musl hunks; `config/system-headers.mozbuild`); add a sorting patch first if Task 1 said `sorted-patch-needed`. Each patch: dominant author, `Co-authored-by` trailers, mapped in `PROVENANCE.md` to source commits. Copy `js/src/ics` into `data/ics`.**
- [ ] **Step 4: Run `verify-migration.sh`; expected PASS (tree identical, leftover empty). Write the final `tree` into `UPSTREAM`.**
- [ ] **Step 5: Re-diff `yurt` tip; if it moved, add new commits as patches and re-run Step 4. Commit.**

### Task 8: `build-engine.sh`, `mozconfig`, drift check

**Files:** Create `mozconfig`, `scripts/build-engine.sh`, `scripts/check-mozconfig-drift.sh`; Test: `tests/test-build-engine.sh` (dry-run mode).

**Creates `NIGHTMONKEY_PIN`** (one line: the NightMonkey SHA used for qualification; Task 11 reuses it).

**Interfaces:** `build-engine.sh [--workdir DIR] [--dry-run]` — `pq_fetch` + `pq_apply` into `${GITHUB_WORKSPACE:-$PWD}/firefox`, runs toolchain bootstrap (`./mach artifact toolchain` on the patched tree for host clang and `sysroot-wasm32-wasi`), then `MOZCONFIG=mozconfig ./mach build`; writes `build-manifest.json` (tag, commit, queue hash, `data/ics` hash, mozconfig sha256, resolved toolchain artifact names and digests, Rust version). `--dry-run` prints the steps and runs only fetch/apply. Drift check: `sha256sum mozconfig` equals NightMonkey's `spidermonkey/mozconfig` at the SHA in `NIGHTMONKEY_PIN` until slice B; `queue.yml` runs it (checking out NightMonkey at that pin).

- [ ] **Step 1: Write tests: dry-run on the fixture creates the tree at the given workdir, writes the manifest keys listed, and aborts on a caller-supplied non-empty dir; drift check fails when the two mozconfigs differ.** Expect FAIL.
- [ ] **Step 2: Implement; copy `mozconfig` from NightMonkey `spidermonkey/mozconfig` at its pinned SHA.** Run tests; expected PASS.
- [ ] **Step 3: On EC2: run the real build; record time; verify `dist/bin/js` exists and is a wasm module (`file`, `wasmtime run`); adjust the smoke command in the plan/spec if not. Commit.**

### Task 9: CI workflows (queue check + build + smoke)

**Files:** Create `.github/workflows/queue.yml`, `.github/workflows/engine.yml`; Test: `actionlint` and `tests/test-workflows.sh`.

**Interfaces:** `queue.yml` (every PR, ubuntu-24.04): `scripts/check-queue.sh --fixtures` then `scripts/check-queue.sh`. `engine.yml` (every PR and `push` on `main`, which seeds the caches): caches per Global Constraints (objdir key also includes the Rust and toolchain versions and the runner image; `main` populates caches so PRs can read them; if the total exceeds the 10 GB cap, cache `~/.mozbuild` and the clone only and record the true cold-build time), `scripts/build-engine.sh`, `wasmtime` (pinned version+digest) smoke printing `42`, upload `build-manifest.json`.

- [ ] **Step 1: Write `tests/test-workflows.sh` asserting both workflows exist, pass `actionlint`, pin actions by SHA, and contain the smoke command verbatim.** Expect FAIL.
- [ ] **Step 2: Implement workflows; run tests; open a draft PR to exercise CI; expected both jobs green, budget measured (< 90 min target).**

### Task 10: Baseline qualification

On EC2: build the queue engine and compare to the baseline recorded in Task 7 (`baseline/` and `PROVENANCE.md`: the named CI run's log URL, NightMonkey SHA, engine SHA, and the `dist` file list).

- [ ] **Step 1: Compare `dist` file list/layout to the baseline's `dist` (`diff <(cd dist; find . | sort)`), expected identical modulo documented differences.**
- [ ] **Step 2: Check out NightMonkey at the pinned SHA; with the queue tree at `firefox/` run `scripts/ci-suite.sh` jit-test (AOT strict and interpreter lanes), local regressions, guest-option checks and baseline/MIR-stress steps with `-DSPIDERMONKEY_DIST` from the queue build. Expected: all green; counts recorded against the baseline run.**
- [ ] **Step 3: Record results in `PROVENANCE.md`; stop the EC2 box when idle.**

### Task 11: Semantic gate workflow

The gate runs the two jit-test lanes only (intentionally narrower than Task 10, which also runs local regressions, guest-option checks and baseline/MIR-stress once at qualification).

**Files:** Create `.github/workflows/gate.yml`; Test: `tests/test-workflows.sh` (extend).

**Interfaces:** triggers `workflow_dispatch`, nightly `schedule`, PR label `gate`. Steps: build engine via `build-engine.sh` into `$GITHUB_WORKSPACE/firefox`, check out NightMonkey at `NIGHTMONKEY_PIN` (a file `NIGHTMONKEY_PIN` in this repo), build with `-DSPIDERMONKEY_DIST=<queue-built dist>`, run both jit-test lanes with the harness from `$GITHUB_WORKSPACE/firefox`; nonempty passing results required (use NightMonkey's `scripts/check-test-log.py`).

- [ ] **Step 1: Extend the workflow test: gate exists, has the three triggers, references `NIGHTMONKEY_PIN`, and never references the unmodified tag or `YurtOS/firefox` as a source of the test tree.** Expect FAIL, then implement; expect PASS.
- [ ] **Step 2: Dispatch once; expected green. Document the layout-change rule (NightMonkey change merges first, then bump `NIGHTMONKEY_PIN`) and the pin-bump procedure in `AGENTS.md`.**

### Task 12: NightMonkey repoint PR and freeze

Two repos; each change is its own PR. The NightMonkey PR follows NightMonkey's own `AGENTS.md` (red test first, draft while in review).

**Files (NightMonkey):** Modify `.github/workflows/engine.yml` (source of `firefox/` becomes `YurtOS/yurt-firefox` at a pinned queue commit, built by its `scripts/build-engine.sh`); Test: its workflow lint plus the full engine lane.

- [ ] **Step 1 (red): in NightMonkey add a workflow check that fails while `FIREFOX_REPO` is `YurtOS/firefox`.**
- [ ] **Step 2: Repoint; the PR runs both lanes (jit-test, local regressions, guest-option checks, baseline/MIR-stress) building from the pinned queue commit; expected green.**
- [ ] **Step 3: User merges NightMonkey's PR (explicit instruction naming the PR, `--match-head-commit`).**
- [ ] **Step 4: Only then ask the user to freeze `YurtOS/firefox` `yurt` (branch protection + README notice pointing to the new repo). Do not archive; ask before closing any issue or PR; issue #1 moves/re-files.**
- [ ] **Step 5: Re-run Task 10 if `yurt` moved after the export (re-qualify after any late addition).**

---

## Self-review

- **Spec coverage:** layout, pin, apply loops, fixtures, census, mozconfig move + drift, IC experiment (Task 1), build + manifest, CI + smoke, migration with baseline and equality, cutover before freeze, gate, rollback (user lifts), licensing (NOTICE in Task 7), test-source tree rule (Global Constraints, Tasks 10–12). Slice B is out of scope by design.
- **Type consistency:** `pq_*` names identical across Tasks 4–8; `PQ_ICS_PATH` only in tests.
- **Proportion:** the plan is deliberately command-level; patch contents are not written here.
- **Open facts to settle during execution:** `dist/bin/js` runnable under wasmtime (Task 8); corpus mode (Task 1); build budget (Task 9).
