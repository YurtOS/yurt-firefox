#!/usr/bin/env bash
# Migration equality check.
#   verify-migration.sh <yurt-sha>
# Fresh fetch of the pinned tag, apply the queue and data/ics, and require the
# resulting tree to equal <yurt-sha>'s tree with every path the census
# classifies as excluded reset to its content at the pinned commit (or removed
# if absent there). Also runs the include/exclude census over tag..<yurt-sha>.
# PQ_YURT_REPO (required) is a repository holding <yurt-sha> and the pinned
# commit; it is only read (its objects are borrowed as an alternate by the
# temporary clone). PQ_DOM_COUNT (default 19) is the expected dom/ file count.
# PQ_ROOT overrides the repository root (tests use it). Every git call goes
# through pq_git (see scripts/lib/patch-queue.sh); a step that cannot be read
# fails the run.
# Exit codes: 0 equal, 1 different or failed, 2 bad usage.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

usage() {
  echo "usage: PQ_YURT_REPO=<repo> verify-migration.sh <yurt-sha>" >&2
  exit 2
}

verify() {
  local yurt work objects census=0 path class rc entry mode type blob rest
  local queue expected included=0 excluded=0 leftover=0
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  yurt=$(pq_git -C "$PQ_YURT_REPO" rev-parse -q --verify --end-of-options "$1^{commit}") ||
    { echo "verify-migration: $1 is not a commit in $PQ_YURT_REPO" >&2; return 1; }

  PQ_DIFF_REPO=$PQ_YURT_REPO pq_leftover "$PQ_COMMIT" "$yurt" "${PQ_DOM_COUNT:-19}" || census=1

  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"; trap - RETURN' RETURN
  pq_fetch "$work/tree" || return 1
  pq_apply "$work/tree" "$ROOT/patches" "$ROOT/data/ics" || return 1
  queue=$(pq_tree "$work/tree") || return 1

  objects=$(pq_git -C "$PQ_YURT_REPO" rev-parse --path-format=absolute --git-path objects) && [ -n "$objects" ] ||
    { echo "verify-migration: cannot find the objects of $PQ_YURT_REPO" >&2; return 1; }
  printf '%s\n' "$objects" >>"$work/tree/.git/objects/info/alternates" || return 1
  pq_git -C "$work/tree" cat-file -e "$yurt^{commit}" ||
    { echo "verify-migration: $yurt is not readable through $objects" >&2; return 1; }

  # Expected tree: yurt with each excluded path reset to the pinned commit. The
  # queue tree is written, so the clone's index is free to build it in.
  # NUL-separated so that git does not quote unusual paths (see pq_leftover).
  pq_git -C "$work/tree" read-tree "$yurt" || return 1
  pq_git -C "$work/tree" diff --name-only -z --no-renames "$PQ_COMMIT" "$yurt" >"$work/changed" ||
    { echo "verify-migration: cannot diff $PQ_COMMIT $yurt" >&2; return 1; }
  while IFS= read -r -d '' path; do
    rc=0
    class=$(pq_classify "$path" 2>"$work/classify.err") || rc=$?
    case $rc in
      0) ;;
      2) class=leftover ;;
      *) cat "$work/classify.err" >&2; return 1 ;;
    esac
    case $class in
      leftover) leftover=$((leftover + 1)) ;;
      include) included=$((included + 1)) ;;
      exclude)
        excluded=$((excluded + 1))
        entry=$(pq_git --literal-pathspecs -C "$work/tree" ls-tree "$PQ_COMMIT" -- "$path") || return 1
        if [ -n "$entry" ]; then
          # "<mode> SP <type> SP <object> TAB <path>"; split by hand, not by IFS.
          mode=${entry%% *} rest=${entry#* }
          type=${rest%% *} rest=${rest#* }
          blob=${rest%%$'\t'*}
          [ "$type" = blob ] || { echo "verify-migration: $path is a $type at the tag" >&2; return 1; }
          pq_git -C "$work/tree" update-index --add --cacheinfo "$mode,$blob,$path" || return 1
        else
          pq_git -C "$work/tree" update-index --force-remove -- "$path" || return 1
        fi
        ;;
      *) echo "verify-migration: unexpected class for $path: $class" >&2; return 1 ;;
    esac
  done <"$work/changed"
  expected=$(pq_tree "$work/tree") || return 1

  echo "verify-migration: $((included + excluded + leftover)) paths changed in tag..$yurt:" \
    "$included included, $excluded excluded (reset to the tag), $leftover in neither list"
  if [ "$queue" != "$expected" ]; then
    echo "verify-migration: queue tree $queue differs from expected $expected (status: expected -> queue):"
    pq_git -C "$work/tree" diff-tree -r --no-renames --name-status "$expected" "$queue" || return 1
    echo "verify-migration: FAIL tree differs" >&2
    return 1
  fi
  if [ "$census" -ne 0 ]; then
    echo "verify-migration: FAIL census" >&2
    return 1
  fi
  echo "verify-migration: PASS tree=$queue"
}

[ $# -eq 1 ] || usage
[ -n "${PQ_YURT_REPO:-}" ] || { echo "verify-migration: PQ_YURT_REPO is required" >&2; usage; }
verify "$1"
