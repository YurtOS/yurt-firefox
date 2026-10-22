#!/usr/bin/env bash
# Patch queue library: read the upstream pin, fetch it, apply the queue and
# report the resulting tree. Source it; it defines functions only.
#
# Functions return non-zero with a "pq:" message on stderr instead of relying on
# `set -e`, which does not apply inside callers' `if`/`||` contexts. None of them
# reset, clean or check out a tree the caller supplied.

# pq_read_pin <upstream-file>: set PQ_URL PQ_TAG PQ_COMMIT PQ_TREE from key=value lines.
pq_read_pin() {
  local file=$1 key value
  PQ_URL= PQ_TAG= PQ_COMMIT= PQ_TREE=
  [ -f "$file" ] || { echo "pq: no upstream file: $file" >&2; return 1; }
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case $key in
      url) PQ_URL=$value ;;
      tag) PQ_TAG=$value ;;
      commit) PQ_COMMIT=$value ;;
      tree) PQ_TREE=$value ;;
      '' | '#'*) ;;
      *) echo "pq: unknown key in $file: $key" >&2; return 1 ;;
    esac
  done <"$file"
  [ -n "$PQ_URL" ] && [ -n "$PQ_TAG" ] && [ -n "$PQ_COMMIT" ] && [ -n "$PQ_TREE" ] ||
    { echo "pq: $file must set url, tag, commit and tree" >&2; return 1; }
}

# pq_fetch <dest>: shallow-fetch PQ_TAG into a new repo at <dest>; fail if it
# is not PQ_COMMIT.
pq_fetch() {
  local dest=$1 head
  git init -q "$dest" || return 1
  git -C "$dest" fetch -q --depth 1 "$PQ_URL" tag "$PQ_TAG" || return 1
  git -C "$dest" checkout -q --detach FETCH_HEAD || return 1
  head=$(git -C "$dest" rev-parse HEAD) || return 1
  [ "$head" = "$PQ_COMMIT" ] ||
    { echo "pq: tag $PQ_TAG is $head, pinned commit is $PQ_COMMIT" >&2; return 1; }
}

# pq_apply <worktree> <patches-dir> <data-ics-dir>: apply the queue, then lay
# the corpus over $PQ_ICS_PATH (default js/src/ics) and stage it.
pq_apply() {
  local wt patches ics ics_path patch top mine
  wt=$(cd "$1" 2>/dev/null && pwd -P) || { echo "pq: no such worktree: $1" >&2; return 1; }
  patches=$(cd "$2" 2>/dev/null && pwd -P) || { echo "pq: no such patches dir: $2" >&2; return 1; }
  ics=$(cd "$3" 2>/dev/null && pwd -P) || { echo "pq: no such corpus dir: $3" >&2; return 1; }
  ics_path=${PQ_ICS_PATH:-js/src/ics}

  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) ||
    { echo "pq: $wt is not a git worktree" >&2; return 1; }
  [ "$top" = "$wt" ] || { echo "pq: $wt is not a repository toplevel" >&2; return 1; }
  if mine=$(git rev-parse --show-toplevel 2>/dev/null); then
    mine=$(cd "$mine" && pwd -P)
    [ "$mine" != "$wt" ] || { echo "pq: refusing the caller's repository: $wt" >&2; return 1; }
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$PQ_COMMIT" ] ||
    { echo "pq: $wt is not at pinned commit $PQ_COMMIT" >&2; return 1; }
  [ -z "$(git -C "$wt" status --porcelain)" ] ||
    { echo "pq: $wt is not clean" >&2; return 1; }

  while IFS= read -r patch; do
    git -C "$wt" apply --index --whitespace=nowarn "$patch" ||
      { echo "pq: failed to apply $patch" >&2; return 1; }
  done < <(find "$patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)

  mkdir -p "$wt/$ics_path" || return 1
  cp -R "$ics/." "$wt/$ics_path/" || return 1
  git -C "$wt" add -- "$ics_path" || return 1
}

# pq_tree <worktree>: print the tree hash of the index.
pq_tree() {
  git -C "$1" write-tree
}
