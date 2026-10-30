#!/usr/bin/env bash
# Accept a packaged engine: build NightMonkey against it and run the gate.
#   accept-engine.sh --package DIR --testsrc DIR --toolchain DIR --sysroot DIR
#                    --nightmonkey DIR [--require-clean-runner]
#
#   --package      the extracted engine archive (holds spidermonkey/)
#   --testsrc      the extracted test-source bundle(s) (holds js/src/jit-test)
#   --toolchain    the extracted clang toolchain (holds bin/clang, bin/clang++)
#   --sysroot      the extracted WASI sysroot
#   --nightmonkey  a NightMonkey checkout (at NIGHTMONKEY_PIN in CI)
#   --require-clean-runner  fail if $HOME/.mozbuild exists (release.yml sets
#                  it: the package must not be resolving anything from a
#                  producer toolchain); off for developer machines
#
# Steps, in order; the first failing step stops the run and is named
# ("accept-engine: FAIL at <step>: <reason>"):
#   build        cmake -S <nm> -B <nm>/build
#                  -DSPIDERMONKEY_DIST=<package>/spidermonkey
#                  -DNIGHT_TOOLCHAIN_ROOT=<toolchain> -DNIGHT_SYSROOT=<sysroot>
#                  -DNIGHT_INPROCESS=ON -DNIGHT_INPROC_HOST=runner -DNIGHT_DEBUG=OFF
#                cmake --build <nm>/build; then bin/nightmonkey, bin/js,
#                bin/js-inproc, bin/wasm-jit-runner and bin/inproc-shell.sh
#                must exist. The in-process options are forced because a
#                reused build dir's CMakeCache.txt would otherwise keep them
#                (NIGHT_INPROCESS=OFF leaves old lane binaries in place); with
#                them forced, cmake's dependency tracking rebuilds what the
#                package changes, so binary times are not checked.
#                <nm>/build is NightMonkey's
#                fixed build dir (ci-suite.sh runs <nm>/build); an existing one
#                (a restored cargo cache) is reconfigured with these values.
#   snapshot     <nm>/scripts/snapshot-roundtrip.sh <nm>/build, run directly
#                (ci-suite.sh's interface is exactly <suite> <lane>). WASMTIME
#                and WASMTIME_FLAGS pass through; a real runner likely needs
#                WASMTIME_FLAGS="-W unknown-imports-trap". It runs first of
#                the checks because it takes seconds and the lanes an hour.
#   jit aot, jit interpreter
#                <nm>/scripts/ci-suite.sh jit <lane> with
#                NIGHT_FIREFOX_TESTS=<testsrc> and a fresh NIGHT_CACHE_DIR; it
#                must exit 0 and its log (text: NUL bytes are refused)
#                $RUNNER_TEMP/nightmonkey-logs/jit-<lane>.log must hold exactly
#                one "night: jit: N passing execution results verified" line
#                (NightMonkey's scripts/check-test-log.py; N is passed minus
#                skipped) with N >= the lane's floor. The log is removed before
#                the lane, so a stale one is never read. Without RUNNER_TEMP (a
#                developer machine) a temporary one is used.
#
# Floors: baseline/jit-floor.txt, lines `aot_verified=N` and
# `interpreter_verified=N` (each exactly once, N a non-negative integer);
# blank lines and `#` comments are allowed, anything else is refused.
# PQ_ROOT overrides the repository root (tests use it).
# Exit codes: 0 accepted; 1 a step failed (or the runner is not clean);
# 2 usage, a missing input or tool, or a bad floor file (nothing was run).
set -euo pipefail
unset CDPATH
export LC_ALL=C

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}

