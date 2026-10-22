#!/usr/bin/env bash
# Tests for scripts/verify-migration.sh: the pinned tag plus the queue and
# data/ics must equal a yurt commit's tree with every excluded path reset to
# its tag content, and the include/exclude census of tag..yurt must be clean.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"

VERIFY="$ROOT/scripts/verify-migration.sh"
export PQ_ICS_PATH=js/ics

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# Fixture lists: js is queue content; dom and other are excluded.
export PQ_LISTS_DIR="$BASE/lists"
mkdir -p "$PQ_LISTS_DIR"
printf 'js\n' >"$PQ_LISTS_DIR/include.txt"
printf 'dom\nother\n' >"$PQ_LISTS_DIR/exclude.txt"

# new_root: a fake repo root R (empty queue, corpus equal to the upstream's
# js/ics) and a yurt branch Y in the fixture upstream that changes js/a.txt,
# adds dom/x.txt and modifies other/b.txt. YURT is its commit.
new_root() {
  R=$(mktemp -d "$BASE/root.XXXXXX")
  URL="$R/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$R/patches" "$R/data/ics"
  cp -R "$URL/js/ics/." "$R/data/ics/"
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=0000000000000000000000000000000000000000\n' "$URL" "$SHA" >"$R/UPSTREAM"
  git -C "$URL" checkout -q -b yurt
  sed 's/^line5$/line5 yurt/' "$URL/js/a.txt" >"$URL/js/a.tmp"
  mv "$URL/js/a.tmp" "$URL/js/a.txt"
  mkdir -p "$URL/dom"
  echo browser-only >"$URL/dom/x.txt"
  echo changed >"$URL/other/b.txt"
  yurt_commit yurt
  export PQ_YURT_REPO=$URL PQ_DOM_COUNT=1
}

# yurt_commit <message>: commit everything on the fixture yurt branch.
yurt_commit() {
  git -C "$URL" add -A
  git -C "$URL" commit -q -m "$1"
  YURT=$(git -C "$URL" rev-parse HEAD)
}

# queue_from_yurt <paths...>: one patch carrying tag..yurt for <paths>.
queue_from_yurt() {
  git -C "$URL" diff --binary "$SHA" "$YURT" -- "$@" >"$R/patches/0001-yurt.patch"
}

# run_verify <args...>: run verify-migration.sh against $R; sets OUT and RC.
run_verify() {
  RC=0
  OUT=$(PQ_ROOT=$R "$VERIFY" "$@" 2>&1) || RC=$?
}

empty_queue_fails_listing_included_change() {
  new_root
  run_verify "$YURT"
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || { echo "rc $RC: $OUT"; return 1; }
  case $OUT in *js/a.txt*) ;; *) echo "included change not listed: $OUT"; return 1 ;; esac
  case $OUT in *dom/x.txt* | *other/b.txt*) echo "excluded path listed: $OUT"; return 1 ;; esac
}

matching_queue_passes() {
  new_root
  queue_from_yurt js
  run_verify "$YURT"
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *PASS*) ;; *) echo "no PASS: $OUT"; return 1 ;; esac
}

# An excluded path deleted in yurt is reset to (restored at) its tag content.
excluded_deletion_is_reset() {
  new_root
  git -C "$URL" rm -q other/b.txt
  yurt_commit "delete other"
  queue_from_yurt js
  run_verify "$YURT"
  assert_eq 0 "$RC" "$OUT"
}

# Carrying an excluded change in the queue is a difference.
excluded_change_in_queue_fails() {
  new_root
  queue_from_yurt js dom
  run_verify "$YURT"
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || { echo "rc $RC: $OUT"; return 1; }
  case $OUT in *dom/x.txt*) ;; *) echo "extra excluded file not listed: $OUT"; return 1 ;; esac
}

corpus_mismatch_fails() {
  new_root
  queue_from_yurt js
  echo stale >"$R/data/ics/README"
  run_verify "$YURT"
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || { echo "rc $RC: $OUT"; return 1; }
  case $OUT in *js/ics/README*) ;; *) echo "corpus difference not listed: $OUT"; return 1 ;; esac
}

# A path in neither list fails the census even when the trees are equal.
leftover_fails_even_with_equal_trees() {
  new_root
  mkdir -p "$URL/new"
  echo x >"$URL/new/thing.c"
  yurt_commit leftover
  queue_from_yurt js new
  run_verify "$YURT"
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || { echo "rc $RC: $OUT"; return 1; }
  case $OUT in *new/thing.c*) ;; *) echo "leftover not listed: $OUT"; return 1 ;; esac
}

dom_count_is_enforced() {
  new_root
  queue_from_yurt js
  PQ_DOM_COUNT=19
  run_verify "$YURT"
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || { echo "rc $RC: $OUT"; return 1; }
  case $OUT in *"dom/ file count"*) ;; *) echo "dom count not enforced: $OUT"; return 1 ;; esac
}

usage_errors() {
  new_root
  run_verify
  assert_eq 2 "$RC" "$OUT"
  unset PQ_YURT_REPO
  run_verify "$YURT"
  assert_eq 2 "$RC" "$OUT"
}

run_test empty_queue_fails_listing_included_change empty_queue_fails_listing_included_change
run_test matching_queue_passes matching_queue_passes
run_test excluded_deletion_is_reset excluded_deletion_is_reset
run_test excluded_change_in_queue_fails excluded_change_in_queue_fails
run_test corpus_mismatch_fails corpus_mismatch_fails
run_test leftover_fails_even_with_equal_trees leftover_fails_even_with_equal_trees
run_test dom_count_is_enforced dom_count_is_enforced
run_test usage_errors usage_errors
finish
