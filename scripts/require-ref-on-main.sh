#!/usr/bin/env bash
# Fail unless a commit is on this repository's main.
#   require-ref-on-main.sh <commit>
# Run inside a full-history checkout whose `origin` is the repository (CI:
# actions/checkout with fetch-depth: 0). Fetches origin's main (three tries,
# so a network blip cannot pass as "not on main", and a persistent failure
# fails closed), then requires <commit> to be an ancestor of origin/main. A
# release cut from a commit that never merged looks normal everywhere else;
# this is the guard (the logic of yurt-clang's scripts/ci/require-ref-on-main.sh).
# git runs through pq_git (no inherited repository selection or config).
# Exit codes: 0 on main; 1 not on main, or main could not be fetched; 2 usage
# or a git error (an unknown commit).
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: require-ref-on-main.sh <commit>" >&2
  exit 2
fi
commit=$1

fetched=0
for attempt in 1 2 3; do
  if pq_git fetch --quiet origin main; then
    fetched=1
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    echo "require-ref-on-main: warning: git fetch origin main failed (attempt $attempt/3); retrying" >&2
    sleep "$attempt"
  fi
done
if [ "$fetched" -ne 1 ]; then
  echo "require-ref-on-main: git fetch origin main failed 3 times; cannot show $commit is on main" >&2
  exit 1
fi

# --is-ancestor: 1 is "not an ancestor"; anything else is an error (an
# unknown commit), reported apart so it is not mistaken for a rogue tag.
rc=0
pq_git merge-base --is-ancestor "$commit" refs/remotes/origin/main || rc=$?
case $rc in
  0) echo "require-ref-on-main: $commit is on main" ;;
  1) echo "require-ref-on-main: $commit is not an ancestor of main; refusing" >&2; exit 1 ;;
  *) echo "require-ref-on-main: git merge-base --is-ancestor exited $rc for $commit (unknown commit?)" >&2; exit 2 ;;
esac
