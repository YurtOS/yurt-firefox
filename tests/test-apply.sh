#!/usr/bin/env bash
# Tests for scripts/lib/patch-queue.sh: pin, fetch, apply, tree identity.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"
# Sourced tolerantly so that, before it exists, every case fails on its own.
# shellcheck source=../scripts/lib/patch-queue.sh
if [ -f "$ROOT/scripts/lib/patch-queue.sh" ]; then
  . "$ROOT/scripts/lib/patch-queue.sh"
else
  echo "WARN: scripts/lib/patch-queue.sh missing" >&2
fi

export PQ_ICS_PATH=js/ics

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# --- helpers ----------------------------------------------------------------

# new_case: fresh upstream fixture and work dir; sets T (work dir), SHA, URL.
new_case() {
  T=$(mktemp -d "$BASE/case.XXXXXX")
  URL="$T/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$T/patches" "$T/ics"
  S="$T/scratch"
  write_pin "$T/UPSTREAM.tmp" "$SHA" unset
  pq_read_pin "$T/UPSTREAM.tmp"
  pq_fetch "$S"
}

# write_pin <file> <commit> <tree>
write_pin() {
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=%s\n' "$URL" "$2" "$3" >"$1"
}

# Edits are done in the scratch clone S and recorded as patches by `git diff`.
# step <patch-name>: commit what is in S and save that commit as a patch.
step() {
  git -C "$S" add -A
  git -C "$S" commit -q -m "$1"
  git -C "$S" diff --no-color --src-prefix=a/ --dst-prefix=b/ HEAD~1 HEAD >"$T/patches/$1.patch"
}

# replace_line <file> <old> <new>
replace_line() {
  awk -v o="$2" -v n="$3" '$0 == o { print n; next } { print }' "$1" >"$1.new"
  mv "$1.new" "$1"
}

# add_corpus: two corpus files in $T/ics, mirrored into S.
add_corpus() {
  echo one >"$T/ics/one.txt"
  echo two >"$T/ics/two.txt"
  cp "$T/ics/one.txt" "$T/ics/two.txt" "$S/js/ics/"
}

# expected_tree: tree of S (all queue steps + corpus), built without pq_*.
expected_tree() {
  git -C "$S" add -A
  git -C "$S" write-tree
}

# apply_queue: fresh pinned clone, applied; sets W, prints nothing.
apply_queue() {
  W="$T/work"
  pq_read_pin "$T/UPSTREAM.tmp"
  pq_fetch "$W"
  pq_apply "$W" "$T/patches" "$T/ics"
}

# basic_queue: 2 patches + 2 corpus files; sets EXPECTED.
basic_queue() {
  replace_line "$S/js/a.txt" line5 "line5 patched"
  step 0001-edit-a
  echo c >"$S/other/c.txt"
  step 0002-add-c
  add_corpus
  EXPECTED=$(expected_tree)
}

# scan_forbidden <dir...>: succeed (printing hits) if a non-comment line uses a
# forbidden apply flag.
scan_forbidden() {
  grep -rnE -e '--(3way|reject|ignore-whitespace|ignore-space-change|unidiff-zero)' \
    -e '(^|[[:space:]])-3([[:space:]]|$)' "$@" 2>/dev/null |
    grep -Ev '^[^:]*:[0-9]+:[[:space:]]*#'
}

# --- cases --------------------------------------------------------------------

applies_clean_queue_and_tree_matches_pin() {
  new_case
  basic_queue
  write_pin "$T/UPSTREAM.tmp" "$SHA" "$EXPECTED"
  apply_queue
  assert_eq "$PQ_TREE" "$(pq_tree "$W")" "applied tree equals pinned tree"
  assert_eq "ics readme" "$(cat "$W/js/ics/README")" "existing corpus file kept (no --delete)"
  assert_eq one "$(cat "$W/js/ics/one.txt")"
}

