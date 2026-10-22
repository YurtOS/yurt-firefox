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

# new_root: a fake repo root R (UPSTREAM, patches/, data/ics, mozconfig, pin).
new_root() {
  R=$(mktemp -d "$BASE/root.XXXXXX")
  URL="$R/up"
  SHA=$(make_fixture_upstream "$URL")
  mkdir -p "$R/patches" "$R/data/ics"
  echo one >"$R/data/ics/one.txt"
  printf 'url=%s\ntag=V1\ncommit=%s\ntree=%s\n' "$URL" "$SHA" "$(git -C "$URL" rev-parse 'V1^{tree}')" >"$R/UPSTREAM"
  cp "$ROOT/mozconfig" "$R/mozconfig"
}

# run_build <args...>: sets OUT and RC.
run_build() {
  RC=0
  OUT=$(PQ_ROOT=$R "$BUILD" "$@" 2>&1) || RC=$?
}

dry_run_creates_tree_and_manifest() {
  new_root
  run_build --dry-run --workdir "$BASE/wd1"
  assert_eq 0 "$RC" "$OUT"
  [ -f "$BASE/wd1/js/ics/one.txt" ]
  [ -f "$BASE/wd1/js/a.txt" ]
  python3 - "$BASE/build-manifest.json" "$SHA" "$(shasum -a 256 "$R/mozconfig" | cut -d' ' -f1)" <<'PY'
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
  run_build --dry-run --workdir "$BASE/wd2"
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *"toolchain"*"skipped"*) ;; *) echo "no skip notice: $OUT"; return 1 ;; esac
  [ ! -e "$BASE/wd2/obj-nightmonkey-sm" ]
}

hashes_track_inputs() {
  new_root
  run_build --dry-run --workdir "$BASE/wd3"
  a=$(grep data_ics_sha256 "$BASE/build-manifest.json")
  rm -rf "$BASE/wd3"
  echo two >"$R/data/ics/two.txt"
  run_build --dry-run --workdir "$BASE/wd3"
  assert_eq 0 "$RC" "$OUT"
  b=$(grep data_ics_sha256 "$BASE/build-manifest.json")
  [ "$a" != "$b" ]
}

queue_hash_tracks_patch_set() {
  new_root
  run_build --dry-run --workdir "$BASE/wd6"
  a=$(grep queue_sha256 "$BASE/build-manifest.json")
  rm -rf "$BASE/wd6"
  # A new patch changes the hash.
  printf 'diff --git a/other/b.txt b/other/b.txt\n--- a/other/b.txt\n+++ b/other/b.txt\n@@ -1 +1 @@\n-b\n+c\n' >"$R/patches/0001-x.patch"
  run_build --dry-run --workdir "$BASE/wd6"
  assert_eq 0 "$RC" "$OUT"
  b=$(grep queue_sha256 "$BASE/build-manifest.json")
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
  mkdir -p "$BASE/wd4"
  echo x >"$BASE/wd4/file"
  run_build --dry-run --workdir "$BASE/wd4"
  [ "$RC" -ne 0 ]
  case $OUT in *"not empty"*) ;; *) echo "wrong message: $OUT"; return 1 ;; esac
  assert_eq x "$(cat "$BASE/wd4/file")"
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
finish
