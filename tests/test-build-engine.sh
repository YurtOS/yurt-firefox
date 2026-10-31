#!/usr/bin/env bash
# Tests for scripts/build-engine.sh (--dry-run only; a real build runs on EC2/CI)
# JSON validity is checked with python3.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"

BUILD="$ROOT/scripts/build-engine.sh"
export PQ_ICS_PATH=js/ics

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

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
  python3 - "$BASE/wd1/build-manifest.json" "$SHA" "$(sha256 <"$R/mozconfig" | cut -d' ' -f1)" <<'PY'
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

# hash_of <manifest> <key>: one value from a manifest.
hash_of() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# Changing the content of an existing patch or corpus file, not only adding a
# file, changes the queue or corpus hash.
hashes_track_content_edits() {
  local q1 i1
  new_root
  printf 'diff --git a/other/b.txt b/other/b.txt\n--- a/other/b.txt\n+++ b/other/b.txt\n@@ -1 +1 @@\n-b\n+c\n' >"$R/patches/0001-x.patch"
  repin
  run_build --dry-run --workdir "$BASE/wd13/firefox"
  assert_eq 0 "$RC" "$OUT"
  q1=$(hash_of "$BASE/wd13/build-manifest.json" queue_sha256)
  i1=$(hash_of "$BASE/wd13/build-manifest.json" data_ics_sha256)
  printf 'diff --git a/other/b.txt b/other/b.txt\n--- a/other/b.txt\n+++ b/other/b.txt\n@@ -1 +1 @@\n-b\n+d\n' >"$R/patches/0001-x.patch"
  repin
  run_build --dry-run --workdir "$BASE/wd14/firefox"
  assert_eq 0 "$RC" "$OUT"
  [ "$q1" != "$(hash_of "$BASE/wd14/build-manifest.json" queue_sha256)" ] || { echo "queue hash ignores patch bytes"; return 1; }
  assert_eq "$i1" "$(hash_of "$BASE/wd14/build-manifest.json" data_ics_sha256)" "corpus hash unchanged"
  echo uno >"$R/data/ics/one.txt"
  repin
  run_build --dry-run --workdir "$BASE/wd15/firefox"
  assert_eq 0 "$RC" "$OUT"
  [ "$i1" != "$(hash_of "$BASE/wd15/build-manifest.json" data_ics_sha256)" ] || { echo "corpus hash ignores file bytes"; return 1; }
}

# A file whose digest cannot be computed fails the run; it never contributes an
# empty digest. The sha256sum shim fails on input containing FAILME.
hash_read_error_fails() {
  local real
  new_root
  echo FAILME >"$R/data/ics/bad.txt"
  repin
  if real=$(command -v sha256sum); then :; else real="$(command -v shasum) -a 256"; fi
  mkdir -p "$R.shim"
  # shellcheck disable=SC2016 # expanded by the shim, not here
  printf '#!/bin/sh\nt=$(mktemp) || exit 1\ncat >"$t"\nif grep -q FAILME "$t"; then rm -f "$t"; echo "shim: sha256sum fails" >&2; exit 1; fi\n%s <"$t"; rc=$?; rm -f "$t"; exit $rc\n' \
    "$real" >"$R.shim/sha256sum"
  chmod +x "$R.shim/sha256sum"
  RC=0
  OUT=$(PATH="$R.shim:$PATH" PQ_ROOT=$R "$BUILD" --dry-run --workdir "$BASE/wd16/firefox" 2>&1) || RC=$?
  [ "$RC" -ne 0 ] || { echo "hashed past a read error: $OUT"; return 1; }
  [ ! -e "$BASE/wd16/build-manifest.json" ]
}

# A missing mozconfig fails a dry run before any manifest is written; its hash is
# never recorded as "".
missing_mozconfig_fails() {
  new_root
  rm "$R/mozconfig"
  run_build --dry-run --workdir "$BASE/wd17/firefox"
  [ "$RC" -ne 0 ] || { echo "built without a mozconfig: $OUT"; return 1; }
  [ ! -e "$BASE/wd17/build-manifest.json" ]
}

