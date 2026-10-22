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
  write_pin "$T/UPSTREAM.tmp" "$SHA" 0000000000000000000000000000000000000000
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

# scan_forbidden <root...>: print the non-comment lines under the roots that use
# a forbidden apply flag. Exit 0 if there is one, 1 if there is none, and 2 if a
# root cannot be scanned: a scan error is never "no match".
scan_forbidden() {
  local hits rc=0
  hits=$(grep -rnE -e '--(3way|reject|ignore-whitespace|ignore-space-change|unidiff-zero)' \
    -e '(^|[[:space:]])-3([[:space:]]|$)' -- "$@") || rc=$?
  case $rc in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  hits=$(printf '%s\n' "$hits" | grep -Ev '^[^:]*:[0-9]+:[[:space:]]*#') || return 1
  printf '%s\n' "$hits"
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

pin_is_validated() {
  local f=$BASE/pin sha=0123456789abcdef0123456789abcdef01234567 bad msg loc
  # CRLF line endings are tolerated.
  printf 'url=https://h.test/r\r\ntag=V1\r\ncommit=%s\r\ntree=%s\r\n' "$sha" "$sha" >"$f"
  pq_read_pin "$f"
  assert_eq "https://h.test/r|V1|$sha|$sha" "$PQ_URL|$PQ_TAG|$PQ_COMMIT|$PQ_TREE" "CRLF stripped"
  # commit and tree are 40 lowercase hex digits.
  for bad in unset "${sha%?}" "${sha}0" "$(printf '%s' "$sha" | tr a-f A-F)" "${sha%?}g"; do
    printf 'url=https://h.test/r\ntag=V1\ncommit=%s\ntree=%s\n' "$bad" "$sha" >"$f"
    msg=$(pq_read_pin "$f" 2>&1) && { echo "accepted commit=$bad"; return 1; }
    case $msg in *"commit"*) ;; *) echo "wrong reason (commit=$bad): $msg"; return 1 ;; esac
    printf 'url=https://h.test/r\ntag=V1\ncommit=%s\ntree=%s\n' "$sha" "$bad" >"$f"
    msg=$(pq_read_pin "$f" 2>&1) && { echo "accepted tree=$bad"; return 1; }
    case $msg in *"tree"*) ;; *) echo "wrong reason (tree=$bad): $msg"; return 1 ;; esac
  done
  # Upper case is rejected whatever the locale: in some locales a glob range
  # such as a-f collates A-E inside it.
  for loc in C en_US.UTF-8 C.UTF-8; do
    printf 'url=https://h.test/r\ntag=V1\ncommit=%s\ntree=%s\n' ABCDEABCDEABCDEABCDEABCDEABCDEABCDEABCDE "$sha" >"$f"
    msg=$(LC_ALL=$loc; pq_read_pin "$f" 2>&1) && { echo "accepted A-E commit under $loc"; return 1; }
    case $msg in *"commit"*) ;; *) echo "wrong reason ($loc): $msg"; return 1 ;; esac
  done
  # The example placeholder is read as it is; check-queue reports it.
  pq_read_pin "$ROOT/UPSTREAM.example"
  printf 'url=https://example.invalid/firefox.git\ntag=X\ncommit=TODO\ntree=TODO\n' >"$f"
  pq_read_pin "$f"
  assert_eq "TODO|TODO" "$PQ_COMMIT|$PQ_TREE" "placeholder read"
}

