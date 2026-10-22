#!/usr/bin/env bash
# Dev loop for the patch queue.
#   export-patches.sh <scratch-dir>           build a scratch checkout: the pinned
#                                             tag with the queue applied by git am,
#                                             and the corpus copied in untracked
#   export-patches.sh --write <scratch-dir>   export the scratch commits since the
#                                             tag into patches/ and re-pin the tree
# Edit and commit in the scratch checkout with plain git; the corpus is listed in
# its .git/info/exclude so it never shows up in a commit, am or rebase. The corpus
# itself is edited in data/ics, never in the scratch checkout.
# PQ_ROOT overrides the repository root (tests use it).
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

ICS_PATH=${PQ_ICS_PATH:-js/src/ics}

usage() {
  echo "usage: export-patches.sh [--write] <scratch-dir>" >&2
  exit 2
}

# require_patches_dir: an empty queue is valid, a missing one is not.
require_patches_dir() {
  [ -d "$ROOT/patches" ] || { echo "export-patches: no patches directory: $ROOT/patches" >&2; return 1; }
}

create_scratch() {
  local scratch=$1 patch
  if [ -e "$scratch/.git" ]; then
    echo "export-patches: $scratch already exists; delete it to rebuild from the queue"
    return 0
  fi
  require_patches_dir || return 1
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  pq_fetch "$scratch" || return 1
  # Not --3way: a patch that does not apply cleanly is a broken queue. --keep-cr
  # keeps CRLF files intact in the mailbox round trip.
  while IFS= read -r patch; do
    git -C "$scratch" am -q --no-3way --keep-cr "$patch" ||
      { echo "export-patches: failed to apply $patch" >&2; return 1; }
  done < <(find "$ROOT/patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
  mkdir -p "$scratch/.git/info" "$scratch/$ICS_PATH" || return 1
  printf '/%s/\n' "$ICS_PATH" >>"$scratch/.git/info/exclude"
  cp -R "$ROOT/data/ics/." "$scratch/$ICS_PATH/" || return 1
  echo "export-patches: scratch checkout ready at $scratch"
}

# Patch bytes must not depend on the user's or the system's git config
# (subject prefix, context, diff algorithm, prefixes, sign-off ...).
fp() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c diff.noprefix=false -c diff.mnemonicPrefix=false -c format.signOff=false "$@"
}

write_patches() {
  local scratch work touched f
  scratch=$(cd "$1" 2>/dev/null && pwd -P) || { echo "export-patches: no such scratch: $1" >&2; return 1; }
  git -C "$scratch" rev-parse --git-dir >/dev/null 2>&1 ||
    { echo "export-patches: $scratch is not a git checkout" >&2; return 1; }
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  require_patches_dir || return 1
  git -C "$scratch" merge-base --is-ancestor "$PQ_COMMIT" HEAD ||
    { echo "export-patches: $scratch HEAD does not descend from pinned commit $PQ_COMMIT" >&2; return 1; }

  touched=$(git -C "$scratch" log --no-renames --name-only --format= "$PQ_COMMIT..HEAD" -- "$ICS_PATH") || return 1
  if [ -n "$touched" ]; then
    printf '%s\n' "$touched" >&2
    echo "export-patches: commits touch $ICS_PATH; the corpus lives in data/ics" >&2
    return 1
  fi

  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' RETURN
  mkdir "$work/patches" || return 1
  fp -C "$scratch" format-patch -q --binary --no-signature --zero-commit --no-numbered \
    --abbrev=12 -o "$work/patches" "$PQ_COMMIT..HEAD" || return 1

  # Same path as check-queue: fresh clone, apply, corpus, stage, write-tree.
  pq_fetch "$work/tree" || return 1
  pq_apply "$work/tree" "$work/patches" "$ROOT/data/ics" || return 1
  PQ_TREE_NEW=$(pq_tree "$work/tree") || return 1

  find "$ROOT/patches" -maxdepth 1 -type f -name '*.patch' -exec rm -f {} + || return 1
  for f in "$work"/patches/*.patch; do
    [ -e "$f" ] || continue
    cp "$f" "$ROOT/patches/" || return 1
  done
  awk -v t="$PQ_TREE_NEW" '/^tree=/ { print "tree=" t; next } { print }' "$ROOT/UPSTREAM" >"$work/UPSTREAM" &&
    cp "$work/UPSTREAM" "$ROOT/UPSTREAM" || return 1
  echo "export-patches: wrote $(find "$ROOT/patches" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ') patches; tree=$PQ_TREE_NEW"
}

case ${1:-} in
  --write) [ $# -eq 2 ] || usage; write_patches "$2" ;;
  '' | -*) usage ;;
  *) [ $# -eq 1 ] || usage; create_scratch "$1" ;;
esac
