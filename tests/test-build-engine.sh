#!/usr/bin/env bash
# Tests for scripts/build-engine.sh (--dry-run only; a real build runs on EC2/CI)
# and scripts/check-mozconfig-drift.sh. JSON validity is checked with python3.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"

BUILD="$ROOT/scripts/build-engine.sh"
DRIFT="$ROOT/scripts/check-mozconfig-drift.sh"
export PQ_ICS_PATH=js/ics

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# new_root: a fake repo root R (UPSTREAM, patches/, data/ics, mozconfig, pin),
# its UPSTREAM pinning the applied tree.
new_root() {
  R=$(mktemp -d "$BASE/root.XXXXXX")
  URL="$R/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$R/patches" "$R/data/ics"
  echo one >"$R/data/ics/one.txt"
  cp "$ROOT/mozconfig" "$R/mozconfig"
  repin
}

# write_upstream <tree>: pin tag V1 of the fixture with the given tree.
write_upstream() {
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=%s\n' "$URL" "$SHA" "$1" >"$R/UPSTREAM"
}

# applied_tree: the tree of V1 with R's patches and data/ics laid over
# $PQ_ICS_PATH, computed with plain git (not the library under test).
applied_tree() {
  local t p
  t=$(mktemp -d "$BASE/pin.XXXXXX")
  git clone -q "$URL" "$t/w" 2>/dev/null || return 1
  git -C "$t/w" checkout -q V1 2>/dev/null || return 1
  for p in "$R"/patches/*.patch; do
    [ ! -e "$p" ] || git -C "$t/w" apply --index "$p" || return 1
  done
  mkdir -p "$t/w/$PQ_ICS_PATH" || return 1
  cp -R "$R/data/ics/." "$t/w/$PQ_ICS_PATH/" || return 1
  git -C "$t/w" add -- "$PQ_ICS_PATH" || return 1
  git -C "$t/w" write-tree
}

# repin: pin UPSTREAM to the current applied tree (after changing R's inputs).
repin() {
  TREE=$(applied_tree) || return 1
  write_upstream "$TREE"
}

# run_build <args...>: sets OUT and RC.
run_build() {
  RC=0
  OUT=$(PQ_ROOT=$R "$BUILD" "$@" 2>&1) || RC=$?
}

dry_run_creates_tree_and_manifest() {
  new_root
  run_build --dry-run --workdir "$BASE/wd1/firefox"
  assert_eq 0 "$RC" "$OUT"
  [ -f "$BASE/wd1/firefox/js/ics/one.txt" ]
  [ -f "$BASE/wd1/firefox/js/a.txt" ]
  python3 - "$BASE/wd1/build-manifest.json" "$SHA" "$(shasum -a 256 "$R/mozconfig" | cut -d' ' -f1)" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k in ("tag", "commit", "queue_sha256", "data_ics_sha256", "mozconfig_sha256",
          "toolchain_artifacts", "rust_version"):
    assert k in m, k
assert m["tag"] == "V1"
assert m["commit"] == sys.argv[2]
assert m["mozconfig_sha256"] == sys.argv[3]
assert m["toolchain_artifacts"] == []
assert m["rust_version"] == ""
for k in ("queue_sha256", "data_ics_sha256"):
    assert len(m[k]) == 64, k
PY
}

dry_run_does_not_bootstrap() {
  new_root
  run_build --dry-run --workdir "$BASE/wd2/firefox"
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *"toolchain"*"skipped"*) ;; *) echo "no skip notice: $OUT"; return 1 ;; esac
  [ ! -e "$BASE/wd2/firefox/obj-nightmonkey-sm" ]
}

hashes_track_inputs() {
  new_root
  run_build --dry-run --workdir "$BASE/wd3/firefox"
  a=$(grep data_ics_sha256 "$BASE/wd3/build-manifest.json")
  rm -rf "$BASE/wd3"
  echo two >"$R/data/ics/two.txt"
  repin
  run_build --dry-run --workdir "$BASE/wd3/firefox"
  assert_eq 0 "$RC" "$OUT"
  b=$(grep data_ics_sha256 "$BASE/wd3/build-manifest.json")
  [ "$a" != "$b" ]
}

queue_hash_tracks_patch_set() {
  new_root
  run_build --dry-run --workdir "$BASE/wd6/firefox"
  a=$(grep queue_sha256 "$BASE/wd6/build-manifest.json")
  rm -rf "$BASE/wd6"
  # A new patch changes the hash.
  printf 'diff --git a/other/b.txt b/other/b.txt\n--- a/other/b.txt\n+++ b/other/b.txt\n@@ -1 +1 @@\n-b\n+c\n' >"$R/patches/0001-x.patch"
  repin
  run_build --dry-run --workdir "$BASE/wd6/firefox"
  assert_eq 0 "$RC" "$OUT"
  b=$(grep queue_sha256 "$BASE/wd6/build-manifest.json")
  [ "$a" != "$b" ]
}

drift_rejects_short_or_malformed_pin() {
  new_nm
  printf 'abc123\n' >"$R/NIGHTMONKEY_PIN"
  run_drift
  [ "$RC" -ne 0 ]
  printf '%sZ\n' "$(git -C "$NM" rev-parse HEAD | cut -c1-39)" >"$R/NIGHTMONKEY_PIN"
  run_drift
  [ "$RC" -ne 0 ]
}

refuses_non_empty_workdir() {
  new_root
  mkdir -p "$BASE/wd4/firefox"
  echo x >"$BASE/wd4/firefox/file"
  run_build --dry-run --workdir "$BASE/wd4/firefox"
  [ "$RC" -ne 0 ]
  case $OUT in *"not empty"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  assert_eq x "$(cat "$BASE/wd4/firefox/file")"
}

defaults_workdir_to_workspace() {
  new_root
  mkdir -p "$BASE/ws"
  RC=0
  OUT=$(PQ_ROOT=$R GITHUB_WORKSPACE=$BASE/ws "$BUILD" --dry-run 2>&1) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  [ -f "$BASE/ws/firefox/js/a.txt" ]
  [ -f "$BASE/ws/build-manifest.json" ]
}

mozconfig_matches_pin_in_repo() {
  [ -f "$ROOT/mozconfig" ]
  [ "$(wc -l <"$ROOT/NIGHTMONKEY_PIN" | tr -d ' ')" = 1 ]
  grep -Eq '^[0-9a-f]{40}$' "$ROOT/NIGHTMONKEY_PIN"
}

# new_nm: a fake NightMonkey checkout NM at a pinned SHA holding spidermonkey/mozconfig.
new_nm() {
  new_root
  NM=$BASE/nm.$$.$RANDOM
  mkdir -p "$NM/spidermonkey"
  git -C "$NM" init -q .
  cp "$R/mozconfig" "$NM/spidermonkey/mozconfig"
  git -C "$NM" add -A
  git -C "$NM" commit -q -m nm
  git -C "$NM" rev-parse HEAD >"$R/NIGHTMONKEY_PIN"
}

run_drift() {
  RC=0
  OUT=$(PQ_ROOT=$R NM_REPO=$NM "$DRIFT" 2>&1) || RC=$?
}

drift_passes_when_equal() {
  new_nm
  run_drift
  assert_eq 0 "$RC" "$OUT"
}

drift_fails_when_different() {
  new_nm
  echo '# local edit' >>"$R/mozconfig"
  run_drift
  [ "$RC" -ne 0 ]
  case $OUT in *"mozconfig drift"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
}

drift_reads_the_pinned_sha_not_head() {
  new_nm
  echo '# later nm edit' >>"$NM/spidermonkey/mozconfig"
  git -C "$NM" commit -q -am later
  run_drift
  assert_eq 0 "$RC" "$OUT"
}

# Exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE (hooks and dotfile setups export
# them) neither change the verdict nor touch the repository they name: the pinned
# mozconfig is read from NM_REPO.
drift_ignores_repository_env() {
  local before
  new_nm
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  RC=0
  OUT=$(with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE" env PQ_ROOT="$R" NM_REPO="$NM" "$DRIFT" 2>&1) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
}

# The applied tree must be the one UPSTREAM pins; the run fails before writing
# a manifest otherwise.
refuses_tree_mismatch() {
  new_root
  write_upstream "$(git -C "$URL" rev-parse 'V1^{tree}')"
  run_build --dry-run --workdir "$BASE/wd7/firefox"
  [ "$RC" -ne 0 ] || { echo "accepted a wrong tree: $OUT"; return 1; }
  case $OUT in *"tree"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  [ ! -e "$BASE/wd7/build-manifest.json" ]
}

# Placeholder pins are refused with exit 2 before fetching, as check-queue does.
refuses_placeholder_upstream() {
  local zero=0000000000000000000000000000000000000000
  new_root
  write_upstream "$zero"
  run_build --dry-run --workdir "$BASE/wd8"
  assert_eq 2 "$RC" "$OUT"
  case $OUT in *"not initialised"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  [ ! -e "$BASE/wd8" ]
  printf 'url=https://example.invalid/firefox.git\ntag=X\ncommit=TODO\ntree=TODO\n' >"$R/UPSTREAM"
  run_build --dry-run --workdir "$BASE/wd8"
  assert_eq 2 "$RC" "$OUT"
  [ ! -e "$BASE/wd8" ]
}

# The manifest records the applied tree and where the corpus was laid, so builds
# of different trees never share a manifest.
manifest_records_tree_and_ics_path() {
  local a
  new_root
  run_build --dry-run --workdir "$BASE/wd9/firefox"
  assert_eq 0 "$RC" "$OUT"
  python3 - "$BASE/wd9/build-manifest.json" "$TREE" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["tree"] == sys.argv[2], m
assert m["ics_path"] == "js/ics", m
PY2
  a=$(cat "$BASE/wd9/build-manifest.json")
  PQ_ICS_PATH=somewhere/else
  repin
  run_build --dry-run --workdir "$BASE/wd10/firefox"
  assert_eq 0 "$RC" "$OUT"
  [ "$a" != "$(cat "$BASE/wd10/build-manifest.json")" ]
}

# Values are JSON-escaped: a quote or a backslash cannot break the manifest.
manifest_is_valid_json() {
  new_root
  PQ_ICS_PATH='js/q"b\\s'
  repin
  run_build --dry-run --workdir "$BASE/wd11/firefox"
  assert_eq 0 "$RC" "$OUT"
  python3 - "$BASE/wd11/build-manifest.json" "$PQ_ICS_PATH" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["ics_path"] == sys.argv[2], m
PY2
}

# An existing build-manifest.json next to the workdir is refused, not
# overwritten, before anything is fetched.
refuses_existing_manifest() {
  new_root
  mkdir -p "$BASE/wd12"
  echo keep >"$BASE/wd12/build-manifest.json"
  run_build --dry-run --workdir "$BASE/wd12/firefox"
  [ "$RC" -ne 0 ] || { echo "overwrote the manifest: $OUT"; return 1; }
  case $OUT in *"build-manifest.json"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  assert_eq keep "$(cat "$BASE/wd12/build-manifest.json")"
  [ ! -e "$BASE/wd12/firefox" ]
}

run_test dry_run_creates_tree_and_manifest dry_run_creates_tree_and_manifest
run_test dry_run_does_not_bootstrap dry_run_does_not_bootstrap
run_test hashes_track_inputs hashes_track_inputs
run_test queue_hash_tracks_patch_set queue_hash_tracks_patch_set
run_test refuses_non_empty_workdir refuses_non_empty_workdir
run_test defaults_workdir_to_workspace defaults_workdir_to_workspace
run_test mozconfig_matches_pin_in_repo mozconfig_matches_pin_in_repo
run_test drift_passes_when_equal drift_passes_when_equal
run_test drift_fails_when_different drift_fails_when_different
run_test drift_reads_the_pinned_sha_not_head drift_reads_the_pinned_sha_not_head
run_test drift_rejects_short_or_malformed_pin drift_rejects_short_or_malformed_pin
run_test drift_ignores_repository_env drift_ignores_repository_env
run_test refuses_tree_mismatch refuses_tree_mismatch
run_test refuses_placeholder_upstream refuses_placeholder_upstream
run_test manifest_records_tree_and_ics_path manifest_records_tree_and_ics_path
run_test manifest_is_valid_json manifest_is_valid_json
run_test refuses_existing_manifest refuses_existing_manifest
finish