# real_root: new_root whose queue adds an executable `mach` that records its
# calls, fails if any repository-selection variable reaches it, and writes an
# artifact manifest for `artifact toolchain`; plus shims for uname (Linux),
# rustup and rustc (the pinned version), so the non-dry path runs offline.
real_root() {
  local t want
  new_root
  t=$(mktemp -d "$BASE/mach.XXXXXX")
  git clone -q "$URL" "$t/w" 2>/dev/null
  git -C "$t/w" checkout -q V1 2>/dev/null
  cat >"$t/w/mach" <<'MACH'
#!/bin/sh
echo "mach $*" >>"$MACH_LOG"
for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR; do
  if eval "[ -n \"\${$v+set}\" ]"; then echo "mach: $v is set" >&2; exit 1; fi
done
case " $* " in *" artifact "*)
  while [ $# -gt 0 ]; do
    case $1 in --from-build) n=$2 ;; --artifact-manifest) m=$2 ;; esac
    shift
  done
  printf '{"https://h.test/%s.tar.zst": {"sha256": "%s"}}\n' "$n" \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef >"$m" ;;
esac
MACH
  chmod +x "$t/w/mach"
  git -C "$t/w" add mach
  git -C "$t/w" diff --cached >"$R/patches/0001-mach.patch"
  repin
  want=$(sed -n 's/^RUST_VERSION=//p' "$BUILD")
  mkdir -p "$R.bin" "$R.state"
  printf '#!/bin/sh\necho Linux\n' >"$R.bin/uname"
  printf '#!/bin/sh\nexit 0\n' >"$R.bin/rustup"
  printf '#!/bin/sh\necho "rustc %s (0000000 2026-01-01)"\n' "$want" >"$R.bin/rustc"
  chmod +x "$R.bin/uname" "$R.bin/rustup" "$R.bin/rustc"
}

# run_real <workdir> [command prefix...]: the non-dry path with the shims.
run_real() {
  local wd=$1
  shift
  RC=0
  OUT=$("$@" env PATH="$R.bin:$PATH" MACH_LOG="$R.log" MOZBUILD_STATE_PATH="$R.state" \
    PQ_ROOT="$R" "$BUILD" --workdir "$wd" 2>&1) || RC=$?
}

# The non-dry path runs bootstrap, both toolchain fetches and the build, and
# records the toolchain digests.
real_path_runs_mach() {
  real_root
  run_real "$BASE/wd18/firefox"
  assert_eq 0 "$RC" "$OUT"
  assert_eq 4 "$(wc -l <"$R.log" | tr -d ' ')" "mach calls: $(cat "$R.log")"
  python3 - "$BASE/wd18/build-manifest.json" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1]))
assert [a["name"] for a in m["toolchain_artifacts"]] == ["linux64-clang.tar.zst", "sysroot-wasm32-wasi.tar.zst"], m
assert m["rust_version"].startswith("rustc "), m
PY2
}

# A caller's exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE never reach mach:
# neither pointing at a decoy repository nor at a directory that does not exist.
real_path_cleans_git_env_for_mach() {
  local before
  real_root
  make_decoy "$R.decoy"
  before=$(repo_state "$R.decoy")
  run_real "$BASE/wd19/firefox" with_git_env "$R.decoy" "GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE"
  assert_eq 0 "$RC" "decoy env: $OUT"
  assert_eq "$before" "$(repo_state "$R.decoy")" "decoy untouched"
  run_real "$BASE/wd20/firefox" env GIT_DIR="$R.missing/.git"
  assert_eq 0 "$RC" "missing GIT_DIR: $OUT"
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

mozconfig_and_pin_in_repo() {
  [ -f "$ROOT/mozconfig" ]
  [ "$(wc -l <"$ROOT/NIGHTMONKEY_PIN" | tr -d ' ')" = 1 ]
  grep -Eq '^[0-9a-f]{40}$' "$ROOT/NIGHTMONKEY_PIN"
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
run_test hashes_track_content_edits hashes_track_content_edits
run_test hash_read_error_fails hash_read_error_fails
run_test missing_mozconfig_fails missing_mozconfig_fails
run_test real_path_runs_mach real_path_runs_mach
run_test real_path_cleans_git_env_for_mach real_path_cleans_git_env_for_mach
run_test refuses_non_empty_workdir refuses_non_empty_workdir
run_test defaults_workdir_to_workspace defaults_workdir_to_workspace
run_test mozconfig_and_pin_in_repo mozconfig_and_pin_in_repo
run_test refuses_tree_mismatch refuses_tree_mismatch
run_test refuses_placeholder_upstream refuses_placeholder_upstream
run_test manifest_records_tree_and_ics_path manifest_records_tree_and_ics_path
run_test manifest_is_valid_json manifest_is_valid_json
run_test refuses_existing_manifest refuses_existing_manifest
finish
