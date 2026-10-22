#!/usr/bin/env bash
# Tests for the shared test scaffolding (tests/lib.sh, tests/fixture-upstream.sh).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-upstream.sh
. "$ROOT/tests/fixture-upstream.sh"

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

fixture_has_tag_v1_with_files() {
  local sha
  sha=$(make_fixture_upstream "$BASE/up")
  assert_eq "$sha" "$(git -C "$BASE/up" rev-parse 'V1^{commit}')" "printed sha is the V1 commit"
  local files
  files=$(git -C "$BASE/up" ls-tree -r --name-only V1)
  assert_eq $'js/a.txt\njs/ics/README\nother/b.txt' "$files" "V1 tree contents"
}

fixture_is_deterministic() {
  local a b
  a=$(make_fixture_upstream "$BASE/one")
  b=$(make_fixture_upstream "$BASE/two")
  assert_eq "$a" "$b" "same fixture, same commit"
}

assert_eq_fails_on_mismatch() {
  assert_fails assert_eq a b "must differ"
}

assert_fails_fails_on_success() {
  if assert_fails true; then
    echo "assert_fails accepted a succeeding command"
    return 1
  fi
}

run_test fixture_has_tag_v1_with_files fixture_has_tag_v1_with_files
run_test fixture_is_deterministic fixture_is_deterministic
run_test assert_eq_fails_on_mismatch assert_eq_fails_on_mismatch
run_test assert_fails_fails_on_success assert_fails_fails_on_success
finish
