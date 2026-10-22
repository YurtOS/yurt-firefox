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
  local scratch=$1 made= entries
  if [ -e "$scratch/.git" ]; then
    echo "export-patches: $scratch already exists; delete it to rebuild from the queue"
    return 0
  fi
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  if [ -e "$scratch" ]; then
    [ -d "$scratch" ] || { echo "export-patches: $scratch is not a directory" >&2; return 1; }
    entries=$(ls -A "$scratch") || { echo "export-patches: cannot list $scratch" >&2; return 1; }
    [ -z "$entries" ] || { echo "export-patches: $scratch is not empty" >&2; return 1; }
  else
    made=1
  fi
  # From here on a failure would leave a scratch with part of the queue, which
  # --write would export as the whole queue, so it is discarded.
  build_scratch "$scratch" || { discard_scratch "$scratch" "$made"; return 1; }
  echo "export-patches: scratch checkout ready at $scratch"
}

# build_scratch <scratch>: fetch the pin into the empty <scratch>, apply the
# queue with git am and copy the corpus in, untracked.
build_scratch() {
  local scratch=$1 list patch
  pq_fetch "$scratch" || return 1
  # pq_git ignores the user's config, so name the committer of the am commits;
  # format-patch does not export it.
  export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-export-patches}
  export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-export-patches@localhost}
  # Not --3way: a patch that does not apply cleanly is a broken queue. --keep-cr
  # keeps CRLF files intact in the mailbox round trip, and --whitespace=nowarn
  # applies lines as they are, like pq_apply.
  list=$(pq_list_patches "$ROOT/patches") || return 1
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    pq_git -C "$scratch" am -q --no-3way --whitespace=nowarn --keep-cr "$patch" ||
      { echo "export-patches: failed to apply $patch" >&2; return 1; }
  done <<<"$list"
  mkdir -p "$scratch/.git/info" "$scratch/$ICS_PATH" || return 1
  printf '/%s/\n' "$ICS_PATH" >>"$scratch/.git/info/exclude" || return 1
  cp -R "$ROOT/data/ics/." "$scratch/$ICS_PATH/" || return 1
}

# discard_scratch <scratch> <made>: remove a failed scratch build: the directory
# if this run made it, else only what was put in it (it was empty).
discard_scratch() {
  if [ -n "$2" ]; then
    rm -rf "$1"
  else
    find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi || { echo "export-patches: cannot remove the failed scratch build at $1; delete it before using it" >&2; return 1; }
  echo "export-patches: removed the failed scratch build at $1" >&2
}

write_patches() {
  local scratch work touched commits c n rc written want stage= keep= list f
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
  # Read line by line: a caller that sources this script may have changed IFS.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
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
  done <<<"$commits"

  work=$(mktemp -d) || return 1
  # $stage is kept when a failed publish could not restore the old patches.
  trap 'rm -rf "$work"; [ -z "$stage" ] || [ -n "$keep" ] || rm -rf "$stage"; trap - RETURN' RETURN
  mkdir "$work/patches" || return 1
  # One .patch file per commit, nothing in it but the commit: no cover letter,
  # extra headers, threading, diffstat or signature, and the default context,
  # renames, prefixes, subject and encoding, whatever the scratch config.
  pq_git -C "$scratch" format-patch -q --binary --no-signature --zero-commit --no-numbered \
    --abbrev=12 --no-stat --no-thread --suffix=.patch --no-cover-letter --no-add-header \
    --no-to --no-cc --no-attach -U3 -M --src-prefix=a/ --dst-prefix=b/ --subject-prefix=PATCH \
    --encoding=UTF-8 -o "$work/patches" "$PQ_COMMIT..HEAD" || return 1
  list=$(pq_list_patches "$work/patches") || return 1
  written=0
  while IFS= read -r f; do [ -z "$f" ] || written=$((written + 1)); done <<<"$list"
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

  # Stage the new queue next to patches/ (same filesystem, so publishing is a
  # series of renames) and check it before anything published is touched.
  mkdir -p "$ROOT/patches" || return 1
  stage=$(mktemp -d "$ROOT/.export-stage.XXXXXX") || return 1
  mkdir "$stage/new" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp "$f" "$stage/new/" || { echo "export-patches: cannot stage $f; nothing written" >&2; return 1; }
  done <<<"$list"
  list=$(pq_list_patches "$stage/new") || return 1
  written=0
  while IFS= read -r f; do [ -z "$f" ] || written=$((written + 1)); done <<<"$list"
  [ "$written" -eq "$n" ] ||
    { echo "export-patches: staged $written patches for $n commits; nothing written" >&2; return 1; }
  awk -v t="$PQ_TREE_NEW" '/^tree=/ { print "tree=" t; next } { print }' "$ROOT/UPSTREAM" >"$stage/UPSTREAM" ||
    { echo "export-patches: cannot stage UPSTREAM; nothing written" >&2; return 1; }

  publish "$stage" || return 1
  echo "export-patches: wrote $n patches; tree=$PQ_TREE_NEW"
}

# publish <stage>: replace patches/*.patch with <stage>/new/*.patch and UPSTREAM
# with <stage>/UPSTREAM, by renames. If a step fails, put the old files back.
publish() {
  local stage=$1 list f
  mkdir "$stage/old" || return 1
  list=$(pq_list_patches "$ROOT/patches") || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv "$f" "$stage/old/" || { unpublish "$stage" old; return 1; }
  done <<<"$list"
  list=$(pq_list_patches "$stage/new") || { unpublish "$stage" old; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv "$f" "$ROOT/patches/" || { unpublish "$stage" new; return 1; }
  done <<<"$list"
  mv "$stage/UPSTREAM" "$ROOT/UPSTREAM" || { unpublish "$stage" new; return 1; }
}

# unpublish <stage> <old|new>: undo a failed publish. "new" means new patches may
# already be in patches/ (the old ones are then all in <stage>/old). UPSTREAM is
# only ever replaced by the last, atomic rename, so it is still the old one. If
# the old patches cannot be put back, keep <stage> and say where they are.
unpublish() {
  local stage=$1 placed=$2 list f ok=1
  if [ "$placed" = new ]; then
    if list=$(pq_list_patches "$ROOT/patches"); then
      while IFS= read -r f; do
        [ -z "$f" ] || rm -f "$f" || ok=
      done <<<"$list"
    else
      ok=
    fi
  fi
  if list=$(pq_list_patches "$stage/old"); then
    while IFS= read -r f; do
      [ -z "$f" ] || mv "$f" "$ROOT/patches/" || ok=
    done <<<"$list"
  else
    ok=
  fi
  if [ -n "$ok" ]; then
    echo "export-patches: could not publish the new queue; patches/ and UPSTREAM are unchanged" >&2
  else
    keep=1
    echo "export-patches: could not publish the new queue or restore the old one; the old patches are in $stage/old and UPSTREAM is unchanged" >&2
  fi
}

case ${1:-} in
  --write) [ $# -eq 2 ] || usage; write_patches "$2" ;;
  '' | -*) usage ;;
  *) [ $# -eq 1 ] || usage; create_scratch "$1" ;;
esac
