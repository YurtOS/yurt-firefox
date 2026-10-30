#!/usr/bin/env bash
# Tests for scripts/accept-engine.sh with stubbed cmake, NightMonkey
# scripts/ci-suite.sh and scripts/snapshot-roundtrip.sh in a tempdir (the
# execute-with-stubs style of t_gate_lanes in tests/test-workflows.sh). No
# build, no wasmtime, no network.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO
unset WASMTIME WASMTIME_FLAGS NIGHT_FIREFOX_TESTS

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

ACCEPT="$ROOT/scripts/accept-engine.sh"

BASE=$(mktemp -d)
BASE=$(cd "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT

# setup: a case directory D with
#   pkg/spidermonkey/          the extracted engine package
#   testsrc/js/src/...         the extracted test sources
#   tc/bin/clang{,++}, sysroot the toolchain
#   nm/                        NightMonkey: CMakeLists.txt and stub scripts
#   stubs/cmake                a cmake that "builds" nm/build/bin/*
#   root/baseline/jit-floor.txt (the real floors) as PQ_ROOT
#   home/                      $HOME (no .mozbuild)
#   runner/                    $RUNNER_TEMP
# Every stub appends one line to $D/calls. Stub behaviour is set with
# environment variables: STUB_CONFIGURE_RC, STUB_BUILD_RC, STUB_NO_SHELL,
# STUB_SNAP_RC, and per lane (AOT, INTERPRETER) STUB_<L>_RC, STUB_<L>_COUNT
# (default 20000), STUB_<L>_LINE=none|twice|nolog (nolog: no log written).
setup() {
  D=$(mktemp -d "$BASE/case.XXXXXX")
  mkdir -p "$D/pkg/spidermonkey/include-private" "$D/testsrc/js/src/jit-test" "$D/tc/bin" "$D/sysroot" \
    "$D/nm/scripts" "$D/stubs" "$D/root/baseline" "$D/home" "$D/runner"
  echo '{}' >"$D/pkg/spidermonkey/include-private/js-build-config.json"
  echo '# jit_test.py' >"$D/testsrc/js/src/jit-test/jit_test.py"
  printf '#!/bin/sh\nexit 0\n' >"$D/tc/bin/clang"
  cp "$D/tc/bin/clang" "$D/tc/bin/clang++"
  chmod +x "$D/tc/bin/clang" "$D/tc/bin/clang++"
  echo 'project(nightmonkey)' >"$D/nm/CMakeLists.txt"
  cp "$ROOT/baseline/jit-floor.txt" "$D/root/baseline/jit-floor.txt"
  : >"$D/calls"

  cat >"$D/stubs/cmake" <<'SH'
#!/bin/bash
echo "cmake $* | cwd=$PWD" >>"$CALLS"
if [ "$1" = --build ]; then
  [ "${STUB_BUILD_RC:-0}" = 0 ] || exit "$STUB_BUILD_RC"
  mkdir -p "$2/bin"
  for f in nightmonkey js inproc-shell.sh; do
    [ "$f" = inproc-shell.sh ] && [ -n "${STUB_NO_SHELL:-}" ] && continue
    printf '#!/bin/sh\n' >"$2/bin/$f"; chmod +x "$2/bin/$f"
  done
  exit 0
fi
exit "${STUB_CONFIGURE_RC:-0}"
SH
  cat >"$D/nm/scripts/ci-suite.sh" <<'SH'
#!/bin/bash
# Stub of NightMonkey's ci-suite.sh <suite> <lane>: writes the lane log as the
# real one does (tee into $RUNNER_TEMP/nightmonkey-logs/<suite>-<lane>.log).
echo "ci-suite.sh $* | NIGHT_FIREFOX_TESTS=${NIGHT_FIREFOX_TESTS:-} | cwd=$PWD" >>"$CALLS"
L=$(echo "$2" | tr '[:lower:]' '[:upper:]')
eval "rc=\${STUB_${L}_RC:-0} count=\${STUB_${L}_COUNT:-20000} line=\${STUB_${L}_LINE:-once}"
logs=${RUNNER_TEMP:?}/nightmonkey-logs
mkdir -p "$logs"
[ "$line" != nolog ] || exit "$rc"
{
  echo "TEST-PASS | basic/simple.js | Success"
  case $line in
    once) echo "night: jit: $count passing execution results verified" ;;
    twice) echo "night: jit: $count passing execution results verified"
      echo "night: jit: $count passing execution results verified" ;;
  esac
} | tee "$logs/$1-$2.log"
exit "$rc"
SH
  cat >"$D/nm/scripts/snapshot-roundtrip.sh" <<'SH'
