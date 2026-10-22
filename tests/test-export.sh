#!/usr/bin/env bash
# Tests for scripts/export-patches.sh, the dev loop: build a scratch checkout from
# the queue, commit edits there, export them back as patches and re-pin the tree.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO

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

EXPORT="$ROOT/scripts/export-patches.sh"
export PQ_ICS_PATH=js/ics

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# --- helpers ----------------------------------------------------------------

# new_root: a fake repo root R with an empty queue, one corpus file and a
# fixture upstream; S is the scratch path (not yet created).
new_root() {
  R=$(mktemp -d "$BASE/root.XXXXXX")
  URL="$R/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$R/patches" "$R/data/ics"
  echo one >"$R/data/ics/one.txt"
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=unset\n' "$URL" "$SHA" >"$R/UPSTREAM"
  S="$R/scratch"
}

# export_cmd <args...>: run export-patches.sh against $R.
export_cmd() {
  PQ_ROOT=$R "$EXPORT" "$@"
}

# scratch_commit <message> [git commit args]: commit everything in S.
scratch_commit() {
  local msg=$1
  shift
  git -C "$S" add -A
  git -C "$S" commit -q -m "$msg" "$@"
}

# pin_tree: the tree recorded in $R/UPSTREAM.
pin_tree() {
  pq_read_pin "$R/UPSTREAM"
  echo "$PQ_TREE"
}

# fresh_apply_tree <dir>: tree from a fresh pinned clone with the queue applied.
fresh_apply_tree() {
  pq_read_pin "$R/UPSTREAM"
  pq_fetch "$1"
  pq_apply "$1" "$R/patches" "$R/data/ics"
  pq_tree "$1"
}

# fresh_am_tree <dir>: tree from a fresh pinned clone with the queue applied by
# git am, then the corpus staged.
fresh_am_tree() {
  local p
  pq_read_pin "$R/UPSTREAM"
  pq_fetch "$1"
  for p in "$R"/patches/*.patch; do
    git -C "$1" am -q --no-3way --keep-cr "$p"
  done
  mkdir -p "$1/$PQ_ICS_PATH"
  cp -R "$R/data/ics/." "$1/$PQ_ICS_PATH/"
  git -C "$1" add -- "$PQ_ICS_PATH"
  git -C "$1" write-tree
}

# hand_tree <dir>: HEAD of the scratch checkout plus the corpus, in a private
# index so the checkout itself is not touched.
hand_tree() {
  local idx=$BASE/idx.$$
  rm -f "$idx"
  GIT_INDEX_FILE=$idx git -C "$1" read-tree HEAD
  local f rel
  for f in "$R"/data/ics/*; do
    rel=$PQ_ICS_PATH/${f##*/}
    GIT_INDEX_FILE=$idx git -C "$1" update-index --add --cacheinfo "100644,$(git -C "$1" hash-object -w "$f"),$rel"
  done
  GIT_INDEX_FILE=$idx git -C "$1" write-tree
}

# --- cases --------------------------------------------------------------------

round_trip_tree_matches_pin() {
  new_root
  export_cmd "$S"
  [ -f "$S/js/ics/one.txt" ]
  # The corpus is not tracked, nor visible to plain git.
  assert_eq "" "$(git -C "$S" status --porcelain)" "corpus is invisible to git status"
  sed -i.bak 's/^line5$/line5 patched/' "$S/js/a.txt" && rm "$S/js/a.txt.bak"
  scratch_commit "patch a"
  echo c >"$S/other/c.txt"
  scratch_commit "add c"
  export_cmd --write "$S"
  assert_eq 2 "$(ls "$R"/patches/*.patch | wc -l | tr -d ' ')" "two patches"
  assert_eq "$(hand_tree "$S")" "$(pin_tree)" "UPSTREAM tree is HEAD plus corpus"
  assert_eq "$(pin_tree)" "$(fresh_apply_tree "$BASE/fresh")" "fresh pq_apply tree equals pin"
}

authors_and_subjects_survive() {
  new_root
  export_cmd "$S"
  echo x >"$S/other/x.txt"
  scratch_commit "Subject one" --author="Ann Author <ann@example.invalid>"
  echo y >"$S/other/y.txt"
  scratch_commit "Subject two: with colon" --author="Bob B <bob@example.invalid>"
  export_cmd --write "$S"
  grep -q '^From: Ann Author <ann@example.invalid>$' "$R"/patches/0001-*.patch
  grep -q '^Subject: \[PATCH\] Subject one$' "$R"/patches/0001-*.patch
  rm -rf "$S"
  export_cmd "$S"
  assert_eq "Bob B <bob@example.invalid>|Subject two: with colon
Ann Author <ann@example.invalid>|Subject one" \
    "$(git -C "$S" log --format='%an <%ae>|%s' V1..HEAD)"
}

