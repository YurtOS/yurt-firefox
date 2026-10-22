#!/usr/bin/env bash
# Tests for pq_classify and pq_leftover in scripts/lib/patch-queue.sh.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# Sourced tolerantly so that, before it exists, every case fails on its own.
# shellcheck source=../scripts/lib/patch-queue.sh
if [ -f "$ROOT/scripts/lib/patch-queue.sh" ]; then
  . "$ROOT/scripts/lib/patch-queue.sh"
else
  echo "WARN: scripts/lib/patch-queue.sh missing" >&2
fi

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# expect_class <path> <include|exclude|unclassified>
expect_class() {
  local out rc=0
  out=$(pq_classify "$1" 2>/dev/null) || rc=$?
  if [ "$2" = unclassified ]; then
    assert_eq 2 "$rc" "$1 exit status"
    assert_eq "" "$out" "$1 prints nothing"
  else
    assert_eq 0 "$rc" "$1 exit status"
    assert_eq "$2" "$out" "$1 class"
  fi
}

classifies_included_prefixes() {
  local p
  for p in js/src/jsapi.cpp js/src/builtin/streams/a.cpp js/public/Stream.h \
    build/moz.configure mfbt/RandomNum.cpp modules/libpref/init/all.js \
    third_party/weval/x third_party/wizer/y/z config/system-headers.mozbuild; do
    expect_class "$p" include
  done
}

classifies_excluded_prefixes() {
  local p
  for p in dom/webidl/A.webidl testing/web-platform/meta/x.ini .github/workflows/ci.yml \
    .agents/skills/s/SKILL.md .claude/skills docs/agents/org.md AGENTS.md CLAUDE.md; do
    expect_class "$p" exclude
  done
}

unclassified_exits_2() {
  expect_class something/new.c unclassified
  # Prefixes match whole path components only.
  expect_class jsx/a.c unclassified
  expect_class AGENTS.md.bak unclassified
  expect_class docs/other.md unclassified
}

longest_prefix_wins() {
  local d=$BASE/lists
  mkdir -p "$d"
  printf '# comment\na\na/b/c\n\n' >"$d/include.txt"
  printf 'a/b\n' >"$d/exclude.txt"
  export PQ_LISTS_DIR=$d
  expect_class a/x include
  expect_class a/b/x exclude
  expect_class a/b/c/x include
  expect_class a/b exclude
  expect_class a/bc include
  expect_class z/q unclassified
}

# A diff repo: tag V1 and branch yurt that adds the given files.
# make_diff_repo <dir> <file...>
make_diff_repo() {
  local dir=$1 f
  shift
  git init -q "$dir"
  echo base >"$dir/base.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  git -C "$dir" tag V1
  git -C "$dir" checkout -q -b yurt
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    echo "$f" >"$dir/$f"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m yurt
}

leftover_empty_when_all_classified() {
  local out
  make_diff_repo "$BASE/r1" js/a.c dom/a dom/b .github/x AGENTS.md
  export PQ_DIFF_REPO=$BASE/r1
  out=$(pq_leftover V1 yurt 2)
  assert_eq "" "$out"
}

leftover_lists_unclassified() {
  local out
  make_diff_repo "$BASE/r2" js/a.c dom/a new/thing.c other.txt
  export PQ_DIFF_REPO=$BASE/r2
  out=$(pq_leftover V1 yurt 1 2>&1) && return 1
  case $out in *new/thing.c*other.txt*) ;; *) echo "missing leftovers: $out"; return 1 ;; esac
  case $out in *js/a.c*) echo "included path reported: $out"; return 1 ;; esac
}

leftover_asserts_dom_count() {
  local out
  make_diff_repo "$BASE/r3" js/a.c dom/a dom/b
  export PQ_DIFF_REPO=$BASE/r3
  out=$(pq_leftover V1 yurt 3 2>&1) && return 1
  case $out in *"dom/"*"expected 3"*"found 2"*) ;; *) echo "wrong reason: $out"; return 1 ;; esac
  # The default expectation is 19.
  out=$(pq_leftover V1 yurt 2>&1) && return 1
  case $out in *"expected 19"*"found 2"*) ;; *) echo "wrong default: $out"; return 1 ;; esac
}

leftover_defaults_to_19_dom_files() {
  local i out files=(js/a.c)
  for i in $(seq 1 19); do files+=("dom/f$i"); done
  make_diff_repo "$BASE/r4" "${files[@]}"
  export PQ_DIFF_REPO=$BASE/r4
  out=$(pq_leftover V1 yurt)
  assert_eq "" "$out"
}

run_test classifies_included_prefixes classifies_included_prefixes
run_test classifies_excluded_prefixes classifies_excluded_prefixes
run_test unclassified_exits_2 unclassified_exits_2
run_test longest_prefix_wins longest_prefix_wins
run_test leftover_empty_when_all_classified leftover_empty_when_all_classified
run_test leftover_lists_unclassified leftover_lists_unclassified
run_test leftover_asserts_dom_count leftover_asserts_dom_count
run_test leftover_defaults_to_19_dom_files leftover_defaults_to_19_dom_files
finish