rejects_moved_tag() {
  local msg
  new_case
  write_pin "$T/UPSTREAM.tmp" "$SHA" 0000000000000000000000000000000000000000
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
  local roots=("$ROOT/scripts") d="$BASE/scan dir/scripts" rc flag
  # The scan must not be vacuous: the library has to exist and be scanned...
  [ -f "$ROOT/scripts/lib/patch-queue.sh" ]
  if [ -d "$ROOT/.github/workflows" ]; then roots+=("$ROOT/.github/workflows"); fi
  rc=0
  scan_forbidden "${roots[@]}" || rc=$?
  assert_eq 1 "$rc" "repository scan (0: forbidden flag found, 2: scan error)"
  # ...work under a path with spaces, tell a missing root from no match...
  mkdir -p "$d"
  cp -R "$ROOT/scripts/." "$d/"
  rc=0
  scan_forbidden "$d" || rc=$?
  assert_eq 1 "$rc" "copy under a path with spaces"
  rc=0
  scan_forbidden "$d" "$BASE/no such root" 2>/dev/null || rc=$?
  assert_eq 2 "$rc" "missing root"
  # ...and see a violation, but not a comment mentioning one.
  printf '# --3way is forbidden\n' >"$d/comment.sh"
  rc=0
  scan_forbidden "$d" || rc=$?
  assert_eq 1 "$rc" "comment only"
  for flag in --3way -3 --reject --ignore-whitespace --ignore-space-change --unidiff-zero; do
    printf 'git apply --index %s p\n' "$flag" >"$d/bad.sh"
    rc=0
    scan_forbidden "$d" >/dev/null || rc=$?
    assert_eq 0 "$rc" "planted $flag"
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

  # A status that cannot be read is not clean.
  pq_fetch "$T/corrupt"
  echo garbage >"$T/corrupt/.git/index"
  msg=$(pq_apply "$T/corrupt" "$T/patches" "$T/ics" 2>&1) && return 1
  case $msg in *"cannot read the status"*) ;; *) echo "wrong reason (status): $msg"; return 1 ;; esac

  # A clean pq_fetch clone is accepted and gets the queue.
  pq_fetch "$T/good"
  pq_apply "$T/good" "$T/patches" "$T/ics"
  assert_eq "$EXPECTED" "$(pq_tree "$T/good")"
}

# --- hostile environment and config -----------------------------------------

# Exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE must not redirect the library to
# the repository they name, and the clone must still get the queue.
ignores_repository_env() {
  local vars before n=0
  new_case
  basic_queue
  make_decoy "$T/decoy"
  before=$(repo_state "$T/decoy")
  for vars in "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE" GIT_INDEX_FILE; do
    n=$((n + 1))
    with_git_env "$T/decoy" "$vars" pq_fetch "$T/env$n"
    with_git_env "$T/decoy" "$vars" pq_apply "$T/env$n" "$T/patches" "$T/ics"
    assert_eq "$before" "$(repo_state "$T/decoy")" "decoy untouched ($vars)"
    assert_eq "$EXPECTED" "$(with_git_env "$T/decoy" "$vars" pq_tree "$T/env$n")" "queue applied ($vars)"
  done
}

# The caller's IFS (strict-mode $'\n\t', a comma, empty) does not defeat the
# environment guard: pq_fetch and pq_apply still ignore an exported GIT_DIR.
guard_holds_under_caller_ifs() {
  local ifs before n=0
  new_case
  basic_queue
  make_decoy "$T/decoy"
  before=$(repo_state "$T/decoy")
  for ifs in $'\n\t' , ''; do
    n=$((n + 1))
    with_git_env "$T/decoy" "GIT_DIR GIT_WORK_TREE" with_ifs "$ifs" pq_fetch "$T/ifs$n"
    with_git_env "$T/decoy" "GIT_DIR GIT_WORK_TREE" with_ifs "$ifs" pq_apply "$T/ifs$n" "$T/patches" "$T/ics"
    assert_eq "$before" "$(repo_state "$T/decoy")" "decoy untouched (IFS case $n)"
    assert_eq "$EXPECTED" "$(pq_tree "$T/ifs$n")" "queue applied (IFS case $n)"
  done
}

