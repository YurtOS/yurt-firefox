#!/usr/bin/env bash
# Offline stand-in for Firefox: a tiny git repo with one commit tagged V1.
# Requires tests/lib.sh to be sourced first (hermetic git environment).

# make_fixture_upstream <dir>: create the repo; print the commit SHA of tag V1.
make_fixture_upstream() {
  local dir=$1
  mkdir -p "$dir/js/ics" "$dir/other" || return 1
  printf 'line%s\n' 1 2 3 4 5 6 7 8 9 10 >"$dir/js/a.txt" || return 1
  echo "ics readme" >"$dir/js/ics/README" || return 1
  echo b >"$dir/other/b.txt" || return 1
  git -C "$dir" init -q . || return 1
  git -C "$dir" add -A || return 1
  git -C "$dir" commit -q -m "fixture upstream" || return 1
  git -C "$dir" tag V1 || return 1
  git -C "$dir" rev-parse 'V1^{commit}'
}