rejects_moved_tag() {
  local msg
  new_case
  write_pin "$T/UPSTREAM.tmp" "$SHA" unset
  pq_read_pin "$T/UPSTREAM.tmp"
  pq_fetch "$T/ok"
  echo moved >"$URL/moved.txt"
  git -C "$URL" add -A
  git -C "$URL" commit -q -m moved
  git -C "$URL" tag -f V1 >/dev/null
  msg=$(pq_fetch "$T/bad" 2>&1) && return 1
  case $msg in *"tag V1 is"*"pinned commit is"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
}

fetch_accepts_annotated_tag() {
  new_case
  git -C "$URL" tag -d V1 >/dev/null
  git -C "$URL" tag -a -m annotated V1 "$SHA"
  pq_fetch "$T/ann"
  assert_eq "$SHA" "$(git -C "$T/ann" rev-parse HEAD)"
}

fetch_refuses_non_empty_dest() {
  local msg
  new_case
  mkdir "$T/full" "$T/empty"
  echo keep >"$T/full/file"
  msg=$(pq_fetch "$T/full" 2>&1) && return 1
  case $msg in *"not empty"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  assert_eq keep "$(cat "$T/full/file")" "existing file untouched"
  [ ! -e "$T/full/.git" ]
  pq_fetch "$T/empty"
  assert_eq "$SHA" "$(git -C "$T/empty" rev-parse HEAD)" "empty existing dest is accepted"
}

rejects_context_drift() {
  local msg
  new_case
  replace_line "$S/js/a.txt" line5 "line5 patched"
  step 0001-edit-a
  add_corpus
  # The unaltered patch applies, so the failure below is due to the drift.
  apply_queue
  rm -rf "$W"
  # Altered context: must fail.
  sed 's/^ line4$/ lineX/' "$T/patches/0001-edit-a.patch" >"$T/patches/0001-edit-a.new"
  mv "$T/patches/0001-edit-a.new" "$T/patches/0001-edit-a.patch"
  msg=$(apply_queue 2>&1) && return 1
  case $msg in *"failed to apply"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
}

applies_trailing_whitespace_unchanged() {
  new_case
  printf 'ws \n' >>"$S/js/a.txt"
  step 0001-ws
  grep -q '^+ws $' "$T/patches/0001-ws.patch"
  add_corpus
  EXPECTED=$(expected_tree)
  apply_queue
  assert_eq "$EXPECTED" "$(pq_tree "$W")" "trailing whitespace preserved"
}

applies_with_line_offset() {
  new_case
  # Base the patch on a file with 3 extra leading lines so its hunk is offset.
  printf 'x1\nx2\nx3\n' | cat - "$S/js/a.txt" >"$S/js/a.txt.new"
  mv "$S/js/a.txt.new" "$S/js/a.txt"
  git -C "$S" add -A
  git -C "$S" commit -q -m prefix
  replace_line "$S/js/a.txt" line5 "line5 patched"
  step 0001-edit-a
  grep -q '^@@ -5,' "$T/patches/0001-edit-a.patch"
  # The expected tree comes from the unprefixed file.
  git -C "$S" reset -q --hard HEAD~2
  replace_line "$S/js/a.txt" line5 "line5 patched"
  add_corpus
  EXPECTED=$(expected_tree)
  apply_queue
  assert_eq "$EXPECTED" "$(pq_tree "$W")" "offset hunk applied"
}

corpus_in_hash() {
  new_case
  basic_queue
  apply_queue
  assert_eq "$EXPECTED" "$(pq_tree "$W")" "baseline"
  # Corpus file unstaged: not in the tree.
  git -C "$W" rm -q --cached js/ics/two.txt
  [ "$EXPECTED" != "$(pq_tree "$W")" ]
  # Corpus file missing from the corpus dir: different tree.
  rm "$T/ics/two.txt"
  rm -rf "$T/work"
  apply_queue
  [ "$EXPECTED" != "$(pq_tree "$W")" ]
}

