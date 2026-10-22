#!/usr/bin/env bash
# Tests for scripts/check-queue.sh. Accepts --fixtures (the only mode; it builds
# its own offline upstream). check-queue.sh --fixtures runs this file, so these
# cases call check-queue.sh only in non-fixture mode.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"

CHECK="$ROOT/scripts/check-queue.sh"
export PQ_ICS_PATH=js/ics

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# new_root: a fake repo root R with patches/, data/ics and a fixture upstream.
new_root() {
  R=$(mktemp -d "$BASE/root.XXXXXX")
  URL="$R/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$R/patches" "$R/data/ics"
  echo one >"$R/data/ics/one.txt"
}

# queue_tree: tree of the fixture upstream plus the corpus, built by hand.
queue_tree() {
  local s=$BASE/s.$$
  rm -rf "$s"
  git clone -q "$URL" "$s"
  mkdir -p "$s/js/ics"
  cp -R "$R/data/ics/." "$s/js/ics/"
  git -C "$s" add -A
  git -C "$s" write-tree
}

write_upstream() {
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=%s\n' "$URL" "$SHA" "$1" >"$R/UPSTREAM"
}

# run_check <args...>: run check-queue.sh against $R; sets OUT and RC.
run_check() {
  RC=0
  OUT=$(PQ_ROOT=$R "$CHECK" "$@" 2>&1) || RC=$?
}

refuses_without_upstream() {
  new_root
  run_check
  assert_eq 2 "$RC"
  case $OUT in *"UPSTREAM not initialised"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
}

refuses_placeholder_upstream() {
  new_root
  cp "$ROOT/UPSTREAM.example" "$R/UPSTREAM"
  run_check
  assert_eq 2 "$RC"
  case $OUT in *"UPSTREAM not initialised"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  # A real url with a zero commit or tree is still a placeholder.
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=%s\n' "$URL" "$SHA" 0000000000000000000000000000000000000000 >"$R/UPSTREAM"
  run_check
  assert_eq 2 "$RC"
}

passes_when_tree_matches() {
  new_root
  write_upstream "$(queue_tree)"
  run_check
  assert_eq 0 "$RC" "$OUT"
}

fails_on_tree_mismatch() {
  new_root
  write_upstream "$(queue_tree)"
  echo changed >"$R/data/ics/one.txt"
  run_check
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ]
  case $OUT in *"tree mismatch"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
}

fails_on_moved_tag() {
  new_root
  write_upstream "$(queue_tree)"
  echo moved >"$URL/moved.txt"
  git -C "$URL" add -A
  git -C "$URL" commit -q -m moved
  git -C "$URL" tag -f V1 >/dev/null
  run_check
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ]
  case $OUT in *"pinned commit"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
}

runs_census_when_configured() {
  new_root
  write_upstream "$(queue_tree)"
  git -C "$URL" checkout -q -b yurt
  mkdir "$URL/new"
  echo x >"$URL/new/thing.c"
  git -C "$URL" add -A
  git -C "$URL" commit -q -m extra
  export PQ_YURT_REPO=$URL PQ_YURT_REF=yurt PQ_DOM_COUNT=0
  run_check
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ]
  case $OUT in *new/thing.c*) ;; *) echo "leftover not reported: $OUT"; return 1 ;; esac
}

census_skipped_is_announced() {
  new_root
  write_upstream "$(queue_tree)"
  run_check
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *"census skipped (PQ_YURT_REPO unset)"*) ;; *) echo "no skip notice: $OUT"; return 1 ;; esac
}

passes_census_when_clean() {
  new_root
  write_upstream "$(queue_tree)"
  git -C "$URL" checkout -q -b yurt
  echo y >"$URL/js/y.txt"
  git -C "$URL" add -A
  git -C "$URL" commit -q -m included
  export PQ_YURT_REPO=$URL PQ_YURT_REF=yurt PQ_DOM_COUNT=0
  run_check
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *"census ok"*) ;; *) echo "no census ok: $OUT"; return 1 ;; esac
}

run_test refuses_without_upstream refuses_without_upstream
run_test refuses_placeholder_upstream refuses_placeholder_upstream
run_test passes_when_tree_matches passes_when_tree_matches
run_test fails_on_tree_mismatch fails_on_tree_mismatch
run_test fails_on_moved_tag fails_on_moved_tag
run_test runs_census_when_configured runs_census_when_configured
run_test census_skipped_is_announced census_skipped_is_announced
run_test passes_census_when_clean passes_census_when_clean
finish
