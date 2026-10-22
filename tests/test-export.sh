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
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=0000000000000000000000000000000000000000\n' "$URL" "$SHA" >"$R/UPSTREAM"
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
  grep -q '^tree=0000000000000000000000000000000000000000$' "$R/UPSTREAM"
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

# Patch bytes do not depend on the scratch commit ids, the git version or the
# repository size: zero commit in the From line, no signature, 12-digit ids.
patch_format_is_pinned() {
  local p
  new_root
  export_cmd "$S" >/dev/null
  echo x >"$S/other/x.txt"
  scratch_commit "add x"
  sed -i.bak 's/^line5$/line5 patched/' "$S/js/a.txt" && rm "$S/js/a.txt.bak"
  scratch_commit "patch a"
  export_cmd --write "$S" >/dev/null
  for p in "$R"/patches/*.patch; do
    assert_eq "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001" "$(head -n 1 "$p")" "$p"
    if grep -q '^-- $' "$p"; then echo "signature in $p"; return 1; fi
    grep -q '^index ' "$p"
    if grep '^index ' "$p" | grep -Ev '^index [0-9a-f]{12}\.\.[0-9a-f]{12}( [0-7]{6})?$'; then
      echo "index line without 12-digit ids in $p"
      return 1
    fi
  done
}

# Every git command the dev loop runs, logged by a PATH shim: am runs with
# --no-3way and nothing runs with a fuzzy apply flag.
dev_loop_git_flags() {
  local log=$BASE/git.log
  queued_root
  mkdir "$BASE/shim"
  printf '#!/bin/sh\nprintf "%%s\\n" " $* " >>"%s"\nexec "%s" "$@"\n' "$log" "$(command -v git)" >"$BASE/shim/git"
  chmod +x "$BASE/shim/git"
  rm -rf "$S"
  (
    PATH="$BASE/shim:$PATH"
    export_cmd "$S" >/dev/null
    echo y >"$S/other/y.txt"
    scratch_commit "add y"
    export_cmd --write "$S" >/dev/null
  )
  grep -q ' am ' "$log"
  if grep ' am ' "$log" | grep -v -- ' --no-3way '; then echo "am without --no-3way"; return 1; fi
  if grep -E -- ' (--3way|-3|--reject|--ignore-whitespace|--ignore-space-change|--unidiff-zero) ' "$log"; then
    echo "fuzzy apply flag"
    return 1
  fi
}

# --- refused exports write nothing -----------------------------------------

# queued_root: new_root with a one-patch queue exported from the scratch, and
# that queue saved in $R.saved.
queued_root() {
  new_root
  export_cmd "$S" >/dev/null
  echo x >"$S/other/x.txt"
  scratch_commit "add x"
  export_cmd --write "$S" >/dev/null
  mkdir "$R.saved"
  cp -R "$R/patches" "$R/UPSTREAM" "$R.saved/"
}

# queue_unchanged: patches/ and UPSTREAM are still the saved queue.
queue_unchanged() {
  diff -r "$R.saved/patches" "$R/patches" || { echo "patches/ changed"; return 1; }
  diff "$R.saved/UPSTREAM" "$R/UPSTREAM" || { echo "UPSTREAM changed"; return 1; }
}

refuses_merge_commit() {
  local msg
  queued_root
  git -C "$S" checkout -q -b side
  echo s >"$S/other/s.txt"
  scratch_commit side
  git -C "$S" checkout -q -
  echo m >"$S/other/m.txt"
  scratch_commit main
  git -C "$S" merge -q --no-ff --no-commit side
  # Content only the merge commit carries: format-patch would drop it.
  echo evil >"$S/other/evil.txt"
  scratch_commit merge
  msg=$(export_cmd --write "$S" 2>&1) && { echo "merge exported: $msg"; return 1; }
  case $msg in *"merge commit"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  queue_unchanged
}

refuses_empty_commit_clearly() {
  local msg
  queued_root
  git -C "$S" commit -q --allow-empty -m empty
  msg=$(export_cmd --write "$S" 2>&1) && { echo "empty commit exported: $msg"; return 1; }
  case $msg in *"empty commit"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  queue_unchanged
}

# A commit message that contains a diff is applied by `git apply` along with the
# commit's own diff, so the replayed queue is not the scratch HEAD.
refuses_replay_that_differs_from_head() {
  local msg
  queued_root
  echo y >"$S/other/y.txt"
  git -C "$S" add -A
  git -C "$S" commit -q -F - <<'EOF'
add y

diff --git a/other/fake.txt b/other/fake.txt
new file mode 100644
--- /dev/null
+++ b/other/fake.txt
@@ -0,0 +1 @@
+fake
EOF
  msg=$(export_cmd --write "$S" 2>&1) && { echo "lossy replay exported: $msg"; return 1; }
  case $msg in *"does not match"*) ;; *) echo "wrong reason: $msg"; return 1 ;; esac
  queue_unchanged
}

# --- hostile environment and config -----------------------------------------

# hostile_root: new_root with a CRLF corpus file and an exported queue of two
# commits (one with trailing whitespace and two files); keeps that clean export
# in $R.clean.
hostile_root() {
  new_root
  printf 'crlf\r\n' >"$R/data/ics/crlf.txt"
  printf 'other/*\n*\n' >"$R.order"
  printf '*.txt\n' >"$R.ignore"
  export_cmd "$S" >/dev/null
  sed -i.bak 's/^line5$/line5 patched /' "$S/js/a.txt" && rm "$S/js/a.txt.bak"
  echo c >"$S/other/c.txt"
  scratch_commit "two files, trailing whitespace"
  echo d >"$S/other/d.txt"
  scratch_commit "add d"
  git -C "$S" mv other/b.txt other/b-renamed.txt
  scratch_commit "rename b"
  export_cmd --write "$S" >/dev/null
  mkdir "$R.clean"
  cp -R "$R/patches" "$R/UPSTREAM" "$R.clean/"
}

# restore_clean: put the clean export back and drop the scratch checkout.
restore_clean() {
  rm -rf "$S" "$R/patches"
  cp -R "$R.clean/patches" "$R/patches"
  cp "$R.clean/UPSTREAM" "$R/UPSTREAM"
}

# same_as_clean <case>: patches/ and UPSTREAM equal the clean export.
same_as_clean() {
  diff -r "$R.clean/patches" "$R/patches" || { echo "patches differ: $1"; return 1; }
  diff "$R.clean/UPSTREAM" "$R/UPSTREAM" || { echo "UPSTREAM differs: $1"; return 1; }
}

# hostile_settings: key=value lines that change trees or patch bytes when git
# honours them. Needs hostile_root.
hostile_settings() {
  printf '%s\n' format.suffix=.txt apply.whitespace=fix format.thread=true \
    "diff.orderFile=$R.order" "format.headers=X-Hostile: 1" core.autocrlf=input \
    "core.excludesFile=$R.ignore" format.coverLetter=true format.signOff=true \
    diff.noprefix=true format.to=x@example.invalid
}

# Rebuilding the scratch and exporting under each user setting gives the clean
# export, byte for byte.
export_ignores_user_config() {
  local how kv failed=
  hostile_root
  for how in count home; do
    while IFS= read -r kv; do
      restore_clean
      {
        with_git_config "$how" "${kv%%=*}" "${kv#*=}" export_cmd "$S" >/dev/null </dev/null &&
          with_git_config "$how" "${kv%%=*}" "${kv#*=}" export_cmd --write "$S" >/dev/null </dev/null &&
          same_as_clean "$how $kv" >/dev/null
      } || failed="$failed [$how $kv]"
    done < <(hostile_settings)
  done
  assert_eq "" "$failed" "settings that changed the export"
}

# Exported variables that change diff output do not change the export.
export_ignores_user_env() {
  local kv failed=
  hostile_root
  for kv in GIT_DIFF_OPTS=-u5; do
    restore_clean
    {
      with_env "$kv" export_cmd "$S" >/dev/null </dev/null &&
        with_env "$kv" export_cmd --write "$S" >/dev/null </dev/null &&
        same_as_clean "$kv" >/dev/null
    } || failed="$failed [$kv]"
  done
  assert_eq "" "$failed" "variables that changed the export"
}

# scratch_settings: hostile_settings plus keys that change patch bytes only when
# set in the scratch checkout's own config (the user-config cases cannot reach
# them). Needs hostile_root.
scratch_settings() {
  hostile_settings
  printf '%s\n' diff.context=5 diff.renames=false \
    format.attach=true format.subjectPrefix=HOSTILE diff.srcPrefix=x/ diff.dstPrefix=y/ \
    i18n.logOutputEncoding=UTF-16
}

# The scratch_settings keys, set in the scratch checkout's own config, do not
# change the export. Keys not listed there are not covered.
export_ignores_scratch_config() {
  local kv failed=
  hostile_root
  restore_clean
  export_cmd "$S" >/dev/null
  while IFS= read -r kv; do
    git -C "$S" config "${kv%%=*}" "${kv#*=}"
    { export_cmd --write "$S" >/dev/null </dev/null && same_as_clean "scratch $kv" >/dev/null; } ||
      failed="$failed [$kv]"
    git -C "$S" config --unset "${kv%%=*}"
  done < <(scratch_settings)
  assert_eq "" "$failed" "scratch settings that changed the export"
}

# Exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE do not redirect the dev loop.
export_ignores_repository_env() {
  local before
  hostile_root
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  restore_clean
  with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE" export_cmd "$S" >/dev/null
  with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE" export_cmd --write "$S" >/dev/null
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
  same_as_clean env
}

# With a readonly GIT_DIR/GIT_WORK_TREE in the calling shell, export-patches
# stops before running git, so the repository they name is not touched.
export_refuses_readonly_repository_env() {
  local before out rc=0
  new_root
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  out=$(with_readonly_git_env "$R.decoy" 'PQ_ROOT=$1; s=$2; export PQ_ROOT; set -- "$3"; . "$s"' "$R" "$EXPORT" "$S" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "export-patches ran: $out"; return 1; }
  case $out in *"GIT_DIR"*) ;; *) echo "no reason given: $out"; return 1 ;; esac
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
  [ ! -e "$S" ]
}

# The scratch builds when the committer identity is only in the user's config.
scratch_builds_without_committer_env() {
  hostile_root
  restore_clean
  (
    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL XDG_CONFIG_HOME EMAIL
    HOME=$(mktemp -d "$BASE/home.XXXXXX")
    export HOME
    git config --global user.name Dev
    git config --global user.email dev@example.invalid
    export_cmd "$S" >/dev/null
  )
  assert_eq 3 "$(git -C "$S" rev-list --count V1..HEAD)" "queue applied"
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
run_test patch_format_is_pinned patch_format_is_pinned
run_test dev_loop_git_flags dev_loop_git_flags
run_test refuses_merge_commit refuses_merge_commit
run_test refuses_empty_commit_clearly refuses_empty_commit_clearly
run_test refuses_replay_that_differs_from_head refuses_replay_that_differs_from_head
run_test export_ignores_user_config export_ignores_user_config
run_test export_ignores_scratch_config export_ignores_scratch_config
run_test export_ignores_user_env export_ignores_user_env
run_test export_ignores_repository_env export_ignores_repository_env
run_test export_refuses_readonly_repository_env export_refuses_readonly_repository_env
run_test scratch_builds_without_committer_env scratch_builds_without_committer_env
run_test fixtures_run_the_export_suite fixtures_run_the_export_suite
finish
