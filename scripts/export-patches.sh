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

create_scratch() {
  local scratch=$1 patch
  if [ -e "$scratch/.git" ]; then
    echo "export-patches: $scratch already exists; delete it to rebuild from the queue"
    return 0
  fi
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  pq_fetch "$scratch" || return 1
  # pq_git ignores the user's config, so name the committer of the am commits;
  # format-patch does not export it.
  export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-export-patches}
  export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-export-patches@localhost}
  # Not --3way: a patch that does not apply cleanly is a broken queue. --keep-cr
  # keeps CRLF files intact in the mailbox round trip, and --whitespace=nowarn
  # applies lines as they are, like pq_apply.
  while IFS= read -r patch; do
    pq_git -C "$scratch" am -q --no-3way --whitespace=nowarn --keep-cr "$patch" ||
      { echo "export-patches: failed to apply $patch" >&2; return 1; }
  done < <(find "$ROOT/patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
  mkdir -p "$scratch/.git/info" "$scratch/$ICS_PATH" || return 1
  printf '/%s/\n' "$ICS_PATH" >>"$scratch/.git/info/exclude"
  cp -R "$ROOT/data/ics/." "$scratch/$ICS_PATH/" || return 1
  echo "export-patches: scratch checkout ready at $scratch"
}

write_patches() {
  local scratch work touched f commits c n rc written want
  scratch=$(cd "$1" 2>/dev/null && pwd -P) || { echo "export-patches: no such scratch: $1" >&2; return 1; }
  pq_git -C "$scratch" rev-parse --git-dir >/dev/null 2>&1 ||
    { echo "export-patches: $scratch is not a git checkout" >&2; return 1; }
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  pq_git -C "$scratch" merge-base --is-ancestor "$PQ_COMMIT" HEAD ||
    { echo "export-patches: $scratch HEAD does not descend from pinned commit $PQ_COMMIT" >&2; return 1; }

  touched=$(pq_git -C "$scratch" log --no-renames --name-only --format= "$PQ_COMMIT..HEAD" -- "$ICS_PATH") || return 1
  if [ -n "$touched" ]; then
    printf '%s\n' "$touched" >&2
    echo "export-patches: commits touch $ICS_PATH; the corpus lives in data/ics" >&2
    return 1
  fi

  # format-patch drops merge commits and writes an empty commit as a patch that
  # does not apply, so neither can be exported.
  commits=$(pq_git -C "$scratch" rev-list "$PQ_COMMIT..HEAD") || return 1
  n=0
  for c in $commits; do
    n=$((n + 1)) rc=0
    pq_git -C "$scratch" rev-parse -q --verify "$c^2" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] ||
      { echo "export-patches: $c is a merge commit; make the scratch history linear" >&2; return 1; }
    rc=0
    pq_git -C "$scratch" diff-tree --quiet "$c" || rc=$?
    case $rc in
      0) echo "export-patches: $c is an empty commit; drop it from the scratch history" >&2; return 1 ;;
      1) ;;
      *) return 1 ;;
    esac
  done

  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' RETURN
  mkdir "$work/patches" || return 1
  # One .patch file per commit, nothing in it but the commit: no cover letter,
  # extra headers, threading, diffstat or signature, whatever the scratch config.
  pq_git -C "$scratch" format-patch -q --binary --no-signature --zero-commit --no-numbered \
    --abbrev=12 --no-stat --no-thread --suffix=.patch --no-cover-letter --no-add-header \
    --no-to --no-cc -o "$work/patches" "$PQ_COMMIT..HEAD" || return 1
  written=$(find "$work/patches" -maxdepth 1 -type f -name '*.patch' | wc -l | tr -d ' ')
  [ "$written" -eq "$n" ] ||
    { echo "export-patches: format-patch wrote $written .patch files for $n commits" >&2; return 1; }

  # Same path as check-queue: fresh clone, apply, corpus, stage, write-tree.
  pq_fetch "$work/tree" || return 1
  pq_apply "$work/tree" "$work/patches" "$ROOT/data/ics" || return 1
  PQ_TREE_NEW=$(pq_tree "$work/tree") || return 1

  # The replayed queue must be exactly the scratch: its HEAD tree plus the
  # corpus, staged the same way. Anything else lost or added content.
  pq_git -C "$work/tree" fetch -q "$scratch" HEAD || return 1
  pq_git -C "$work/tree" read-tree FETCH_HEAD || return 1
  pq_add_corpus "$work/tree" "$ROOT/data/ics" || return 1
  want=$(pq_tree "$work/tree") || return 1
  [ "$PQ_TREE_NEW" = "$want" ] || {
    echo "export-patches: the replayed patches give tree $PQ_TREE_NEW, which does not match scratch HEAD plus the corpus ($want); nothing written" >&2
    return 1
  }

  mkdir -p "$ROOT/patches" || return 1
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