refuses_commit_touching_ics() {
  local msg
  new_root
  export_cmd "$S"
  echo changed >"$S/js/ics/README"
  scratch_commit "touch corpus path"
  msg=$(export_cmd --write "$S" 2>&1) && return 1
  case $msg in *"js/ics"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  assert_eq 0 "$(ls "$R"/patches | wc -l | tr -d ' ')" "no patches written"
  grep -q '^tree=unset$' "$R/UPSTREAM"
}

am_tree_equals_apply_tree() {
  new_root
  export_cmd "$S"
  sed -i.bak 's/^line5$/line5 patched/' "$S/js/a.txt" && rm "$S/js/a.txt.bak"
  printf 'ws \n' >>"$S/js/a.txt"
  scratch_commit "edit a"
  echo c >"$S/other/c.txt"
  chmod +x "$S/other/c.txt"
  git -C "$S" rm -q other/b.txt
  scratch_commit "add c, drop b"
  export_cmd --write "$S"
  assert_eq "$(fresh_apply_tree "$BASE/viaapply")" "$(fresh_am_tree "$BASE/viaam")" "am tree equals apply tree"
  assert_eq "$(pin_tree)" "$(fresh_am_tree "$BASE/viaam2")" "pin equals am tree"
}

binary_hunk_survives() {
  new_root
  export_cmd "$S"
  printf '\000\001\002\377\376' >"$S/other/blob.bin"
  scratch_commit "add blob"
  printf '\000\377\000\001\002\003\004' >"$S/other/blob.bin"
  scratch_commit "change blob"
  export_cmd --write "$S"
  printf '\000\377\000\001\002\003\004' >"$BASE/blob.expected"
  fresh_apply_tree "$BASE/binapply" >/dev/null
  cmp "$BASE/blob.expected" "$BASE/binapply/other/blob.bin"
  assert_eq "$(pin_tree)" "$(fresh_am_tree "$BASE/binam")"
  cmp "$BASE/blob.expected" "$BASE/binam/other/blob.bin"
}

re_export_is_byte_identical() {
  new_root
  export_cmd "$S"
  echo x >"$S/other/x.txt"
  scratch_commit "add x"
  printf '\000\001' >"$S/other/blob.bin"
  scratch_commit "add blob"
  export_cmd --write "$S"
  cp -R "$R/patches" "$BASE/first"
  cp "$R/UPSTREAM" "$BASE/first.UPSTREAM"
  export_cmd --write "$S"
  diff -r "$BASE/first" "$R/patches"
  diff "$BASE/first.UPSTREAM" "$R/UPSTREAM"
  # Rebuilding the scratch checkout from the patches and exporting again too.
  rm -rf "$S"
  export_cmd "$S"
  export_cmd --write "$S"
  diff -r "$BASE/first" "$R/patches"
  diff "$BASE/first.UPSTREAM" "$R/UPSTREAM"
}

no_commits_clears_stale_patches() {
  new_root
  export_cmd "$S"
  echo x >"$S/other/x.txt"
  scratch_commit "add x"
  export_cmd --write "$S"
  git -C "$S" reset -q --hard V1
  export_cmd --write "$S"
  assert_eq 0 "$(ls "$R"/patches | wc -l | tr -d ' ')" "stale patch removed"
  assert_eq "$(hand_tree "$S")" "$(pin_tree)"
}

# User and system git config must not change the exported patch bytes.
patch_bytes_ignore_user_and_system_config() {
  new_root
  export_cmd "$S"
  sed -i.bak 's/^line5$/line5 patched/' "$S/js/a.txt" && rm "$S/js/a.txt.bak"
  scratch_commit "patch a"
  export_cmd --write "$S"
  cp -R "$R/patches" "$BASE/hermetic"
  printf '[format]\n\tsubjectPrefix = LEAK\n[diff]\n\tcontext = 1\n' >"$BASE/global.config"
  printf '[diff]\n\tcontext = 0\n\tsrcPrefix = s/\n' >"$BASE/system.config"
  (
    unset GIT_CONFIG_NOSYSTEM
    export GIT_CONFIG_GLOBAL="$BASE/global.config" GIT_CONFIG_SYSTEM="$BASE/system.config"
    export_cmd --write "$S"
  )
  diff -r "$BASE/hermetic" "$R/patches"
}

fixtures_run_the_export_suite() {
  grep -q 'test-export\.sh' "$ROOT/scripts/check-queue.sh"
}

run_test round_trip_tree_matches_pin round_trip_tree_matches_pin
run_test authors_and_subjects_survive authors_and_subjects_survive
run_test refuses_commit_touching_ics refuses_commit_touching_ics
run_test am_tree_equals_apply_tree am_tree_equals_apply_tree
run_test binary_hunk_survives binary_hunk_survives
run_test re_export_is_byte_identical re_export_is_byte_identical
run_test no_commits_clears_stale_patches no_commits_clears_stale_patches
run_test patch_bytes_ignore_user_and_system_config patch_bytes_ignore_user_and_system_config
run_test fixtures_run_the_export_suite fixtures_run_the_export_suite
finish