#!/bin/bash
echo "snapshot-roundtrip.sh $* | WASMTIME_FLAGS=${WASMTIME_FLAGS:-} | cwd=$PWD" >>"$CALLS"
exit "${STUB_SNAP_RC:-0}"
SH
  chmod +x "$D/stubs/cmake" "$D/nm/scripts/ci-suite.sh" "$D/nm/scripts/snapshot-roundtrip.sh"
}

# run_accept [VAR=value...] [-- args...]: run accept-engine.sh with the stubs
# (default arguments unless args follow --); sets OUT and RC.
run_accept() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  if [ $# -eq 0 ]; then
    set -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" --nightmonkey "$D/nm"
  fi
  RC=0
  OUT=$(cd "$BASE" && env PATH="$D/stubs:$PATH" HOME="$D/home" RUNNER_TEMP="$D/runner" CALLS="$D/calls" \
    PQ_ROOT="$D/root" ${envs[@]+"${envs[@]}"} "$ACCEPT" "$@" 2>&1) || RC=$?
}

# expect_fail <rc> <text>: exit <rc> and the output contains <text>.
expect_fail() {
  assert_eq "$1" "$RC" "$OUT"
  case $OUT in *"$2"*) ;; *) echo "output lacks '$2': $OUT" >&2; return 1 ;; esac
}

# called <pattern>: some recorded call matches the grep -E pattern.
called() { grep -Eq "$1" "$D/calls"; }

all_green_runs_every_step_in_order() {
  setup
  run_accept
  assert_eq 0 "$RC" "$OUT"
  local want
  want="cmake -S $D/nm -B $D/nm/build -DSPIDERMONKEY_DIST=$D/pkg/spidermonkey -DNIGHT_TOOLCHAIN_ROOT=$D/tc -DNIGHT_SYSROOT=$D/sysroot | cwd=$D/nm
cmake --build $D/nm/build | cwd=$D/nm
snapshot-roundtrip.sh $D/nm/build | WASMTIME_FLAGS= | cwd=$D/nm
ci-suite.sh jit aot | NIGHT_FIREFOX_TESTS=$D/testsrc | cwd=$D/nm
ci-suite.sh jit interpreter | NIGHT_FIREFOX_TESTS=$D/testsrc | cwd=$D/nm"
  assert_eq "$want" "$(cat "$D/calls")" "calls"
  case $OUT in *"aot: 20000 verified (floor 12307)"*"interpreter: 20000 verified (floor 12494)"*) ;;
    *) echo "counts not reported: $OUT" >&2; return 1 ;; esac
  [ -f "$D/runner/nightmonkey-logs/jit-aot.log" ] && [ -f "$D/runner/nightmonkey-logs/jit-interpreter.log" ]
}

configure_failure_fails() {
  setup
  run_accept STUB_CONFIGURE_RC=1
  expect_fail 1 "FAIL at build: cmake configure"
  ! called '^(ci-suite|snapshot)' || { echo "ran past a failed configure" >&2; return 1; }
}

build_failure_fails() {
  setup
  run_accept STUB_BUILD_RC=2
  expect_fail 1 "FAIL at build: cmake --build"
  ! called '^(ci-suite|snapshot)' || { echo "ran past a failed build" >&2; return 1; }
  setup
  run_accept STUB_NO_SHELL=1
  expect_fail 1 "FAIL at build: missing $D/nm/build/bin/inproc-shell.sh"
}

aot_lane_failure_fails() {
  setup
  run_accept STUB_AOT_RC=1
  expect_fail 1 "FAIL at jit aot"
  ! called '^ci-suite.sh jit interpreter' || { echo "ran interpreter after aot failed" >&2; return 1; }
}

interpreter_lane_failure_fails() {
  setup
  run_accept STUB_INTERPRETER_RC=1
  expect_fail 1 "FAIL at jit interpreter"
}

