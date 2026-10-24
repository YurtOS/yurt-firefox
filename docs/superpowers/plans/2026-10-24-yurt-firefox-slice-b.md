# yurt-firefox Slice B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** yurt-firefox publishes checksummed, relocatable engine releases; NightMonkey builds from a downloaded release instead of building Firefox.

**Architecture:** A packager turns the queue-built `dist/` into a relocatable archive: symlinks materialized, `js-build-config.json` stripped of every producer path. A release workflow builds, packages, proves the archive on a clean runner against a NightMonkey that already understands packages, and only then publishes the engine, the test sources and the two toolchain archives together. NightMonkey's CMake takes a provisioned toolchain root from explicit variables; its jit/jstests lanes take test sources from a bundle shipped with the release. NightMonkey keeps its source-build path (and `engine/QUEUE_PIN`) until the downloaded asset has been green on `origin/yurt`.

**Tech Stack:** bash and python3 (stdlib `unittest` in NightMonkey, plain bash tests in yurt-firefox), GitHub Actions, CMake, `tar` + `zstd`, `gh release`.

**Spec:** `docs/superpowers/specs/2026-10-21-yurt-firefox-design.md`, section "Slice B design". Where the spec leaves a choice, this plan records it as a **Call** for review to challenge.

## Global Constraints