# A repository-selection variable that cannot be unset (readonly) makes loading
# the library fail, and pq_git refuse to run even if the caller ignores that.
refuses_readonly_repository_env() {
  local before out rc call lib=$ROOT/scripts/lib/patch-queue.sh
  new_case
  basic_queue
  pq_fetch "$T/clean"
  make_decoy "$T/decoy"
  before=$(repo_state "$T/decoy")
  rc=0
  out=$(with_readonly_git_env "$T/decoy" '. "$1"' "$lib" 2>&1) || rc=$?
  assert_eq 1 "$rc" "sourcing: $out"
  case $out in *"GIT_DIR"*) ;; *) echo "no reason given: $out"; return 1 ;; esac
  for call in 'pq_fetch "$3"' 'pq_apply "$4" "$5" "$6"'; do
    rc=0
    out=$(with_readonly_git_env "$T/decoy" '. "$1" 2>/dev/null; pq_read_pin "$2" && '"$call" \
      "$lib" "$T/UPSTREAM.tmp" "$T/ro" "$T/clean" "$T/patches" "$T/ics" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "$call ran: $out"; return 1; }
    case $out in *"GIT_DIR"*) ;; *) echo "$call: no reason given: $out"; return 1 ;; esac
    assert_eq "$before" "$(repo_state "$T/decoy")" "decoy untouched ($call)"
  done
  [ ! -e "$T/ro" ]
}

# A readonly GIT_CONFIG_GLOBAL naming the user's config cannot be pointed at
# /dev/null, so loading the library fails and pq_fetch refuses to run.
refuses_readonly_global_config() {
  local out rc script lib=$ROOT/scripts/lib/patch-queue.sh
  new_case
  printf '[core]\n\tautocrlf = input\n' >"$T/user.gitconfig"
  for script in '. "$1"' '. "$1" 2>/dev/null; pq_read_pin "$2" && pq_fetch "$3"'; do
    rc=0
    out=$(GIT_CONFIG_GLOBAL=$T/user.gitconfig bash -c "readonly GIT_CONFIG_GLOBAL; $script" _ \
      "$lib" "$T/UPSTREAM.tmp" "$T/ro" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "ran: $script: $out"; return 1; }
    case $out in *"GIT_CONFIG_GLOBAL"*) ;; *) echo "no reason given ($script): $out"; return 1 ;; esac
  done
  [ ! -e "$T/ro" ]
}

# git older than 2.32 ignores GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM, so the
# library refuses to load with it, and pq_fetch and pq_apply refuse to run.
refuses_old_git() {
  local out rc script lib=$ROOT/scripts/lib/patch-queue.sh
  new_case
  basic_queue
  pq_fetch "$T/clean"
  make_git_shim "$T/old" 2.31.9
  assert_eq "git version 2.31.9" "$(PATH="$T/old:$PATH" git --version)" "shim in effect"
  for script in '. "$1"' \
    '. "$1" 2>/dev/null; pq_read_pin "$2" && pq_fetch "$3"' \
    '. "$1" 2>/dev/null; pq_read_pin "$2" && pq_apply "$4" "$5" "$6"'; do
    rc=0
    out=$(PATH="$T/old:$PATH" bash -c "$script" _ "$lib" "$T/UPSTREAM.tmp" "$T/old-fetch" \
      "$T/clean" "$T/patches" "$T/ics" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "ran: $script: $out"; return 1; }
    case $out in *"2.31.9"*"2.32"*) ;; *) echo "no reason given ($script): $out"; return 1 ;; esac
  done
  [ ! -e "$T/old-fetch" ]
  assert_eq "" "$(git -C "$T/clean" status --porcelain)" "clean clone untouched"
  # 2.32 itself is accepted.
  make_git_shim "$T/new" 2.32.0
  PATH="$T/new:$PATH" bash -c '. "$1"' _ "$lib"
}