overlap_and_delete() {
  new_case
  printf 'n1\nn2\n' >"$T/ins"
  awk 'NR==3 { while ((getline l < "'"$T/ins"'") > 0) print l } { print }' "$S/js/a.txt" >"$S/js/a.txt.new"
  mv "$S/js/a.txt.new" "$S/js/a.txt"
  step 0001-insert
  replace_line "$S/js/a.txt" n1 "n1 edited"
  echo d >"$S/other/d.txt"
  step 0002-edit-inserted
  git -C "$S" rm -q other/d.txt
  step 0003-delete-d
  add_corpus
  EXPECTED=$(expected_tree)
  apply_queue
  assert_eq "$EXPECTED" "$(pq_tree "$W")"
  [ ! -e "$W/other/d.txt" ]
}

forbidden_flags_absent() {
  # The scan must not be vacuous: the library has to exist and be scanned...
  [ -f "$ROOT/scripts/lib/patch-queue.sh" ]
  local dirs="$ROOT/scripts"
  [ -d "$ROOT/.github/workflows" ] && dirs="$dirs $ROOT/.github/workflows"
  # shellcheck disable=SC2086
  assert_fails scan_forbidden $dirs
  # ...and able to see a violation, but not a comment mentioning one.
  mkdir "$BASE/scan"
  printf '# --3way is forbidden\n' >"$BASE/scan/comment.sh"
  assert_fails scan_forbidden "$BASE/scan"
  printf 'git apply --index --3way p\n' >"$BASE/scan/bad.sh"
  scan_forbidden "$BASE/scan" >/dev/null
  local flag
  for flag in -3 --ignore-space-change; do
    printf 'git apply --index %s p\n' "$flag" >"$BASE/scan/bad.sh"
    scan_forbidden "$BASE/scan" >/dev/null
  done
}

guard() {
  new_case
  basic_queue
  local msg

  # HEAD not at PQ_COMMIT.
  pq_fetch "$T/moved"
  echo x >"$T/moved/x.txt"
  git -C "$T/moved" add -A
  git -C "$T/moved" commit -q -m extra
  msg=$(pq_apply "$T/moved" "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"not at pinned commit"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac

  # Dirty tree.
  pq_fetch "$T/dirty"
  echo x >"$T/dirty/untracked.txt"
  msg=$(pq_apply "$T/dirty" "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"not clean"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac

  # The caller's own repo toplevel, even though it is clean and at PQ_COMMIT.
  pq_fetch "$T/mine"
  msg=$(cd "$T/mine" && pq_apply "$T/mine" "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"caller's repository"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  msg=$(cd "$T/mine" && pq_apply . "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"caller's repository"*) ;; *) echo "wrong reason (.): $msg"; return 1 ;; esac
  # A subdirectory of a repo is not a worktree toplevel.
  msg=$(pq_apply "$T/mine/js" "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"not a repository toplevel"*) ;; *) echo "wrong reason (sub): $msg"; return 1 ;; esac

  # A clean pq_fetch clone is accepted and gets the queue.
  pq_fetch "$T/good"
  pq_apply "$T/good" "$T/patches" "$T/ics"
  assert_eq "$EXPECTED" "$(pq_tree "$T/good")"
}

run_test applies_clean_queue_and_tree_matches_pin applies_clean_queue_and_tree_matches_pin
run_test rejects_moved_tag rejects_moved_tag
run_test fetch_accepts_annotated_tag fetch_accepts_annotated_tag
run_test fetch_refuses_non_empty_dest fetch_refuses_non_empty_dest
run_test rejects_context_drift rejects_context_drift
run_test applies_trailing_whitespace_unchanged applies_trailing_whitespace_unchanged
run_test applies_with_line_offset applies_with_line_offset
run_test corpus_in_hash corpus_in_hash
run_test overlap_and_delete overlap_and_delete
run_test forbidden_flags_absent forbidden_flags_absent
run_test guard guard
finish