- Linux x86_64 only for the release assets (CI and EC2).
- Every red test is committed before the fix it targets; a failure-injection or mutation step proves each check can fail. Follow-up commits only; never amend or force-push an open PR branch.
- Firefox builds run on CI or on EC2 via `/Users/sunny/work/yurtos/bin/ec2slot`, never on the laptop. Packager and bundle tests use a **fixture dist/tree**, not a real build.
- Workflows: top-level `permissions: contents: read`, every action pinned by full SHA with a version comment, `persist-credentials: false`, no `pull_request_target`/`workflow_run`, no `secrets.`. Only the `publish` job of `release.yml` may have `contents: write`.
- No consumer pins an `engine-v*` tag before the packager, relocation and acceptance red tests exist and pass.
- Merge authority is the user's (`docs/agents/org.md`). Open PRs as drafts; dual Claude + Codex review each round.
- `YurtOS/yurt-firefox` is public (checked with `gh repo view`; the spec left visibility to the user at creation): CI downloads need no credentials.
- Tag `engine-v<firefox-version>-<n>` (first: `engine-v147.0.4-1`). Release assets: `spidermonkey_<ver>-<n>-wasm32-wasi.tar.zst`, `spidermonkey_<ver>-<n>-testsrc.tar.zst`, `spidermonkey_<ver>-<n>-toolchain-clang.tar.zst`, `spidermonkey_<ver>-<n>-toolchain-sysroot.tar.zst`, one `.sha256` each, and `MANIFEST.json`; plus `spidermonkey_<ver>-<n>-jstests.tar.zst` (+ `.sha256`), which **every release includes** (the nightly full-jstests job needs it; `release.yml`'s build runs `package-test-sources.sh --jstests` and the 1.9 GiB check covers it). Consumers fetch it only when full jstests are requested.

## Review Focus

- A leftover producer path in any text file of the archive (including `include-private/js-build-config.json`: `cc`, `cxx`, `cxx_base_flags`, `ar`, `topsrcdir`, `topobjdir`) must fail the packager. Binaries (`lib/*.a`, `bin/js`) embed the workdir and are exempt from the text scan; "relocatable" means config, headers and the link, not byte identity.
- An archive that passes on the producer host but not on a clean runner: the acceptance run is the gate, and it must be able to fail (build fails, a lane fails, results below the floor, snapshot round-trip broken).
- Test sources that cannot start the harness, or do not match the engine.
- A release overwritten, re-tagged after publish, or published from a branch dispatch or a tag not on `main`.
- Opcodes: `include-private/vm/Opcodes.h` must be byte-identical in the package.
- Toolchain URLs from Taskcluster expiring: consumers must not depend on them.

## File structure

yurt-firefox: `scripts/package-engine.sh`, `scripts/package-test-sources.sh`, `scripts/lib/package-contract.sh`, `scripts/accept-engine.sh`, `scripts/require-ref-on-main.sh`, `.github/workflows/release.yml`, `.github/workflows/engine.yml` (gains `workflow_call`), `tests/fixture-dist.sh`, `tests/test-package-engine.sh`, `tests/test-package-test-sources.sh`, `tests/test-accept-engine.sh`, `tests/test-release-workflow.sh`, `baseline/jit-floor.txt`, `RELEASE_REQUIRES_NIGHTMONKEY` (one line: the NightMonkey `yurt` commit containing N1/N1b). **Every new `tests/test-*.sh` is appended to the list at `scripts/check-queue.sh:22-23` in the same task that creates it, with a step proving a failing case fails the fixtures lane.**
NightMonkey: `CMakeLists.txt`, `scripts/tests/test_cmake_dist.py`, `scripts/ci-suite.sh`, `scripts/run-jit-tests.sh`, `scripts/run-jstests.sh`, `scripts/tests/test_ci_suite.py`, `.github/workflows/engine.yml`, `scripts/check-engine-source.sh` + `scripts/tests/test_check_engine_source.py`, `engine/ENGINE_RELEASE` (new; `engine/QUEUE_PIN` stays), README/AGENTS recipes.

## Order

1. **N1, N1b** NightMonkey consumer (toolchain root and test-source variables; snapshot round-trip script). Merge, then bump `NIGHTMONKEY_PIN` (PR labeled `gate`) to a `yurt` commit containing both; write that SHA to `RELEASE_REQUIRES_NIGHTMONKEY`.
2. **Y1 -> Y2 -> Y3 -> Y4 -> Y5** yurt-firefox packager, test bundle, acceptance script and floor, `engine.yml` `workflow_call`, release workflow.
3. First release `engine-v147.0.4-1` (the user decides to push the tag), gated by the relocated acceptance run.
4. **N2** NightMonkey downloads the release; source build stays as fallback.
5. After the asset has been green on `origin/yurt`: remove the fallback, `engine/QUEUE_PIN` and `spidermonkey/mozconfig` (separate PR); then the user archives `YurtOS/firefox`.

---

### Task N1: NightMonkey takes a provisioned toolchain and a test-source root (repo: nightmonkey)

**Files:** Modify `CMakeLists.txt:66-100,254`, `scripts/ci-suite.sh:15-16`, `scripts/run-jit-tests.sh`, `scripts/run-jstests.sh`; Test `scripts/tests/test_cmake_dist.py`, `scripts/tests/test_ci_suite.py`; README/AGENTS.

**Interfaces:**
- CMake cache variables `NIGHT_TOOLCHAIN_ROOT` (the extracted clang toolchain root; CMake uses `<root>/bin/clang` and `<root>/bin/clang++`, so the resource dir and `wasm-ld` stay next to the driver; a driver copied or symlinked elsewhere is unsupported) and `NIGHT_SYSROOT`. When set they replace `argv0` of `cc`/`cxx` and replace any sysroot option in the config: `--sysroot X`, `--sysroot=X` and `-isysroot X`, in the `cc`/`cxx` strings and in `cxx_base_flags`. When unset, a config with absolute paths behaves exactly as today; a **package** config (bare `clang`/`clang++`, no sysroot option) with `NIGHT_TOOLCHAIN_ROOT` unset fails configure naming the variable (never falls back to a `clang` on `PATH`).
- Env `NIGHT_FIREFOX_TESTS` for `ci-suite.sh`, `run-jit-tests.sh`, `run-jstests.sh`: root holding `js/src/jit-test` and `js/src/tests`; default `$here/firefox` (unchanged).

- [ ] **Step 0: Spike.** Run a configure-only against a fixture dist with stub `clang`/`clang++` scripts and record what the stub must answer for `CMakeDetermineCompilerId` (the compiler checks are forced but identification still runs). Record the answer in the test's docstring so the red tests fail for the stated reason, not a stub defect.
- [ ] **Step 1: Red tests.** `test_cmake_dist.py` with a fake dist whose config copies the **real** shape (`"cxx": ".../clang++ --sysroot /abs/sysroot -std=gnu++20 --target=wasm32-wasi"`, `cxx_base_flags` with `["--sysroot", "/abs/sysroot", ...]`): (a) legacy absolute config, no variables: compiler and flags unchanged; (b) package config with both variables: compiler is `<root>/bin/clang++`, exactly one `--sysroot=<NIGHT_SYSROOT>` appears on compile and link lines and no producer path remains (also with the `=` and `-isysroot` spellings); (c) package config, `NIGHT_TOOLCHAIN_ROOT` unset: configure fails naming it; (d) `cc` and `cxx` both resolve under the root; (e) opcode mismatch: after a successful configure, `cmake --build tmp --target night_opcodes_check` fails with the digest message when the fixture `Opcodes.h` is altered (the check is a build target, not a configure step). `test_ci_suite.py`: with `NIGHT_FIREFOX_TESTS` set, jit and jstests harness paths are under it; unset keeps `$here/firefox`.
- [ ] **Step 2:** Run; confirm each new case fails for the stated reason.
- [ ] **Step 3: Implement** both behaviors; keep `cc`/`cxx` parsing in one place (`CMakeLists.txt:66-93`).
- [ ] **Step 4:** Mutation-check each case (revert its handling, see the test go red). The `scripts` gate and the existing source-built `engine` job stay green.
- [ ] **Step 5:** Commit red tests first, then the change; draft PR; dual review; ready report.

### Task N1b: Snapshot round-trip script (repo: nightmonkey)

The spec gates publication on "a representative `main()` snapshot round-trip"; no NightMonkey script runs one today.

**Files:** Create `scripts/snapshot-roundtrip.sh`, `scripts/tests/test_snapshot_roundtrip.py`.

- [ ] **Step 0: Spike.** Find the existing way NightMonkey snapshots and restores a guest (look in `crates/`, `inproc-host/`, README "snapshot"): name the exact command and what a pass looks like (e.g. snapshot a script that defines state in `main()`, restore, evaluate, compare output). If none exists, define the smallest one that exercises the engine's snapshot path and record it in the PR.
- [ ] **Step 1: Red tests** (stdlib `unittest`, fake runner in a tempdir as in `test_ci_suite.py`): script exits 0 only when restored output equals the expected; nonzero when the restore output differs, the snapshot is empty, or the runner is missing.
- [ ] **Step 2-5:** as N1. Document in README. It is called directly (not wired into `ci-suite.sh`, whose usage is `<suite> <lane>`).

### Task Y1: Packager with contract tests (repo: yurt-firefox)

**Files:** Create `scripts/package-engine.sh`, `scripts/lib/package-contract.sh`, `tests/fixture-dist.sh`, `tests/test-package-engine.sh`; Modify `scripts/check-queue.sh:22-23`.

**Interfaces:**
- `scripts/package-engine.sh --dist DIR --manifest build-manifest.json --out DIR --version V --revision N` -> `<out>/spidermonkey_V-N-wasm32-wasi.tar.zst`, `.sha256`, and `MANIFEST.json`. Exit 0 ok; 1 contract violation (message names the file); 2 usage.
- Archive: top directory `spidermonkey/` (passed as `SPIDERMONKEY_DIST`) with `include/`, `include-private/` (with the rewritten `js-build-config.json`), `system_wrappers/`, `lib/{libjs_static,libjsrust,libjsshell,libpure_virtual}.a`, `bin/js`, `MANIFEST.json`.
- Materialization comes first: every file under `include/**`, `system_wrappers/**` and `lib/*.a` is copied by following its symlink (absolute or relative; the producer links are often absolute). A dangling producer symlink fails at materialization. Only then does the contract check run **on the archive tree**: no symlinks remain, no path points outside, no text file contains a producer prefix.
- **Call (config rewrite):** CMake reads only `cxx`, `cc`, `os_cxxflags`, `optimize_flags`, `debug_flags`, `extra_cxxflags`, `debug_defines`, `library_defines`, `force_includes`, `include_dirs`, `libraries`, `rust_target` (and `os_arch`, unused). The packager rewrites `cc`, `cxx` and `cxx_base_flags`: argv0 becomes bare `clang`/`clang++`; `--sysroot X`, `--sysroot=X` and `-isysroot X` are dropped; and blanks the path-only fields `ar`, `topsrcdir`, `topobjdir` (set to `""`). All other fields are kept verbatim.
- **Call (what counts as a leaked path):** the producer prefixes are read from the dist's own config (`topsrcdir`, `topobjdir`, the sysroot and clang directories) plus `$HOME` and `MOZBUILD_STATE_PATH`; a text file containing any of them fails. A generic "any absolute path" scan would false-positive on headers and is not used. Binaries are exempt.
- **Call (manifest):** `MANIFEST.json` = the `build-manifest.json` fields plus `firefox_version` (from `UPSTREAM`), `queue_commit` (this repo's HEAD), `dist_files` (count and the sha256 of the sorted `sha256  relpath` list), `package_version`, `toolchain` (clang and sysroot `name`, `url`, `sha256` only, no filesystem paths and no original compiler strings), and `test_sources` (filled by Y2).

- [ ] **Step 1: Red tests** (`tests/test-package-engine.sh`; the fixture dist reproduces the real config shape, a symlinked `include/` (absolute links) and `lib/`, a `system_wrappers/`): extracts into a different directory with no symlinks; no text file contains the fixture's producer prefixes; rewritten config has bare argv0, no sysroot option, blank `ar`/`topsrcdir`/`topobjdir`; **fails** (exit 1, names the file) for each of: a leftover producer path in a text file, a dangling symlink, a symlink resolving outside the dist, a missing `lib/*.a`, a missing `include-private/vm/Opcodes.h`, a missing `system_wrappers`; `Opcodes.h` in the archive is byte-identical to the dist's; two packagings give identical `.sha256` (`tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner`, `zstd -T1`); `MANIFEST.json` contains no path under the producer prefixes.
- [ ] **Step 2:** Run; confirm they fail because the script is absent, then for the stated reasons.
- [ ] **Step 3: Implement**, hermetic like `pq_git` (no reliance on cwd or env); the checks live in `scripts/lib/package-contract.sh` so `release.yml` re-runs them on the extracted archive.
- [ ] **Step 4:** Append the test to `scripts/check-queue.sh:22-23`; mutation-check each failure case; `bash scripts/check-queue.sh --fixtures` green, and red when one case is broken.
- [ ] **Step 5:** Draft PR, dual review, ready report.

### Task Y2: Test-source bundle (repo: yurt-firefox)

**Files:** Create `scripts/package-test-sources.sh`, `tests/test-package-test-sources.sh`; Modify `scripts/package-engine.sh` (record bundle identity), `scripts/check-queue.sh:22-23`.

**Interfaces:**
- `scripts/package-test-sources.sh --tree DIR --out DIR --version V --revision N [--jstests]` -> `spidermonkey_V-N-testsrc.tar.zst` + `.sha256` (and, with `--jstests`, `-jstests.tar.zst` + `.sha256`).
- **Call:** the testsrc bundle holds everything the jit lane needs to **start and run**: `js/src/jit-test/**`, `js/src/tests/lib/**`, `js/src/tests/jstests.py`, `js/src/jsapi.h` (jit_test.py asserts it exists), and whatever the harness-startup test below shows is missing. The jstests asset adds `js/src/tests/{test262,non262}/**` and the top-level shared `js/src/tests/shell.js`, plus `xul-info.txt`: the engine-bound metadata that `jstests.py` otherwise derives from `config/autoconf.mk` (passed through `--xul-info`); `run-jstests.sh` gets it from the test root it is given. (After N1, `NIGHT_FIREFOX_TESTS` is read only by `ci-suite.sh`, which passes the root to `run-jit-tests.sh`/`run-jstests.sh` as their first argument; `run-jstests.sh` has no `--xul-info` handling yet, so Y2/N2 add it against that argument: use `<root>/xul-info.txt` when present.)
- The tree hash is checked against `UPSTREAM` on the **tracked tree** (as `build-engine.sh:80-82` does, via `git write-tree`/index), and the packager also **rejects any modification of tracked files in the worktree** (`git diff --quiet` against the index), because `write-tree` ignores unstaged edits while the archive is cut from disk. Untracked build output (the objdir) is allowed and excluded from the archive.
- Bundle identity (sha256 of each archive) goes into `MANIFEST.json` `test_sources`; bundles are built from the patched tree, never the bare tag.

- [ ] **Step 1: Red tests** on a fixture tree: listed paths present and nothing else; deterministic archive; **the extracted bundle starts the harness** (`python3 js/src/jit-test/jit_test.py --help` exits 0 from the extracted directory; the same with `jsapi.h` removed fails) **and runs one tiny jit test through a stub shell** (catches a runtime import of a path outside the bundle); an unstaged edit to a tracked harness file is refused; with `--jstests`, the jstests runner starts with `--xul-info` and without the producer tree; a tree whose tracked-tree hash differs from `UPSTREAM` is refused; a workdir containing an objdir still passes and the objdir is absent from the archive; missing `jit_test.py` fails.
- [ ] **Step 2-5:** as Y1 (register the test in `scripts/check-queue.sh:22-23`, mutation-check, draft PR, dual review).

### Task Y3: Acceptance script and floor (repo: yurt-firefox)

The relocated gate must be able to fail. It is a script so it can be tested and reused by `gate.yml` and `release.yml` instead of a third inline copy.

**Files:** Create `scripts/accept-engine.sh`, `tests/test-accept-engine.sh`, `baseline/jit-floor.txt`; Modify `scripts/check-queue.sh:22-23`.

**Interfaces:**
- `scripts/accept-engine.sh --package DIR --testsrc DIR --toolchain DIR --sysroot DIR --nightmonkey DIR` builds NightMonkey at that checkout with `-DSPIDERMONKEY_DIST=<package>/spidermonkey -DNIGHT_TOOLCHAIN_ROOT -DNIGHT_SYSROOT`, then runs `ci-suite.sh jit aot` and `ci-suite.sh jit interpreter` with `NIGHT_FIREFOX_TESTS=<testsrc>`, and the snapshot script. With `--require-clean-runner` (set by `release.yml`; off for developer machines) it fails if `~/.mozbuild` exists. It always fails if the build fails, if either lane fails, if a lane's **verified** count is below the floor, or if the snapshot round-trip fails. It runs `scripts/snapshot-roundtrip.sh` directly (not through `ci-suite.sh`, whose interface is exactly `<suite> <lane>`). `gate.yml` keeps its own steps.
- `baseline/jit-floor.txt`: `aot_verified=12307` and `interpreter_verified=12494`: the "passing execution results verified" count (passed minus skipped) that `scripts/check-test-log.py jit` prints, which `accept-engine.sh` parses from the lane log under `$RUNNER_TEMP/nightmonkey-logs/jit-<lane>.log`. The comparison is `>=`; a queue PR that legitimately changes counts updates the file. This also closes issue #12's floor request.

- [ ] **Step 1: Red tests** (`tests/test-accept-engine.sh`, stubbed `cmake`/`ci-suite.sh`, same execute-with-stubs style as `t_gate_lanes`): each of build failure, aot lane failure, interpreter lane failure, verified one below the floor (exactly at the floor passes), snapshot failure, existing `~/.mozbuild` with `--require-clean-runner`, missing floor file makes the script exit nonzero with a specific message; the all-green case exits 0; replacing the script body with `exit 0` fails at least five of the cases.
- [ ] **Step 2-5:** as Y1.

### Task Y4: Reuse engine.yml for release builds (repo: yurt-firefox)

**Files:** Modify `.github/workflows/engine.yml`, `tests/test-workflows.sh`.

- [ ] **Step 1: Red tests:** `engine.yml` gains `on: workflow_call` with a `package` boolean input; when true it runs the packager and test-source bundler after the smoke test and uploads `package-out/` as a workflow artifact; PR runs never package (cost); permissions, pins and credentials checks unchanged; a mutation removing the upload or the packaging fails; **for a tag run called from `release.yml` the cache is not saved and no PR run is cancelled** (the concurrency group and the save condition are evaluated in the caller's context; test both); actionlint passes on the new inputs.
- [ ] **Step 2-5:** as Y1. Release builds go through this one job so the wasmtime pin, cache logic and smoke test exist once (a tag run restores only caches of the default branch).

### Task Y5: Release workflow (repo: yurt-firefox)

**Files:** Create `.github/workflows/release.yml`, `scripts/require-ref-on-main.sh` (the logic of `yurt-clang/scripts/ci/require-ref-on-main.sh`), `tests/test-release-workflow.sh`, `RELEASE_REQUIRES_NIGHTMONKEY`; Modify `tests/test-workflows.sh` (add `release.yml` to the hard-coded lists; relax `t_permissions` for the `publish` job of `release.yml` only), `scripts/check-queue.sh:22-23`.

**Interfaces:** Trigger `push: tags: ['engine-v*']` and `workflow_dispatch` (a dry run that builds and accepts but never publishes). Jobs, in `needs:` order:
1. `check-tag`: regex `engine-v<ver>-<n>`; tag commit is an ancestor of `main` (full-history checkout, `require-ref-on-main.sh`); tag version equals the version in `UPSTREAM`; `RELEASE_REQUIRES_NIGHTMONKEY` is an ancestor of `NIGHTMONKEY_PIN` on NightMonkey's `yurt` (full-history clone).
2. `build`: `uses: ./.github/workflows/engine.yml` with `package: true`.
3. `accept`: fresh runner; downloads the build artifact; re-runs the Y1 contract checks on the extracted archive; **mirrors the toolchain verbatim**: downloads clang and sysroot from the URLs in `MANIFEST.json`, verifies the recorded sha256 and copies the archives **unchanged** into the two toolchain assets (the published digest equals the one recorded at build time, anyone can check it, and no consumer depends on Taskcluster URLs staying alive). The mapping from recorded `name` to asset name is explicit; each archive must be under 1.9 GiB (the release asset cap; checked here). It extracts them under `$RUNNER_TEMP/toolchain` (never `~/.mozbuild`); the extract commands and the resulting `NIGHT_TOOLCHAIN_ROOT` (the directory holding `bin/clang`) and `NIGHT_SYSROOT` are fixed in the PR after inspecting the real archive layout in the dry run (Mozilla's archives carry a top-level directory). It runs `scripts/accept-engine.sh --require-clean-runner` at `NIGHTMONKEY_PIN`, then writes the **final `MANIFEST.json`** (the Y1 manifest plus the digest of every release asset) and uploads the complete release set (all assets, `.sha256` files, final manifest) as the `release-set` artifact. Has the apt packages, rustup + `wasm32-wasip1` + `rust-src` per NightMonkey's `rust-toolchain.toml`, cmake/ninja, the pinned wasmtime, disk cleanup, and `timeout-minutes` covering the build plus both lanes.
4. `publish`: `if: github.event_name == 'push' && github.ref_type == 'tag'` (a `workflow_dispatch` can target a tag, so `ref_type` alone is not enough), `permissions: contents: write`; re-verifies the tag is on `main` itself; downloads the `release-set` artifact from `accept` and checks every asset's sha256 against the final `MANIFEST.json` **and that manifest's own digest against the value `accept` passed as a job output (`needs.accept.outputs`)**, so a swapped artifact is caught (the manifest travels in the same artifact and proves only internal consistency); `gh release create` with that set; **refuses** if the release or any asset exists.

- [ ] **Step 0: Spike.** Run the dry run once with `accept` stopped before the build; record the archives' top-level directories and sizes, then fix the extract commands and `NIGHT_TOOLCHAIN_ROOT`/`NIGHT_SYSROOT` in this plan before writing the `accept` red tests.
- [ ] **Step 1: Red tests** (`tests/test-release-workflow.sh`, executing steps against stubs): tag not on main fails; tag/`UPSTREAM` mismatch fails; `RELEASE_REQUIRES_NIGHTMONKEY` not an ancestor fails; `accept` does not restore the mozbuild cache; `publish` `needs` `accept`, runs only for a `push` of a tag (a `workflow_dispatch` against a branch **and against a tag** skips it), is the only job with `contents: write`, re-checks main, refuses when a toolchain or other asset digest differs from what `accept` recorded, refuses an artifact swapped after `accept` (mutation), refuses an existing release/asset; `t_pinned` accepts the local `uses: ./.github/workflows/engine.yml` call only for that exact path while still requiring `@<40-hex-SHA>` on every remote `uses:` (mutation: an unpinned remote action still fails); each rule has a mutation that fails the test.
- [ ] **Step 2-4:** implement; run the `workflow_dispatch` dry run on CI and attach the evidence to the PR.
- [ ] **Step 5:** Draft PR, dual review, ready report. **Non-code step for the user:** create a tag ruleset restricting creation/update/deletion of `engine-v*` and enable immutable releases (`gh api repos/YurtOS/yurt-firefox/rulesets` is `[]` today); an in-workflow guard alone can be omitted by a tag pointing at an old commit. After merge and the user's go-ahead: push `engine-v147.0.4-1`.

### Task N2: NightMonkey downloads the release (repo: nightmonkey)

**Files:** Create `engine/ENGINE_RELEASE`, `.github/workflows/engine-release.yml`, `scripts/check-engine-release.sh` + `scripts/tests/test_check_engine_release.py` (the same exact-text, no-`if:` guard discipline as `check-engine-source.sh`); Modify `.github/workflows/ci.yml` (runs both engine jobs), `.github/workflows/jstests.yml`, README/AGENTS. `.github/workflows/engine.yml`, `check-engine-source.sh` and `engine/QUEUE_PIN` are **left untouched** until the fallback is removed (the existing guard forbids conditionals, so the fallback is a separate job, not a dispatch input).

**Interfaces:** `engine/ENGINE_RELEASE` holds the tag and the sha256 of the engine, testsrc, toolchain-clang and toolchain-sysroot assets (and of `MANIFEST.json`). The job downloads each with `gh release download` (public, no token), verifies every digest, extracts the toolchain to `$RUNNER_TEMP/toolchain`, the engine to `$RUNNER_TEMP/spidermonkey`, the test sources to `$RUNNER_TEMP/testsrc`; builds with `-DSPIDERMONKEY_DIST`, `-DNIGHT_TOOLCHAIN_ROOT`, `-DNIGHT_SYSROOT`; runs the lanes with `NIGHT_FIREFOX_TESTS`. `engine-release.yml` has `on: workflow_call` with the same `lane` and `full_jstests` inputs as `engine.yml`. `ci.yml` runs the existing source-build job and the new download job side by side (no conditionals; this doubles engine CI cost per PR, accepted for the transition) until the download job has been green on `origin/yurt`; then the fallback is deleted. `jstests.yml` keeps calling `engine.yml` and switches to `engine-release.yml` only in the fallback-removal PR (or in this PR if it shows green full-jstests evidence from the download path). When `full_jstests` is requested (the nightly `jstests.yml` calls it), `engine-release.yml` also pins, downloads, verifies and extracts the separate jstests asset (`ENGINE_RELEASE` lists its digest) and points `NIGHT_FIREFOX_TESTS` at the union. The engine bump procedure also regenerates opcode tables (`scripts/gen_opcodes.py`) as in the spec.

- [ ] **Step 1: Red tests:** `test_check_engine_release.py` requires: the download step verifies each digest against `engine/ENGINE_RELEASE` before extraction; precedes the build; a floating tag, `latest`, a missing digest check, a missing test-source download, and (for the full-jstests path) a missing jstests-asset download each fail; the existing `check-engine-source.sh` suite still passes unchanged.
- [ ] **Step 2-4:** implement; the PR run builds from the downloaded release and runs both lanes.
- [ ] **Step 5:** Draft PR, dual review, ready report.

## Self-review notes

- Spec coverage: package contract (Y1), config/toolchain (N1+Y1), test sources (Y2, N1), red tests (every task, with mutation or failure injection), order (Order), release incl. snapshot round-trip and floor (N1b, Y3, Y5), NightMonkey follow-up and fallback (N2), visibility (Global Constraints).
- Calls for review: bare `clang`/`clang++` plus `NIGHT_TOOLCHAIN_ROOT`; blanking `ar`/`topsrcdir`/`topobjdir`; prefix-based leak detection; optional jstests asset with a packaged `xul-info.txt`; toolchain mirrored into the release; `RELEASE_REQUIRES_NIGHTMONKEY`; `accept-engine.sh` shared script.
- Still to learn by spike (named steps): what the stub compiler must answer for CMake (N1 Step 0); the existing NightMonkey snapshot command (N1b Step 0); the exact `--xul-info` content (Y2 red test).
