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

# finish: print the summary; exit non-zero if any test failed.
finish() {
  echo "$((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  [ "$TESTS_RUN" -gt 0 ] || { echo "no tests ran" >&2; exit 1; }
}
