#!/usr/bin/env bash
# Minimal test harness. Source it, define test functions, call run_test for each
# and finish at the end. Assertions return non-zero; run_test runs each test in a
# subshell under `set -e`, so a failed assertion or command fails the test.
# Hermetic git: fixed identity and dates, no user or system config.

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

TESTS_RUN=0
TESTS_FAILED=0

# run_test <name> <fn>
run_test() {
  local name=$1 fn=$2 out
  out=$(mktemp)
  TESTS_RUN=$((TESTS_RUN + 1))
  # A background subshell is not a conditional context, so `set -e` stays
  # effective inside it (it would not under `if ( ... )` or `( ... ) || ...`).
  ( set -e; "$fn" ) >"$out" 2>&1 &
  if wait $!; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    sed 's/^/     /' "$out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -f "$out"
}

# assert_eq <expected> <actual> [message]
assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'assert_eq failed%s\n  expected: %s\n  actual:   %s\n' "${3:+ ($3)}" "$1" "$2" >&2
    return 1
  fi
}

# assert_fails <command...>: the command must exit non-zero.
assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf 'expected failure but succeeded: %s\n' "$*" >&2
    return 1
  fi
}

# with_git_config <how> <key> <value> <command...>: run the command in a subshell
# with key=value set in the git config the way a developer or hook could set it:
# by GIT_CONFIG_COUNT ("count") or in a temporary $HOME/.gitconfig ("home"). Fails
# if plain git does not see the setting, so a hostile case cannot be vacuous.
with_git_config() {
  local how=$1 key=$2 value=$3
  shift 3
  (
    case $how in
      count) export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="$key" GIT_CONFIG_VALUE_0="$value" ;;
      home)
        HOME=$(mktemp -d "${BASE:?}/home.XXXXXX")
        export HOME
        unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
        git config --global "$key" "$value"
        ;;
      *) echo "with_git_config: unknown mode $how" >&2; exit 2 ;;
    esac
    [ "$(git config --get "$key")" = "$value" ] || { echo "with_git_config: $key not in effect" >&2; exit 1; }
    "$@"
  )
}

# with_git_env <repo> <vars> <command...>: run the command in a subshell with the
# repository-selection variables in <vars> (any of GIT_DIR GIT_WORK_TREE
# GIT_INDEX_FILE) exported to point at <repo>, as hooks and dotfile setups do.
with_git_env() {
  local repo=$1 vars=$2 v
  shift 2
  (
    for v in $vars; do
      case $v in
        GIT_DIR) export GIT_DIR="$repo/.git" ;;
        GIT_WORK_TREE) export GIT_WORK_TREE="$repo" ;;
        GIT_INDEX_FILE) export GIT_INDEX_FILE="$repo/.git/index" ;;
        *) echo "with_git_env: unknown variable $v" >&2; exit 2 ;;
      esac
    done
    "$@"
  )
}

# with_readonly_git_env <repo> <script> [args...]: run the bash <script> (args in
# $1...) in a shell where exported GIT_DIR and GIT_WORK_TREE name <repo> and are
# readonly, so nothing in that shell can unset them.
with_readonly_git_env() {
  local repo=$1 script=$2
  shift 2
  GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" bash -c "readonly GIT_DIR GIT_WORK_TREE; $script" _ "$@"
}

# make_git_shim <dir> <version>: a `git` in <dir> that reports
# "git version <version>" for --version and runs the real git otherwise.
make_git_shim() {
  mkdir -p "$1" || return 1
  printf '#!/bin/sh\ncase " $* " in *" --version "*) echo "git version %s"; exit 0 ;; esac\nexec "%s" "$@"\n' \
    "$2" "$(command -v git)" >"$1/git" || return 1
  chmod +x "$1/git"
}

# make_decoy <dir>: a repository that code under test must never touch.
make_decoy() {
  mkdir -p "$1" || return 1
  git -C "$1" init -q || return 1
  echo mine >"$1/mine.txt" || return 1
  git -C "$1" add -A || return 1
  git -C "$1" commit -q -m decoy
}

# repo_state <dir>: HEAD, index checksum and worktree file checksums of a repo.
repo_state() {
  git -C "$1" rev-parse HEAD || return 1
  cksum <"$1/.git/index" || return 1
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
}

# finish: print the summary; exit non-zero if any test failed.
finish() {
  echo "$((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  [ "$TESTS_RUN" -gt 0 ] || { echo "no tests ran" >&2; exit 1; }
}
