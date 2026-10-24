# yurt-firefox Slice B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** yurt-firefox publishes checksummed, relocatable engine releases; NightMonkey builds from a downloaded release instead of building Firefox.

**Architecture:** A packager turns the queue-built `dist/` into a relocatable archive (symlinks materialized, `js-build-config.json` rewritten to carry no compiler or sysroot path). A release workflow builds, packages, proves the archive on a clean runner against a NightMonkey that already understands packages, and only then publishes. NightMonkey's CMake takes a provisioned `clang`/sysroot from explicit variables; its jit/jstests lanes take test sources from a bundle shipped with the release. NightMonkey keeps its source-build path until the downloaded asset has been green on `origin/yurt`.

**Tech Stack:** bash and python3 (stdlib `unittest` in NightMonkey, plain bash tests in yurt-firefox), GitHub Actions, CMake, `tar` + `zstd`, `gh release`.

**Spec:** `docs/superpowers/specs/2026-10-21-yurt-firefox-design.md`, section "Slice B design". This plan argues from it. Where the spec leaves a choice, this plan records it as a **Call**.

## Global Constraints

- Linux x86_64 only for the release asset (CI and EC2); a Mac asset is out of scope.
- Every red test is committed before the fix it targets. Follow-up commits only; never amend or force-push an open PR branch.
- Firefox builds run on CI or on EC2 via `/Users/sunny/work/yurtos/bin/ec2slot`, never on the laptop. Packager tests use a **fixture dist**, not a real build.
- Workflows: top-level `permissions: contents: read`, every action pinned by full SHA with a version comment, `persist-credentials: false`, no `pull_request_target`/`workflow_run`, no `secrets.`. The one exception: the publish job of `release.yml` has `permissions: contents: write`.
- No consumer pins an `engine-v*` tag before the packager and relocation red tests exist and pass.
- Merge authority is the user's (`docs/agents/org.md`). Open PRs as drafts; dual Claude + Codex review per round.
- `YurtOS/yurt-firefox` is public (resolves the spec's visibility question): CI downloads need no credentials.
- Release asset names: `spidermonkey_<ver>-<n>-wasm32-wasi.tar.zst`, `.sha256`, `MANIFEST.json`; tag `engine-v<firefox-version>-<n>` (first: `engine-v147.0.4-1`).

## Review Focus

- A leftover absolute path or symlink pointing outside the archive must fail the packager, including inside `system_wrappers/` and `include-private/js-build-config.json` (most likely).
- An archive that passes on the producer host but not on a clean runner (no `~/.mozbuild`, different path): the acceptance run must be the real gate.
- A release asset overwritten or re-tagged after publish: refuse.
- A tag pushed from a branch other than `main` publishing a release.
- NightMonkey opcode digest mismatch: `include-private/vm/Opcodes.h` must be byte-identical in the package.
- Test-source bundle not matching the engine it ships with (version skew between engine and `jit_test.py`).

## File structure

yurt-firefox: `scripts/package-engine.sh` (packager), `scripts/package-test-sources.sh`, `scripts/lib/package-contract.sh` (shared checks), `scripts/require-ref-on-main.sh`, `.github/workflows/release.yml`, `tests/test-package-engine.sh`, `tests/test-package-test-sources.sh`, `tests/test-release-workflow.sh`, `tests/fixture-dist.sh` (fixture dist generator), `RELEASE_REQUIRES_NIGHTMONKEY` (one line: the NightMonkey commit that contains Task N1).
NightMonkey: `CMakeLists.txt`, `scripts/tests/test_cmake_dist.py`, `scripts/ci-suite.sh`, `scripts/tests/test_ci_suite.py`, `.github/workflows/engine.yml`, `scripts/check-engine-source.sh` + `scripts/tests/test_check_engine_source.py`, README/AGENTS recipes.

## Order

1. **N1** NightMonkey consumer (CMake provisioned toolchain, test-source path). Merge, then bump `NIGHTMONKEY_PIN` (PR labeled `gate`) to that commit.
2. **Y1 -> Y2 -> Y3 -> Y4** yurt-firefox packager, test bundle, manifest additions, release workflow.
3. First release `engine-v147.0.4-1`, gated by the relocated acceptance run.
4. **N2** NightMonkey downloads the release; source build stays as fallback.
5. After the asset has been green on `origin/yurt`: delete NightMonkey's `spidermonkey/mozconfig` copy and the fallback (separate PR), then the user archives `YurtOS/firefox`.

---

### Task N1: NightMonkey takes a provisioned toolchain and a test-source root (repo: nightmonkey)

**Files:** Modify `CMakeLists.txt:66-100,254`, `scripts/ci-suite.sh:15-16`, `scripts/run-jit-tests.sh`, `scripts/run-jstests.sh`; Test `scripts/tests/test_cmake_dist.py`, `scripts/tests/test_ci_suite.py`; docs in README/AGENTS.

**Interfaces:**
- Produces CMake cache variables `NIGHT_CLANG` (path to clang driver dir or binary) and `NIGHT_SYSROOT` (path), both optional. When set they replace `argv0` of `cc`/`cxx` from `js-build-config.json` and replace any `--sysroot=` in the cxx args; when unset behavior is byte-identical to today (absolute paths from the config).
- Produces env `NIGHT_FIREFOX_TESTS` for `ci-suite.sh`: root holding `js/src/jit-test` and `js/src/tests`; default `$here/firefox` (unchanged).
- Consumes a package-style config where `cc`/`cxx` have **no path and no `--sysroot`**: bare `clang`/`clang++` as argv0 plus the remaining args.

- [ ] **Step 1: Red tests.** `test_cmake_dist.py`: build a fake dist in a tempdir (`include-private/js-build-config.json`, `vm/Opcodes.h`, empty `lib/*.a`, fake `clang` shell scripts); `cmake -S . -B tmp -DSPIDERMONKEY_DIST=...` configure-only. Cases: (a) legacy absolute config, no variables: `CMAKE_CXX_COMPILER` is the config's path (unchanged); (b) package config with `NIGHT_CLANG`/`NIGHT_SYSROOT`: compiler is `NIGHT_CLANG`'s `clang++`, `--sysroot=<NIGHT_SYSROOT>` is on the compile and link lines, no other sysroot present; (c) package config without `NIGHT_CLANG`: configure fails with a message naming `NIGHT_CLANG`; (d) `Opcodes.h` digest mismatch still fails. `test_ci_suite.py`: with `NIGHT_FIREFOX_TESTS` set, the jit and jstests harness paths are under it; unset keeps `$here/firefox`.
- [ ] **Step 2:** Run both; confirm each new case fails for the stated reason.
- [ ] **Step 3: Implement** the two behaviors above; keep `cc`/`cxx` parsing in one place (`CMakeLists.txt:66-93`).
- [ ] **Step 4:** Run the NightMonkey `scripts` gate and a real configure against a source-built dist on CI (the existing `engine` job must stay green).
- [ ] **Step 5:** Commit red tests first, then the change; open draft PR; dual review; ready report.

### Task Y1: Packager with contract tests (repo: yurt-firefox)

**Files:** Create `scripts/package-engine.sh`, `scripts/lib/package-contract.sh`, `tests/fixture-dist.sh`, `tests/test-package-engine.sh`; Modify `scripts/check-queue.sh:22-23` (append the test to the fixture list), `tests/test-workflows.sh` if shellcheck globs need it.

**Interfaces:**
- `scripts/package-engine.sh --dist DIR --manifest build-manifest.json --out DIR --version V --revision N` -> `<out>/spidermonkey_V-N-wasm32-wasi.tar.zst`, `.sha256`, `MANIFEST.json`. Exit 0 ok; 1 contract violation (message names the file); 2 usage.
- Archive layout (top directory `spidermonkey/`, which consumers pass as `SPIDERMONKEY_DIST`): `include/` (symlinks materialized to real files), `include-private/` (including a **rewritten** `js-build-config.json`), `system_wrappers/` (materialized), `lib/{libjs_static,libjsrust,libjsshell,libpure_virtual}.a` (materialized), `bin/js`, `MANIFEST.json`.
- **Call:** rewritten config keeps every field but sets `cc`/`cxx` argv0 to the bare names `clang`/`clang++` and drops every `--sysroot=...` / `-isysroot`; all other args retained. Original values go into `MANIFEST.json` as `toolchain.original_cc/cxx` for the record only.
- **Call:** `MANIFEST.json` = the `build-manifest.json` fields plus `firefox_version` (from `UPSTREAM` tag), `queue_commit` (this repo's HEAD SHA), `dist_files` (sorted `sha256  relpath` list hash plus count), `package_version`, `test_sources` (set by Y2), `toolchain.clang`/`sysroot` URL+sha256 (already in the build manifest).

- [ ] **Step 1: Red tests** (`tests/test-package-engine.sh`, fixture dist from `tests/fixture-dist.sh` with symlinked `include/` and `lib/`, a `system_wrappers/`, a config with absolute cc/cxx/sysroot): archive extracts into a different directory and contains no symlinks; no file contains the fixture's absolute prefix; rewritten config has bare argv0 and no sysroot; **fails** (exit 1, names the file) for each of: leftover absolute path in a text file, a symlink pointing outside the archive, a missing `lib/*.a`, a missing `include-private/vm/Opcodes.h`, a dangling symlink; `Opcodes.h` in the archive is byte-identical to the dist's; two packagings of the same dist give identical `.sha256` (use `tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner` and `zstd -T1`).
- [ ] **Step 2:** Run; confirm they fail because the script is absent, then for the stated reasons.
- [ ] **Step 3: Implement** with `pq_git`-style hermetic discipline (no reliance on cwd or env); checks live in `scripts/lib/package-contract.sh` so the release workflow can re-run them on the extracted archive.
- [ ] **Step 4:** `bash scripts/check-queue.sh --fixtures` green; mutation-check each failure case (revert the check, see the test go red).
- [ ] **Step 5:** Draft PR, dual review, ready report.

### Task Y2: Test-source bundle (repo: yurt-firefox)

**Files:** Create `scripts/package-test-sources.sh`, `tests/test-package-test-sources.sh`; Modify `scripts/package-engine.sh` to record the bundle identity.

**Interfaces:**
- `scripts/package-test-sources.sh --tree DIR --out DIR --version V --revision N` -> `spidermonkey_V-N-testsrc.tar.zst` + `.sha256`: `js/src/jit-test/**` and `js/src/tests/lib/**` plus `js/src/tests/jstests.py` (what the jit lane and the checked jstests runner import). **Call:** `js/src/tests/{test262,non262}` go in a second optional asset `spidermonkey_V-N-jstests.tar.zst` because of size; the optional full-jstests lane downloads it only when asked.
- Bundle identity (sha256 of each archive) is written into `MANIFEST.json` `test_sources`. The bundle is built from the patched tree (`build-engine.sh`'s workdir), never from the bare tag.

- [ ] **Step 1: Red tests** on a fixture tree: the paths above are present, nothing else is, deterministic archive, missing `jit_test.py` fails, a tree whose applied-tree hash differs from `UPSTREAM` is refused (reuse `pq_` helpers).
- [ ] **Step 2-5:** as Y1.

### Task Y3: Manifest and engine artifact upload (repo: yurt-firefox)

**Files:** Modify `.github/workflows/engine.yml` (upload the packaged assets as a workflow artifact on `workflow_dispatch` and on `main`), `tests/test-workflows.sh`.

- [ ] **Step 1: Red test** in `tests/test-workflows.sh`: engine.yml runs the packager after the smoke test and uploads `package-out/`; permissions/pins unchanged; a mutation removing the upload fails the test.
- [ ] **Step 2-5:** as Y1. Keep PR runs from uploading (cost); the artifact exists to feed Y4's relocated acceptance during a release run.

### Task Y4: Release workflow with relocated acceptance (repo: yurt-firefox)

**Files:** Create `.github/workflows/release.yml`, `scripts/require-ref-on-main.sh` (copy the logic of `yurt-clang/scripts/ci/require-ref-on-main.sh`), `tests/test-release-workflow.sh`; Modify `tests/test-workflows.sh` (add `release.yml` to the hard-coded workflow lists; relax `t_permissions` for the publish job of `release.yml` only).

**Interfaces:**
- Trigger: `push: tags: ['engine-v*']` and `workflow_dispatch` (dry-run: builds and accepts, never publishes). Jobs, in `needs:` order: `check-tag` (regex `engine-v<ver>-<n>`, tag commit is an ancestor of `main`, tag version equals `UPSTREAM`'s Firefox version) -> `build` (build-engine, smoke, package, test bundle, upload artifact) -> `accept` (runs on a **fresh runner**, downloads the artifact, runs the Y1 contract checks on the extracted archive, installs clang+sysroot from the URLs/digests in `MANIFEST.json` verifying sha256, builds NightMonkey at `NIGHTMONKEY_PIN` with `-DSPIDERMONKEY_DIST=<extracted> -DNIGHT_CLANG=... -DNIGHT_SYSROOT=...`, runs both jit lanes with `NIGHT_FIREFOX_TESTS=<extracted test bundle>`; asserts nonempty counts matching the baseline floor and a `main()` snapshot round-trip) -> `publish` (`contents: write`, `gh release create` with the three assets, **refuses** if the release or any asset exists).
- `NIGHTMONKEY_PIN` must contain Task N1; the workflow's first step checks `git merge-base --is-ancestor <N1 commit> $NIGHTMONKEY_PIN` using a constant recorded in `RELEASE_REQUIRES_NIGHTMONKEY` (**Call:** a one-line file holding the N1 merge commit SHA).

- [ ] **Step 1: Red tests** (`tests/test-release-workflow.sh`, same execute-the-steps-against-stubs style as `t_gate_lanes`): tag not on main fails; tag/UPSTREAM version mismatch fails; `accept` runs on a runner without `~/.mozbuild` (assert the job does not restore the mozbuild cache); publish needs `accept`; publish is the only job with `contents: write`; overwrite refused; mutation of each fails the test.
- [ ] **Step 2-4:** implement; run `workflow_dispatch` dry-run on CI and attach the evidence.
- [ ] **Step 5:** Draft PR, dual review, ready report. After merge and user go-ahead: push `engine-v147.0.4-1` (the user decides to tag).

### Task N2: NightMonkey downloads the release (repo: nightmonkey)

**Files:** Modify `.github/workflows/engine.yml`, `engine/QUEUE_PIN` replaced by `engine/ENGINE_RELEASE` (tag + sha256 of the asset), `scripts/check-engine-source.sh` + `scripts/tests/test_check_engine_source.py` (the guard pins the engine steps verbatim; update both together), README/AGENTS.

- [ ] **Step 1: Red tests:** extend the guard tests so the new download step must verify the sha256 against `engine/ENGINE_RELEASE`, must come before the build, and that a mutation (no verification, floating tag, `latest`) fails.
- [ ] **Step 2-4:** implement the download + provision path; keep a `workflow_dispatch` input `engine_source=queue` selecting the existing source build as fallback until the asset has been green on `origin/yurt`.
- [ ] **Step 5:** Draft PR, dual review, ready report; engine bump procedure also regenerates opcode tables (`scripts/gen_opcodes.py`) as in the spec.

## Self-review notes

- Spec coverage: package contract (Y1), config/toolchain contract (N1+Y1), test sources (Y2, N1), red tests (every task), order (Order), release (Y4), NightMonkey follow-up (N2), visibility (Global Constraints).
- Open item for the user: none blocking. Calls recorded above (bare argv0, optional jstests asset, `RELEASE_REQUIRES_NIGHTMONKEY`) are mine to be checked in review.