# User config that would change the applied tree must not: the result equals
# the clean-config run.
tree_ignores_user_config() {
  local how kv key value clean n=0
  new_case
  replace_line "$S/js/a.txt" line5 "line5 patched"
  printf 'ws \n' >>"$S/js/a.txt"
  step 0001-edit-a
  add_corpus
  printf 'crlf\r\n' >"$T/ics/crlf.txt"
  printf '*.txt\n' >"$T/ignore-txt"
  apply_queue
  clean=$(pq_tree "$W")
  for how in count home; do
    for kv in core.autocrlf=input apply.whitespace=fix "core.excludesFile=$T/ignore-txt"; do
      key=${kv%%=*} value=${kv#*=} n=$((n + 1))
      with_git_config "$how" "$key" "$value" pq_fetch "$T/cfg$n"
      with_git_config "$how" "$key" "$value" pq_apply "$T/cfg$n" "$T/patches" "$T/ics"
      assert_eq "$clean" "$(with_git_config "$how" "$key" "$value" pq_tree "$T/cfg$n")" "$how $kv"
    done
  done
}

# Exported variables that change how git reads attributes or creates repos do
# not change the applied tree.
tree_ignores_user_env() {
  local kv clean n=0
  new_case
  basic_queue
  printf 'crlf\r\n' >"$T/ics/crlf.txt"
  apply_queue
  clean=$(pq_tree "$W")
  for kv in GIT_ATTR_SOURCE=refs/heads/no-such-ref GIT_DEFAULT_HASH=sha256; do
    n=$((n + 1))
    with_env "$kv" pq_fetch "$T/env$n"
    with_env "$kv" pq_apply "$T/env$n" "$T/patches" "$T/ics"
    assert_eq "$clean" "$(with_env "$kv" pq_tree "$T/env$n")" "$kv"
  done
}

# apply.ignoreWhitespace must not let whitespace-drifted context apply, and
# status.showUntrackedFiles=no must not hide an untracked file from the guard.
strict_under_user_config() {
  local how msg
  new_case
  replace_line "$S/js/a.txt" line4 "line four"
  step 0001-word
  replace_line "$S/js/a.txt" line5 "line5 patched"
  step 0002-edit-a
  add_corpus
  # The drifted queue differs only in the amount of whitespace in a context line.
  mkdir "$T/drift"
  cp "$T/patches/0001-word.patch" "$T/drift/"
  sed 's/^ line four$/ line    four/' "$T/patches/0002-edit-a.patch" >"$T/drift/0002-edit-a.patch"
  if cmp -s "$T/patches/0002-edit-a.patch" "$T/drift/0002-edit-a.patch"; then echo "context not drifted"; return 1; fi
  for how in count home; do
    with_git_config "$how" apply.ignoreWhitespace change pq_fetch "$T/ws.$how"
    msg=$(with_git_config "$how" apply.ignoreWhitespace change pq_apply "$T/ws.$how" "$T/drift" "$T/ics" 2>&1) &&
      { echo "whitespace-drifted context applied ($how)"; return 1; }
    case $msg in *"failed to apply"*) ;; *) echo "wrong reason ($how): $msg"; return 1 ;; esac

    with_git_config "$how" status.showUntrackedFiles no pq_fetch "$T/dirty.$how"
    echo local >"$T/dirty.$how/untracked.txt"
    msg=$(with_git_config "$how" status.showUntrackedFiles no pq_apply "$T/dirty.$how" "$T/patches" "$T/ics" 2>&1) &&
      { echo "untracked file not seen ($how)"; return 1; }
    case $msg in *"not clean"*) ;; *) echo "wrong reason ($how): $msg"; return 1 ;; esac
  done
}

run_test applies_clean_queue_and_tree_matches_pin applies_clean_queue_and_tree_matches_pin
run_test pin_is_validated pin_is_validated
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
run_test ignores_repository_env ignores_repository_env
run_test guard_holds_under_caller_ifs guard_holds_under_caller_ifs
run_test refuses_readonly_repository_env refuses_readonly_repository_env
run_test refuses_readonly_global_config refuses_readonly_global_config
run_test refuses_old_git refuses_old_git
run_test tree_ignores_user_config tree_ignores_user_config
run_test strict_under_user_config strict_under_user_config
run_test tree_ignores_user_env tree_ignores_user_env
finish
