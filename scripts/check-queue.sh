#!/usr/bin/env bash
# Verify the patch queue.
#   check-queue.sh --fixtures  run the offline fixture suites
#   check-queue.sh             fresh fetch of the pinned tag, apply the queue and
#                              data/ics, compare the tree hash with UPSTREAM; if
#                              PQ_YURT_REPO is set, also run the include/exclude
#                              census there (PQ_YURT_REF default "yurt",
#                              PQ_DOM_COUNT default 19)
# PQ_ROOT overrides the repository root (tests use it).
# Exit codes: 0 ok, 1 failed, 2 UPSTREAM not initialised or bad usage.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

ZERO=0000000000000000000000000000000000000000

run_fixtures() {
  local t failed=0
  for t in test-fixture.sh test-apply.sh test-classify.sh test-check-queue.sh; do
    echo "== $t"
    if [ "$t" = test-check-queue.sh ]; then
      bash "$SELF/tests/$t" --fixtures || failed=1
    else
      bash "$SELF/tests/$t" || failed=1
    fi
  done
  [ "$failed" -eq 0 ] || { echo "check-queue: fixtures failed" >&2; return 1; }
}

run_queue() {
  local work tree
  if [ ! -f "$ROOT/UPSTREAM" ]; then
    echo "check-queue: UPSTREAM not initialised (no $ROOT/UPSTREAM)" >&2
    return 2
  fi
  pq_read_pin "$ROOT/UPSTREAM" || return 1
  case $PQ_URL in *example.invalid*) PQ_COMMIT=$ZERO ;; esac
  if [ "$PQ_COMMIT" = "$ZERO" ] || [ "$PQ_TREE" = "$ZERO" ]; then
    echo "check-queue: UPSTREAM not initialised (placeholder values)" >&2
    return 2
  fi

  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' RETURN
  pq_fetch "$work/tree" || return 1
  pq_apply "$work/tree" "$ROOT/patches" "$ROOT/data/ics" || return 1
  tree=$(pq_tree "$work/tree") || return 1
  if [ "$tree" != "$PQ_TREE" ]; then
    echo "check-queue: tree mismatch: UPSTREAM says $PQ_TREE, applied queue is $tree" >&2
    return 1
  fi
  echo "check-queue: tree ok ($tree)"

  if [ -n "${PQ_YURT_REPO:-}" ]; then
    PQ_DIFF_REPO=$PQ_YURT_REPO pq_leftover "$PQ_TAG" "${PQ_YURT_REF:-yurt}" "${PQ_DOM_COUNT:-19}" ||
      { echo "check-queue: census failed" >&2; return 1; }
    echo "check-queue: census ok"
  fi
}

case ${1:-} in
  --fixtures) run_fixtures ;;
  '') run_queue ;;
  *) echo "usage: check-queue.sh [--fixtures]" >&2; exit 2 ;;
esac