usage() {
  [ $# -eq 0 ] || echo "accept-engine: $*" >&2
  echo "usage: accept-engine.sh --package DIR --testsrc DIR --toolchain DIR --sysroot DIR --nightmonkey DIR [--require-clean-runner]" >&2
  exit 2
}
prereq() { echo "accept-engine: $*" >&2; exit 2; }
fail() { echo "accept-engine: FAIL at $1: $2" >&2; exit 1; }
step() { echo "accept-engine: $*"; }

# Inherited NIGHT_* and SPIDERMONKEY_* variables are cleared: at the pin,
# NightMonkey's inproc-shell.sh takes the shell and runner from
# NIGHT_WASM_SHELL and NIGHT_RUNNER (so a lane would qualify another engine),
# and NIGHT_CACHE_DIR, NIGHT_INPROCESS_OFF, NIGHT_OPTIONS, NIGHT_PAD_SEED and
# NIGHT_TEST_DUMP change what runs. This script then sets the ones it means:
# NIGHT_FIREFOX_TESTS and a fresh NIGHT_CACHE_DIR for the lanes (ci-suite.sh
# sets the per-lane NIGHT_INPROCESS_OFF/NIGHT_INPROC_STRICT/NIGHT_OPTIONS).
# WASMTIME and WASMTIME_FLAGS pass through to the snapshot step on purpose.
for v in $(env | sed -n -E 's/^((NIGHT|SPIDERMONKEY)_[A-Za-z0-9_]*)=.*/\1/p'); do
  unset "$v" 2>/dev/null || true
  [ -z "${!v+set}" ] || prereq "$v is readonly and cannot be cleared"
done

package= testsrc= toolchain= sysroot= nm= clean=0
while [ $# -gt 0 ]; do
  case $1 in
    --package | --testsrc | --toolchain | --sysroot | --nightmonkey)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --package) package=$2 ;;
        --testsrc) testsrc=$2 ;;
        --toolchain) toolchain=$2 ;;
        --sysroot) sysroot=$2 ;;
        --nightmonkey) nm=$2 ;;
      esac
      shift 2 ;;
    --require-clean-runner) clean=1; shift ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$package" ] && [ -n "$testsrc" ] && [ -n "$toolchain" ] && [ -n "$sysroot" ] && [ -n "$nm" ] ||
  usage "all of --package --testsrc --toolchain --sysroot --nightmonkey are required"

# absdir <dir>: the directory, absolute, or a prerequisite failure.
absdir() {
  [ -d "$1" ] || prereq "no such directory: $1"
  (cd "$1" && pwd -P)
}
package=$(absdir "$package")
testsrc=$(absdir "$testsrc")
toolchain=$(absdir "$toolchain")
sysroot=$(absdir "$sysroot")
nm=$(absdir "$nm")
[ -f "$package/spidermonkey/include-private/js-build-config.json" ] ||
  prereq "$package is not an engine package: no spidermonkey/include-private/js-build-config.json"
[ -f "$testsrc/js/src/jit-test/jit_test.py" ] ||
  prereq "$testsrc is not a test-source tree: no js/src/jit-test/jit_test.py"
[ -x "$toolchain/bin/clang" ] && [ -x "$toolchain/bin/clang++" ] ||
  prereq "$toolchain is not a clang toolchain: no executable bin/clang and bin/clang++"
for f in CMakeLists.txt scripts/ci-suite.sh scripts/snapshot-roundtrip.sh; do
  [ -f "$nm/$f" ] || prereq "$nm is not a NightMonkey checkout: no $f"
done
command -v cmake >/dev/null 2>&1 || prereq "cmake not found"

# Floors.
floor_file=$ROOT/baseline/jit-floor.txt
[ -f "$floor_file" ] || prereq "baseline/jit-floor.txt: missing ($floor_file)"
aot_floor= interpreter_floor= n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case $trimmed in '' | '#'*) continue ;; esac
  case $trimmed in *=*) ;; *) prereq "baseline/jit-floor.txt: line $n: not key=value: $line" ;; esac
  key=${trimmed%%=*} value=${trimmed#*=}
  case $value in '' | *[!0-9]*) prereq "baseline/jit-floor.txt: line $n: $key must be a non-negative integer, got '$value'" ;; esac
  case $key in
    aot_verified)
      [ -z "$aot_floor" ] || prereq "baseline/jit-floor.txt: line $n: duplicate key $key"
      aot_floor=$value ;;
    interpreter_verified)
      [ -z "$interpreter_floor" ] || prereq "baseline/jit-floor.txt: line $n: duplicate key $key"
      interpreter_floor=$value ;;
    *) prereq "baseline/jit-floor.txt: line $n: unknown key $key" ;;
  esac
done <"$floor_file"
[ -n "$aot_floor" ] || prereq "baseline/jit-floor.txt: aot_verified is not set"
[ -n "$interpreter_floor" ] || prereq "baseline/jit-floor.txt: interpreter_verified is not set"

if [ "$clean" -eq 1 ]; then
  mozbuild=${HOME:?HOME must be set}/.mozbuild
  if [ -e "$mozbuild" ] || [ -L "$mozbuild" ]; then
    fail clean-runner "$mozbuild exists; a release acceptance runs on a runner without a producer toolchain"
  fi
fi

