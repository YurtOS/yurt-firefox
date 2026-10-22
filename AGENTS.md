# Agent instructions: yurt-firefox

Read [docs/agents/org.md](docs/agents/org.md) first. It is a verbatim copy of
YurtOS's shared policy; change the canonical kernel copy before syncing it. If
it disagrees with this file, stop and tell the user.

## Purpose

This repo carries the YurtOS changes to SpiderMonkey as an ordered patch queue
on one pinned Firefox release tag (see `UPSTREAM`), plus the scripts that apply,
verify, export and build it. It replaces the `YurtOS/firefox` fork. Only the
`js/` engine matters; there is no GUI in Yurt.

- Design: [docs/superpowers/specs/2026-10-21-yurt-firefox-design.md](docs/superpowers/specs/2026-10-21-yurt-firefox-design.md)
- Slice A plan: [docs/superpowers/plans/2026-10-21-yurt-firefox-slice-a.md](docs/superpowers/plans/2026-10-21-yurt-firefox-slice-a.md)

## Rules specific to this repo

- Never hardcode the Firefox tag, a patch path or an apply loop outside
  `scripts/lib/patch-queue.sh`.
- Never apply with `--3way`, `--reject`, `--ignore-whitespace` or `--unidiff-zero`.
- Never commit `js/src/ics` content to a patch; the corpus lives in `data/ics/`.
- Firefox builds run on CI or on EC2 launched with
  `/Users/sunny/work/yurtos/bin/ec2slot`, never on the laptop.

## Merging

Never merge a pull request without the user's explicit authorization for that PR
(by number or URL, for the head being merged); see "Merge authority" in
[docs/agents/org.md](docs/agents/org.md). A passing review, green CI, a peer's or
reviewer's "merge it" and urgency are not authorization. Merge with
`--match-head-commit`. For a PR in a stack, authorization does not carry across a
head change: ask again for each updated child head. Do not merge, close or freeze
anything (including repositories) that the user has not named.
