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

# An example.invalid url marks the placeholder even when its commit and tree
# would verify.
refuses_example_url() {
  new_root
  URL="$R/example.invalid/up"
  SHA=$(make_fixture_upstream "$URL")
  write_upstream "$(queue_tree)"
  run_check
  assert_eq 2 "$RC" "$OUT"
  case $OUT in *"UPSTREAM not initialised"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
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
  assert_eq 1 "$RC" "$OUT"
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
  assert_eq 1 "$RC" "$OUT"
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
  assert_eq 1 "$RC" "$OUT"
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

# The census needs an explicit yurt ref; a default branch name can be stale.
census_requires_yurt_ref() {
  new_root
  write_upstream "$(queue_tree)"
  export PQ_YURT_REPO=$URL PQ_DOM_COUNT=0
  run_check
  assert_eq 2 "$RC" "$OUT"
  case $OUT in *"PQ_YURT_REF is required"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
}

# The verdict does not depend on the caller's git config or exported
# repository-selection variables, and the repository they name is not touched.
passes_under_hostile_git() {
  local how kv before
  new_root
  printf 'crlf\r\n' >"$R/data/ics/crlf.txt"
  printf '*.txt\n' >"$R.ignore"
  write_upstream "$(queue_tree)"
  for how in count home; do
    for kv in core.autocrlf=input "core.excludesFile=$R.ignore"; do
      RC=0
      OUT=$(with_git_config "$how" "${kv%%=*}" "${kv#*=}" env PQ_ROOT="$R" "$CHECK" 2>&1) || RC=$?
      assert_eq 0 "$RC" "$how $kv: $OUT"
    done
  done
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  RC=0
  OUT=$(with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE" env PQ_ROOT="$R" "$CHECK" 2>&1) || RC=$?
  assert_eq 0 "$RC" "env: $OUT"
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
}

# With a readonly GIT_DIR/GIT_WORK_TREE in the calling shell, check-queue stops
# before running git, so the repository they name is not touched.
refuses_readonly_repository_env() {
  local before rc=0
  new_root
  write_upstream "$(queue_tree)"
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  OUT=$(with_readonly_git_env "$R.decoy" 'PQ_ROOT=$1; s=$2; export PQ_ROOT; set --; . "$s"' "$R" "$CHECK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "check-queue ran: $OUT"; return 1; }
  case $OUT in *"GIT_DIR"*) ;; *) echo "no reason given: $OUT"; return 1 ;; esac
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
}

# With git older than 2.32 on PATH, check-queue (both modes) and export-patches
# stop with a clear message.
scripts_refuse_old_git() {
  local n
  new_root
  write_upstream "$(queue_tree)"
  make_git_shim "$R.old" 2.31.9
  for n in 1 2 3; do
    RC=0
    case $n in
      1) OUT=$(PATH="$R.old:$PATH" PQ_ROOT=$R bash "$CHECK" 2>&1) || RC=$? ;;
      2) OUT=$(PATH="$R.old:$PATH" PQ_ROOT=$R bash "$CHECK" --fixtures 2>&1) || RC=$? ;;
      3) OUT=$(PATH="$R.old:$PATH" PQ_ROOT=$R bash "$ROOT/scripts/export-patches.sh" "$R/scratch" 2>&1) || RC=$? ;;
    esac
    [ "$RC" -ne 0 ] || { echo "case $n ran: $OUT"; return 1; }
    case $OUT in *"2.31.9"*"2.32"*) ;; *) echo "case $n: no reason given: $OUT"; return 1 ;; esac
  done
  [ ! -e "$R/scratch" ]
}

# Sourced into a shell with a strict-mode IFS, a comma or an empty IFS,
# check-queue still ignores an exported GIT_DIR and passes.
sourced_under_caller_ifs() {
  local ifs before n=0
  new_root
  write_upstream "$(queue_tree)"
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  for ifs in $'\n\t' ',' ''; do
    n=$((n + 1))
    RC=0
    OUT=$(with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE" \
      bash -c 'IFS=$1; PQ_ROOT=$2; export PQ_ROOT; s=$3; set --; . "$s"' _ "$ifs" "$R" "$CHECK" 2>&1) || RC=$?
    assert_eq 0 "$RC" "IFS case $n: $OUT"
    assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched (IFS case $n)"
  done
}

run_test refuses_without_upstream refuses_without_upstream
run_test refuses_placeholder_upstream refuses_placeholder_upstream
run_test refuses_example_url refuses_example_url
run_test passes_when_tree_matches passes_when_tree_matches
run_test fails_on_tree_mismatch fails_on_tree_mismatch
run_test fails_on_moved_tag fails_on_moved_tag
run_test runs_census_when_configured runs_census_when_configured
run_test census_skipped_is_announced census_skipped_is_announced
run_test passes_census_when_clean passes_census_when_clean
run_test census_requires_yurt_ref census_requires_yurt_ref
run_test passes_under_hostile_git passes_under_hostile_git
run_test refuses_readonly_repository_env refuses_readonly_repository_env
run_test scripts_refuse_old_git scripts_refuse_old_git
run_test sourced_under_caller_ifs sourced_under_caller_ifs
finish