# Exactly at the floor passes; one below fails, for each lane.
floor_comparison() {
  setup
  run_accept STUB_AOT_COUNT=12307 STUB_INTERPRETER_COUNT=12494
  assert_eq 0 "$RC" "$OUT"
  setup
  run_accept STUB_AOT_COUNT=12306
  expect_fail 1 "FAIL at jit aot: 12306 verified is below the floor aot_verified=12307"
  setup
  run_accept STUB_INTERPRETER_COUNT=12493
  expect_fail 1 "FAIL at jit interpreter: 12493 verified is below the floor interpreter_verified=12494"
}

# A lane log without the verified line, or with two, never passes, even when
# the lane exits 0; a stale log from an earlier run is not read.
verified_line_required() {
  setup
  run_accept STUB_AOT_LINE=none
  expect_fail 1 "FAIL at jit aot: no 'night: jit: N passing execution results verified' line"
  setup
  run_accept STUB_INTERPRETER_LINE=twice
  expect_fail 1 "FAIL at jit interpreter: 2 'night: jit: N passing execution results verified' lines"
  setup
  mkdir -p "$D/runner/nightmonkey-logs"
  echo "night: jit: 99999 passing execution results verified" >"$D/runner/nightmonkey-logs/jit-aot.log"
  run_accept STUB_AOT_LINE=nolog
  expect_fail 1 "FAIL at jit aot: no lane log $D/runner/nightmonkey-logs/jit-aot.log"
}

snapshot_failure_fails() {
  local rc
  for rc in 1 2; do
    setup
    run_accept STUB_SNAP_RC=$rc
    expect_fail 1 "FAIL at snapshot"
    ! called '^ci-suite' || { echo "ran lanes after the snapshot failed" >&2; return 1; }
  done
}

snapshot_gets_wasmtime_flags() {
  setup
  run_accept "WASMTIME_FLAGS=-W unknown-imports-trap"
  assert_eq 0 "$RC" "$OUT"
  called "^snapshot-roundtrip.sh $D/nm/build \\| WASMTIME_FLAGS=-W unknown-imports-trap "
}

clean_runner_required_when_asked() {
  setup
  mkdir -p "$D/home/.mozbuild"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" --require-clean-runner
  expect_fail 1 "FAIL at clean-runner: $D/home/.mozbuild exists"
  [ ! -s "$D/calls" ] || { echo "ran steps on an unclean runner" >&2; return 1; }
  setup
  ln -s "$D/nowhere" "$D/home/.mozbuild"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" --require-clean-runner
  expect_fail 1 "FAIL at clean-runner: $D/home/.mozbuild exists"
  # Without the flag a developer's ~/.mozbuild is fine.
  setup
  mkdir -p "$D/home/.mozbuild"
  run_accept
  assert_eq 0 "$RC" "$OUT"
  # With the flag and no ~/.mozbuild it passes.
  setup
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" --require-clean-runner
  assert_eq 0 "$RC" "$OUT"
}

# floor_case <file content> <message>: the floor file is refused (exit 2)
# before anything runs.
floor_case() {
  setup
  printf '%b' "$1" >"$D/root/baseline/jit-floor.txt"
  run_accept
  expect_fail 2 "$2"
  [ ! -s "$D/calls" ] || { echo "ran steps with a bad floor file" >&2; return 1; }
}

floor_file_checked() {
  setup
  rm "$D/root/baseline/jit-floor.txt"
  run_accept
  expect_fail 2 "baseline/jit-floor.txt: missing"
  [ ! -s "$D/calls" ]
  floor_case 'aot_verified=12307\n' "baseline/jit-floor.txt: interpreter_verified is not set"
  floor_case 'aot_verified=12307\ninterpreter_verified=12494\nextra=1\n' "baseline/jit-floor.txt: line 3: unknown key extra"
  floor_case 'aot_verified=12307\naot_verified=1\ninterpreter_verified=12494\n' "baseline/jit-floor.txt: line 2: duplicate key aot_verified"
  floor_case 'aot_verified=12307\ninterpreter_verified=lots\n' "baseline/jit-floor.txt: line 2: interpreter_verified must be a non-negative integer"
  floor_case 'aot_verified=12307\ninterpreter_verified=\n' "baseline/jit-floor.txt: line 2: interpreter_verified must be a non-negative integer"
  floor_case 'aot_verified 12307\ninterpreter_verified=12494\n' "baseline/jit-floor.txt: line 1: not key=value"
  # Comments (also indented) and blank lines are fine.
  setup
  printf '# c\n\naot_verified=12307\n  # d\ninterpreter_verified=12494\n' >"$D/root/baseline/jit-floor.txt"
  run_accept
  assert_eq 0 "$RC" "$OUT"
}

