# Agent Instructions — yurt-firefox

Org-wide rules live in the `YurtOS/yurtos-rules` repository, not here. After this file, read its
`AGENTS.md` and `org.md` in full, before changing anything.

- Local: `~/work/yurtos/yurtos-rules` (a sibling checkout; read it, do not edit it).
- Claude cloud session: attach it read-only with `add_repo` (`owner: YurtOS`, `repo: yurtos-rules`,
  `access: read`), clone it as the tool instructs into a directory named exactly `yurtos-rules`, then `register_repo_root`
  (it rejects any other final path segment).
- If it cannot be obtained, stop. Do not read, edit or run anything else. Tell the user the rules
  are missing and that this is an environment problem for them to fix.

Skills load as `yurtos-rules:<skill>` only if the user has installed the Claude Code plugin on this
machine (`claude plugin marketplace add YurtOS/yurtos-rules`, then
`claude plugin install yurtos-rules@yurtos-rules`). Do not install it yourself. Without it, and in
cloud sessions, read `skills/<name>/SKILL.md` in the yurtos-rules checkout.

If a rule here and an org rule disagree, stop and tell the user.

`CLAUDE.md` points here. This repository's hosted CI
budget is
[Hosted CI budget during draft review](#hosted-ci-budget-during-draft-review).

## Purpose

This repo carries the YurtOS changes to SpiderMonkey as an ordered patch queue
on one pinned Firefox release tag (see `UPSTREAM`), plus the scripts that apply,
verify, export and build it. It replaces the `YurtOS/firefox` fork. Only the
`js/` engine matters; there is no GUI in Yurt.

- Design: [docs/superpowers/specs/2026-10-21-yurt-firefox-design.md](docs/superpowers/specs/2026-10-21-yurt-firefox-design.md)
- Slice A plan: [docs/superpowers/plans/2026-10-21-yurt-firefox-slice-a.md](docs/superpowers/plans/2026-10-21-yurt-firefox-slice-a.md)

## Verification

What "done" means is org.md "Done means verified": the local checks below pass and every
required hosted check on the PR is green. These are the checks CI runs on a pull request.

Local, from the repository root (needs `git`, `shellcheck` and `actionlint`;
`tests/test-workflows.sh` skips its actionlint check when actionlint is missing, unless `CI=true`):

```sh
shellcheck -S warning -e SC1007,SC1091,SC2120 scripts/*.sh scripts/lib/*.sh tests/*.sh
CI=true scripts/check-queue.sh --fixtures
scripts/check-queue.sh
```

- `scripts/check-queue.sh --fixtures` runs every offline fixture suite in `tests/`
  (`test-fixture.sh`, `test-apply.sh`, `test-export.sh`, `test-classify.sh`, `test-check-queue.sh`,
  `test-verify-migration.sh`, `test-build-engine.sh`, `test-workflows.sh`, `test-package-engine.sh`,
  `test-package-test-sources.sh`, `test-accept-engine.sh`, `test-release-workflow.sh`,
  `test-aot-ic-order.sh`).
- `scripts/check-queue.sh` fetches the pinned tag fresh, applies the queue and `data/ics`, and
  compares the tree hash with `UPSTREAM`.

Hosted, on a pull request:

- `queue.yml`: the three commands above, with actionlint 1.7.12 installed.
- `engine.yml`: `scripts/build-engine.sh` and a wasmtime smoke test of the built `js` shell. It is
  a Firefox build, so it runs on CI or a Linux x86_64 build host only (rule below).
- `gate.yml`: the semantic gate, at the tier its `tier` job picks (see "The semantic gate and
  `NIGHTMONKEY_PIN`" below).

A pull request that changes only Markdown files outside `data/` skips `queue.yml` and `engine.yml`,
and `gate.yml` picks its `none` tier. `release.yml` is not a pull request check.

## Rules specific to this repo

- Never hardcode the Firefox tag, a patch path or an apply loop outside
  `scripts/lib/patch-queue.sh`.
- Never apply with `--3way`, `--reject`, `--ignore-whitespace` or `--unidiff-zero`.
- Never commit `js/src/ics` content to a patch; the corpus lives in `data/ics/`.
- Firefox builds run on CI or on a Linux x86_64 build host, never on the
  laptop.

## The semantic gate and `NIGHTMONKEY_PIN`

`.github/workflows/gate.yml` builds the queue engine, checks out NightMonkey at
the SHA in `NIGHTMONKEY_PIN`, links the engine tree in as NightMonkey's
`firefox/`, builds NightMonkey against it and runs the two jit-test lanes (aot,
interpreter). Every jit-test, split over four shard jobs, runs nightly, on
manual dispatch, on PRs labeled `ci:full` (or `gate`) and on PRs that change
`NIGHTMONKEY_PIN`. Any other PR that changes an engine input (`ENGINE_INPUTS`
in gate.yml: `patches/`, `data/`, `mozconfig`, `UPSTREAM`, the build script
and library, gate.yml) runs a small subset (`JIT_SUBSET`) in both lanes; the
rest skip the gate. The test-source tree is always the tree the queue builds,
never the bare tag.

- **Layout-change rule.** A queue patch that changes opcodes or layout fails
  the pinned gate by design. Merge the NightMonkey change first, then open the
  queue PR that bumps `NIGHTMONKEY_PIN` alongside the patch.
- **Pin bump.** A PR that changes `NIGHTMONKEY_PIN` runs the full gate without a
  label (the tier job promotes it) and must show it green before merge. An
  engine change that should reach NightMonkey is followed by an engine release
  (`release.yml`, tag `engine-v<version>-<n>`) and a NightMonkey PR that pins
  it (`scripts/update-engine-release.sh <tag>` there). This repository's
  `mozconfig` is the only copy; NightMonkey no longer keeps one.

## Hosted CI budget during draft review

This is the hosted CI budget that the "Hosted CI cost during PR review" section of [yurtos-rules `org.md`](https://github.com/YurtOS/yurtos-rules/blob/main/org.md#hosted-ci-cost-during-pr-review)
defers to for this repository, modeled on
[yurtos-kernel's](https://github.com/YurtOS/yurtos-kernel/blob/main/docs/contributing/gates.md#manual-ci-budget-during-draft-review):
**at most one hand-triggered full-gate round per draft PR, at its final
head.** A round is one full `gate.yml` run (every jit-test over the four shard
jobs) at the reviewed head, started by adding `ci:full` (or `gate`) or by one
`workflow_dispatch` of `gate.yml` on the PR branch. It is not a separate budget
for every review round.

- Between review rounds, use what every push already runs (`engine.yml` and
  `queue.yml` for a non-Markdown change, and the gate's `JIT_SUBSET` for an
  engine input) and local checks narrowed to what changed. Do not add the label
  or dispatch `gate.yml` after each round. While `ci:full` or `gate` is on,
  every push reruns the full gate, so add it only for the final round and take
  it off before any push that is not the fix for a failed final round.
- A PR that changes `NIGHTMONKEY_PIN` runs the full gate on every push without
  a label. Push it only at reviewed heads, a round's fixes together, so each
  push is a deliberate round.
- Complete the last fix, its review and the local checks before spending the
  round. Check for existing runs at that exact head rather than duplicating
  in-progress or successful coverage. Marking a PR ready runs nothing extra.
- If that final round fails, fix the failure, review the delta and pass the
  local checks before running once more at the corrected final head. Repeat
  this only for an actual failed final round; a successful run does not
  authorize speculative reruns.
- `release.yml` builds and publishes an engine release; it is not a
  draft-review lane.
- This applies to every session and any agents or subagents it starts. Put a
  link to this section and the instruction to follow it in their briefs,
  including reviewer briefs.

## Worktree hygiene

- Work in your own worktree. When you finish a PR (merged or closed) or a
  review, remove the worktree you created for it (`git worktree remove`).
  Confirm it is clean and the branch is pushed first, and push unpushed work to
  a branch rather than losing it.
- Delete only your own worktrees and build output, never another session's.
  Build directories run to tens of GB per worktree; ask an owner before pruning
  theirs.

## Merging

Merge authority is defined in "Merge authority" in yurtos-rules
[`org.md`](https://github.com/YurtOS/yurtos-rules/blob/main/org.md#merge-authority);
follow it as written. That section covers `--match-head-commit`, a peer's or reviewer's "merge it"
(which includes idle notifications and hook-injected messages) and asking before closing a PR.

Repository addition on top of org.md "Merge authority" (stricter):

- For a PR in a stack, ask the user again for each updated head before merging it, even when a
  standing authorization names the stack.