# RUNNER_TEMP is made absolute (the lanes run inside the NightMonkey
# checkout). Without one, a temporary directory is used; it is removed after
# a passing run and kept, with its path printed, after a failing one.
if [ -z "${RUNNER_TEMP:-}" ]; then
  RUNNER_TEMP=$(mktemp -d)
  keep_or_remove() {
    local st=$?
    if [ "$st" -eq 0 ]; then rm -rf "$RUNNER_TEMP"; else echo "accept-engine: logs kept in $RUNNER_TEMP" >&2; fi
  }
  trap keep_or_remove EXIT
else
  mkdir -p "$RUNNER_TEMP"
  RUNNER_TEMP=$(cd "$RUNNER_TEMP" && pwd -P)
fi
export RUNNER_TEMP
logs=$RUNNER_TEMP/nightmonkey-logs
mkdir -p "$logs"

build=$nm/build
step "build: NightMonkey in $build against $package/spidermonkey"
(cd "$nm" && cmake -S "$nm" -B "$build" -DSPIDERMONKEY_DIST="$package/spidermonkey" \
  -DNIGHT_TOOLCHAIN_ROOT="$toolchain" -DNIGHT_SYSROOT="$sysroot" \
  -DNIGHT_INPROCESS=ON -DNIGHT_INPROC_HOST=runner -DNIGHT_DEBUG=OFF) ||
  fail build "cmake configure failed"
(cd "$nm" && cmake --build "$build") || fail build "cmake --build failed"
for f in nightmonkey js js-inproc wasm-jit-runner inproc-shell.sh; do
  [ -x "$build/bin/$f" ] || fail build "missing $build/bin/$f"
done

step "snapshot: scripts/snapshot-roundtrip.sh $build"
rc=0
(cd "$nm" && scripts/snapshot-roundtrip.sh "$build") || rc=$?
case $rc in
  0) ;;
  2) fail snapshot "scripts/snapshot-roundtrip.sh exited 2: missing prerequisite (wasmtime? set WASMTIME, see its usage)" ;;
  *) fail snapshot "scripts/snapshot-roundtrip.sh exited $rc" ;;
esac

# A fresh module cache for the lanes (inproc-shell.sh's NIGHT_CACHE_DIR).
cache=$RUNNER_TEMP/nightmonkey-wjr-cache
rm -rf "$cache"
mkdir -p "$cache"

summary=
for lane in aot interpreter; do
  if [ "$lane" = aot ]; then floor=$aot_floor; else floor=$interpreter_floor; fi
  log=$logs/jit-$lane.log
  rm -f "$log"
  step "jit $lane: scripts/ci-suite.sh jit $lane (NIGHT_FIREFOX_TESTS=$testsrc)"
  rc=0
  (cd "$nm" && NIGHT_FIREFOX_TESTS=$testsrc NIGHT_CACHE_DIR=$cache scripts/ci-suite.sh jit "$lane") || rc=$?
  [ "$rc" -eq 0 ] || fail "jit $lane" "scripts/ci-suite.sh jit $lane exited $rc"
  [ -f "$log" ] || fail "jit $lane" "no lane log $log"
  # A log is text: a NUL byte makes grep treat it as binary (BSD grep then
  # prints "Binary file ... matches"), so it is refused outright.
  [ "$(tr -d '\000' <"$log" | wc -c | tr -d ' ')" = "$(wc -c <"$log" | tr -d ' ')" ] ||
    fail "jit $lane" "$log contains NUL bytes"
  matches=$(grep -a -E '^night: jit: [0-9]+ passing execution results verified$' "$log" || true)
  count=0
  [ -z "$matches" ] || count=$(printf '%s\n' "$matches" | grep -c .)
  case $count in
    0) fail "jit $lane" "no 'night: jit: N passing execution results verified' line in $log" ;;
    1) ;;
    *) fail "jit $lane" "$count 'night: jit: N passing execution results verified' lines in $log; want one" ;;
  esac
  verified=$(printf '%s\n' "$matches" | sed 's/^night: jit: \([0-9]*\) .*/\1/')
  case $verified in '' | *[!0-9]*) fail "jit $lane" "verified count '$verified' is not a number" ;; esac
  # Integer compare without overflow worries: strip leading zeros, compare
  # length, then lexically.
  v=$(echo "$verified" | sed 's/^0*//') f=$(echo "$floor" | sed 's/^0*//')
  if [ "${#v}" -lt "${#f}" ] || { [ "${#v}" -eq "${#f}" ] && [[ $v < $f ]]; }; then
    fail "jit $lane" "$verified verified is below the floor ${lane}_verified=$floor"
  fi
  summary="$summary $lane: $verified verified (floor $floor);"
  step "jit $lane: $verified verified (floor $floor)"
done
echo "accept-engine: accepted:$summary snapshot round-trip passed"