usage_and_prerequisites() {
  local good
  setup
  RC=0; OUT=$("$ACCEPT" 2>&1) || RC=$?
  assert_eq 2 "$RC" "no args: $OUT"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot"
  expect_fail 2 "--nightmonkey"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" --bogus
  expect_fail 2 "unknown argument: --bogus"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" --nightmonkey
  expect_fail 2 "--nightmonkey needs a value"
  good="--testsrc $D/testsrc --toolchain $D/tc --sysroot $D/sysroot --nightmonkey $D/nm"
  # shellcheck disable=SC2086 # $good is word-split on purpose (no spaces in BASE)
  {
    run_accept -- --package "$D/testsrc" $good; expect_fail 2 "spidermonkey/include-private/js-build-config.json"
  }
  run_accept -- --package "$D/pkg" --testsrc "$D/pkg" --toolchain "$D/tc" --sysroot "$D/sysroot" --nightmonkey "$D/nm"
  expect_fail 2 "js/src/jit-test/jit_test.py"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/sysroot" --sysroot "$D/sysroot" --nightmonkey "$D/nm"
  expect_fail 2 "bin/clang"
  run_accept -- --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/none" --nightmonkey "$D/nm"
  expect_fail 2 "$D/none"
  rm "$D/nm/scripts/snapshot-roundtrip.sh"
  run_accept
  expect_fail 2 "scripts/snapshot-roundtrip.sh"
  [ ! -s "$D/calls" ] || { echo "ran steps with a missing prerequisite" >&2; return 1; }
}

missing_cmake_is_a_prerequisite() {
  setup
  local d=$BASE/nocmake.$$ t
  mkdir -p "$d"
  for t in bash env dirname mktemp rm mkdir cat grep sed tr tee python3; do
    ln -s "$(command -v "$t")" "$d/$t" 2>/dev/null || true
  done
  RC=0
  OUT=$(cd "$BASE" && env PATH="$d" HOME="$D/home" RUNNER_TEMP="$D/runner" CALLS="$D/calls" PQ_ROOT="$D/root" \
    "$d/bash" "$ACCEPT" --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" 2>&1) || RC=$?
  expect_fail 2 "cmake not found"
}

# Without RUNNER_TEMP (a developer machine) the lanes still get one, and its
# logs are the ones parsed.
runner_temp_defaulted() {
  setup
  RC=0
  OUT=$(cd "$BASE" && env -u RUNNER_TEMP PATH="$D/stubs:$PATH" HOME="$D/home" CALLS="$D/calls" PQ_ROOT="$D/root" \
    "$ACCEPT" --package "$D/pkg" --testsrc "$D/testsrc" --toolchain "$D/tc" --sysroot "$D/sysroot" \
    --nightmonkey "$D/nm" 2>&1) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  case $OUT in *"aot: 20000 verified"*) ;; *) echo "no count: $OUT" >&2; return 1 ;; esac
}

run_test "all green runs every step in order" all_green_runs_every_step_in_order
run_test "configure failure fails" configure_failure_fails
run_test "build failure fails" build_failure_fails
run_test "aot lane failure fails" aot_lane_failure_fails
run_test "interpreter lane failure fails" interpreter_lane_failure_fails
run_test "floor comparison (>=)" floor_comparison
run_test "verified line required" verified_line_required
run_test "snapshot failure fails" snapshot_failure_fails
run_test "snapshot gets WASMTIME_FLAGS" snapshot_gets_wasmtime_flags
run_test "clean runner required when asked" clean_runner_required_when_asked
run_test "floor file checked" floor_file_checked
run_test "usage and prerequisites" usage_and_prerequisites
run_test "missing cmake is a prerequisite" missing_cmake_is_a_prerequisite
run_test "RUNNER_TEMP defaulted" runner_temp_defaulted
finish
