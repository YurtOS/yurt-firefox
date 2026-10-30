#!/usr/bin/env bash
# Tests for .github/workflows/{queue,engine,gate}.yml: structure, actionlint, action
# pinning, the smoke command and the pinned wasmtime digest.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

WF="$ROOT/.github/workflows"
SMOKE="wasmtime run --dir=. dist/bin/js -e 'print(6*7)'"
WASMTIME_SHA=77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff

# body <file>: the workflow text without full-line comments, so a commented-out
# line cannot satisfy an assertion.
body() { grep -Ev '^[[:space:]]*#' "$1"; }

# has_line <file> <text>: some body line, leading blanks stripped, is exactly <text>.
has_line() { body "$1" | sed 's/^[[:space:]]*//' | grep -qxF -- "$2"; }

# step <file> <name>: the body of the step named <name>, up to the next step.
step() { body "$1" | awk -v n="- name: $2" '{t=$0; sub(/^[[:space:]]+/, "", t)} f && t ~ /^- name:/{exit} t == n{f=1} f{print}'; }

# step_run <file> <name>: the step's `run:` script (a one-liner, or a `run: |`
# block dedented).
step_run() {
  step "$1" "$2" | awk '
    blk { if ($0 ~ /^[[:space:]]*$/) { print ""; next }
          match($0, /^[[:space:]]*/)
          if (ind == "") ind = RLENGTH
          if (RLENGTH < ind) exit
          print substr($0, ind + 1); next }
    /^[[:space:]]*run: \|[[:space:]]*$/ { blk = 1; next }
    /^[[:space:]]*run: / { sub(/^[[:space:]]*run: /, ""); print; exit }'
}

# exec_step <file> <name> <dir> [name=value...]: run the step's script in <dir>
# as Actions runs a bash step (bash --noprofile --norc -eo pipefail), with the
# given environment. Returns the script's status; output goes to stdout/stderr.
exec_step() {
  local f=$1 name=$2 dir=$3 script
  shift 3
  script=$(step_run "$f" "$name")
  [ -n "$script" ] || { echo "${f##*/}: no run script in step '$name'" >&2; return 2; }
  (cd "$dir" && env "$@" bash --noprofile --norc -eo pipefail -c "$script")
}

# check_pin_step <file> <step name>: the step accepts a 40-hex pin and writes
# sha=<pin>; it fails, writing no sha=, on a branch name, an empty file, upper
# case, 39 hex digits and a pin with a trailing space-separated word.
check_pin_step() {
  local f=$1 name=$2 d out rc pin good=0123456789abcdef0123456789abcdef01234567
  d=$(mktemp -d)
  printf 'url=https://h.test/r\ntag=V1\ncommit=%s\ntree=%s\n' "$good" "$good" >"$d/UPSTREAM"
  printf '%s\n' "$good" >"$d/NIGHTMONKEY_PIN"
  : >"$d/out"
  exec_step "$f" "$name" "$d" GITHUB_OUTPUT="$d/out" >/dev/null 2>&1 ||
    { echo "${f##*/} '$name' rejected a valid pin" >&2; rm -rf "$d"; return 1; }
  grep -qx "sha=$good" "$d/out" || { echo "${f##*/} '$name' did not write sha=<pin>: $(cat "$d/out")" >&2; rm -rf "$d"; return 1; }
  for pin in main '' "$(printf '%s' "$good" | tr a-f A-F)" "${good%?}" "$good extra"; do
    printf '%s\n' "$pin" >"$d/NIGHTMONKEY_PIN"
    : >"$d/out"
    rc=0
    out=$(exec_step "$f" "$name" "$d" GITHUB_OUTPUT="$d/out" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "${f##*/} '$name' accepted pin '$pin'" >&2; rm -rf "$d"; return 1; }
    ! grep -q '^sha=' "$d/out" || { echo "${f##*/} '$name' wrote sha= for pin '$pin'" >&2; rm -rf "$d"; return 1; }
    case $out in *"40-hex"*) ;; *) echo "${f##*/} '$name' gave no reason for pin '$pin': $out" >&2; rm -rf "$d"; return 1 ;; esac
  done
  rm -rf "$d"
}

# no_or_on <file> <pattern>: no body line matching <pattern> carries `||`, so a
# failing check cannot be swallowed.
no_or_on() {
  local bad
  bad=$(body "$1" | grep -F -- "$2" | grep -F '||' || true)
  [ -z "$bad" ] || { printf '%s: failure swallowed:\n%s\n' "${1##*/}" "$bad" >&2; return 1; }
}

t_exist() {
  [ -f "$WF/queue.yml" ] || { echo "missing queue.yml" >&2; return 1; }
  [ -f "$WF/engine.yml" ] || { echo "missing engine.yml" >&2; return 1; }
  [ -f "$WF/gate.yml" ] || { echo "missing gate.yml" >&2; return 1; }
}

t_actionlint() {
  if ! command -v actionlint >/dev/null 2>&1; then
    if [ "${CI:-}" = true ]; then
      echo "actionlint is required when CI=true" >&2
      return 1
    fi
    echo "SKIP: actionlint not installed" >&2
    return 0
  fi
  actionlint "$WF/queue.yml" "$WF/engine.yml" "$WF/gate.yml"
}

t_pinned() {
  local f bad
  for f in queue.yml engine.yml gate.yml; do
    [ -f "$WF/$f" ] || { echo "missing $f" >&2; return 1; }
    bad=$(body "$WF/$f" | grep -E '^[[:space:]-]*uses:' | grep -Ev 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]+#.*)?$' || true)
    [ -z "$bad" ] || { printf '%s: unpinned uses:\n%s\n' "$f" "$bad" >&2; return 1; }
    body "$WF/$f" | grep -Eq '^[[:space:]-]*uses:' || { echo "$f has no uses:" >&2; return 1; }
  done
}

t_credentials() {
  local f n p
  for f in queue.yml engine.yml gate.yml; do
    n=$(body "$WF/$f" | grep -cE 'uses: actions/checkout@')
    p=$(body "$WF/$f" | grep -cE '^[[:space:]]+persist-credentials: false$')
    [ "$n" -gt 0 ] && [ "$n" = "$p" ] ||
      { echo "$f: $n checkouts, $p with persist-credentials: false" >&2; return 1; }
  done
}

t_permissions() {
  local f top block
  for f in queue.yml engine.yml gate.yml; do
    # The top-level block is exactly `permissions:` + `contents: read`, and no job
    # or step widens it with its own permissions.
    top=$(body "$WF/$f" | grep -E '^permissions:' || true)
    assert_eq "permissions:" "$top" "$f top-level permissions line"
    block=$(body "$WF/$f" | awk '/^permissions:/{f=1; next} f && /^[^[:space:]]/{exit} f && NF{print}')
    assert_eq "  contents: read" "$block" "$f top-level permissions block"
    if [ "$f" = gate.yml ]; then
      # One exception: gate.yml's tier job reads the PR's labels and files.
      assert_eq 1 "$(body "$WF/$f" | grep -cE '^[[:space:]]+permissions:')" "gate.yml job-level permissions blocks"
      block=$(body "$WF/$f" | awk '/^    permissions:/{f=1; next} f && !/^      /{exit} f{print}' | sed 's/^[[:space:]]*//')
      assert_eq "contents: read
pull-requests: read" "$block" "gate.yml tier job permissions"
    else
      ! body "$WF/$f" | grep -Eq '^[[:space:]]+permissions:' || { echo "$f has job-level permissions" >&2; return 1; }
    fi
    ! body "$WF/$f" | grep -q 'secrets\.' || { echo "$f uses secrets" >&2; return 1; }
    ! body "$WF/$f" | grep -Eq 'pull_request_target|workflow_run' || { echo "$f runs on pull_request_target or workflow_run" >&2; return 1; }
  done
}

t_engine() {
  local f="$WF/engine.yml"
  [ -f "$f" ] || { echo "missing engine.yml" >&2; return 1; }
  body "$f" | grep -qF -- "$SMOKE" || { echo "engine.yml lacks the smoke command" >&2; return 1; }
  body "$f" | grep -qF "$WASMTIME_SHA" || { echo "engine.yml lacks the wasmtime sha256" >&2; return 1; }
  # The smoke compares both outputs with 42, and the download is checked against
  # the pinned digest by a verify that cannot be swallowed.
  assert_eq 2 "$(body "$f" | grep -cF '[ "$out" = 42 ]')" "smoke comparisons with 42"
  assert_eq 2 "$(body "$f" | grep -cF 'echo "smoke ok: $out"')" "smoke prints its result"
  has_line "$f" "WASMTIME_SHA256: $WASMTIME_SHA" || { echo "engine.yml WASMTIME_SHA256 is not the pinned digest" >&2; return 1; }
  has_line "$f" 'echo "${WASMTIME_SHA256}  $RUNNER_TEMP/wasmtime.tar.xz" | sha256sum -c -' ||
    { echo "engine.yml does not verify wasmtime against WASMTIME_SHA256" >&2; return 1; }
  no_or_on "$f" 'sha256sum'
  body "$f" | grep -q 'scripts/build-engine.sh' || { echo "engine.yml does not run build-engine.sh" >&2; return 1; }
  body "$f" | grep -q 'build-manifest.json' || { echo "engine.yml does not upload build-manifest.json" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "engine.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -Eq '^  push:' || { echo "engine.yml lacks push" >&2; return 1; }
  body "$f" | grep -Eq '^      - main$' || { echo "engine.yml push is not limited to main" >&2; return 1; }
  body "$f" | grep -Eq 'timeout-minutes: 120' || { echo "engine.yml lacks timeout-minutes: 120" >&2; return 1; }
  body "$f" | grep -Eq 'uses: actions/cache/restore@[0-9a-f]{40}' || { echo "engine.yml lacks cache restore" >&2; return 1; }
  body "$f" | grep -Eq 'uses: actions/cache/save@[0-9a-f]{40}' || { echo "engine.yml lacks cache save" >&2; return 1; }
  # the save step runs after a failed build too, but not after a cancellation or
  # timeout (a partial ~/.mozbuild would be cached under the exact key), and only
  # on main pushes or dispatch
  body "$f" | awk '/actions\/cache\/save@/{f=1} f&&/if:/{print; exit}' | grep -q '!cancelled()' ||
    { echo "cache save lacks if: !cancelled()" >&2; return 1; }
  ! body "$f" | awk '/actions\/cache\/save@/{f=1} f&&/if:/{print; exit}' | grep -q 'always()' ||
    { echo "cache save still runs on cancellation (always())" >&2; return 1; }
  body "$f" | awk '/actions\/cache\/save@/{f=1} f&&/if:/{print; exit}' | grep -q "refs/heads/main" ||
    { echo "cache save is not limited to main" >&2; return 1; }
  body "$f" | grep -q 'workflow_dispatch' || { echo "engine.yml lacks workflow_dispatch" >&2; return 1; }
  body "$f" | grep -q 'Free disk space' || { echo "engine.yml lacks the free-disk step" >&2; return 1; }
  body "$f" | grep -q 'scripts/lib/patch-queue.sh' || { echo "cache key lacks patch-queue.sh" >&2; return 1; }
  body "$f" | grep -q 'curl --retry 3' || { echo "wasmtime download lacks --retry 3" >&2; return 1; }
  # wasmtime is installed (and verified) before the build: fail fast
  [ "$(body "$f" | grep -n 'sha256sum -c' | head -1 | cut -d: -f1)" -lt "$(body "$f" | grep -n 'run: scripts/build-engine.sh\|^          scripts/build-engine.sh' | head -1 | cut -d: -f1)" ] ||
    { echo "wasmtime is not verified before the build" >&2; return 1; }
}

t_queue() {
  local f="$WF/queue.yml"
  [ -f "$f" ] || { echo "missing queue.yml" >&2; return 1; }
  body "$f" | grep -Eq 'scripts/check-queue\.sh --fixtures' || { echo "queue.yml lacks fixtures run" >&2; return 1; }
  body "$f" | grep -Eq 'scripts/check-queue\.sh$' || { echo "queue.yml lacks the real check-queue run" >&2; return 1; }
  body "$f" | grep -q 'scripts/check-mozconfig-drift.sh' || { echo "queue.yml lacks the drift check" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "queue.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -q 'NIGHTMONKEY_PIN' || { echo "queue.yml does not use NIGHTMONKEY_PIN" >&2; return 1; }
  body "$f" | grep -q 'steps.pin.outputs.sha' || { echo "drift checkout does not use the pin" >&2; return 1; }
  # the pin is validated where it is read, before it reaches the checkout
  step "$f" "Read NIGHTMONKEY_PIN" | grep -q 'id: pin' || { echo "no 'Read NIGHTMONKEY_PIN' step with id pin" >&2; return 1; }
  check_pin_step "$f" "Read NIGHTMONKEY_PIN"
  body "$f" | grep -q 'rhysd/actionlint/releases/download' || { echo "queue.yml does not install actionlint" >&2; return 1; }
  body "$f" | grep -q 'sha256sum -c' || { echo "queue.yml does not verify actionlint" >&2; return 1; }
  has_line "$f" 'echo "${ACTIONLINT_SHA256}  $tgz" | sha256sum -c -' ||
    { echo "queue.yml does not verify actionlint against ACTIONLINT_SHA256" >&2; return 1; }
  body "$f" | grep -Eq '^ +ACTIONLINT_SHA256: [0-9a-f]{64}$' || { echo "queue.yml lacks a full actionlint digest" >&2; return 1; }
  no_or_on "$f" 'sha256sum'
}

# gate.yml: the semantic gate. The engine tree built from the queue is the
# test-source tree; it is never the bare tag or the YurtOS/firefox fork.
SUBSET_STEP='jit-tests (subset, both lanes)'
SHARD_STEP='jit-tests (shard ${{ matrix.shard }}, both lanes)'
TIER_STEP='Pick the tier'
BUILD_STEP='Build the engine from the queue'

t_gate() {
  local f="$WF/gate.yml"
  [ -f "$f" ] || { echo "missing gate.yml" >&2; return 1; }
  body "$f" | grep -Eq '^  workflow_dispatch:' || { echo "gate.yml lacks workflow_dispatch" >&2; return 1; }
  body "$f" | grep -Eq '^  schedule:' || { echo "gate.yml lacks schedule" >&2; return 1; }
  body "$f" | grep -Eq "cron: '17 3 \* \* \*'" || { echo "gate.yml lacks the 03:17 UTC nightly cron" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "gate.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -Eq 'types: \[opened, synchronize, reopened, labeled\]' || { echo "gate.yml pull_request lacks the label types" >&2; return 1; }
  # The tier comes from the tier job's API reads, never from the event's labels
  ! body "$f" | grep -q 'github.event.pull_request.labels' || { echo "gate.yml reads labels from the event" >&2; return 1; }
  has_line "$f" "if: needs.tier.outputs.mode != 'none'" || { echo "the build job is not gated on the tier" >&2; return 1; }
  has_line "$f" "if: needs.tier.outputs.mode == 'full'" || { echo "the shard jobs are not gated on the full tier" >&2; return 1; }
  body "$f" | grep -q 'steps.pin.outputs.sha' || { echo "gate.yml checkout does not use the pin" >&2; return 1; }
  body "$f" | grep -q 'repository: YurtOS/nightmonkey' || { echo "gate.yml does not check out YurtOS/nightmonkey" >&2; return 1; }
  has_line "$f" 'test ! -e nightmonkey/firefox' || { echo "gate.yml does not check the link target is free" >&2; return 1; }
  has_line "$f" 'ln -s "$GITHUB_WORKSPACE/firefox" nightmonkey/firefox' ||
    { echo "gate.yml does not link the engine tree at nightmonkey/firefox" >&2; return 1; }
  has_line "$f" 'cmake -S . -B build -DSPIDERMONKEY_DIST="$GITHUB_WORKSPACE/firefox/obj-nightmonkey-sm/dist"' ||
    { echo "gate.yml does not build NightMonkey against the queue dist" >&2; return 1; }
  body "$f" | grep -Eq 'timeout-minutes: 125' || { echo "gate.yml lacks the 125 minute jit-test timeout" >&2; return 1; }
  body "$f" | grep -q 'Free disk space' || { echo "gate.yml lacks the free-disk step" >&2; return 1; }
  # the test tree is never the fork or a bare tag checkout
  ! body "$f" | grep -Eiq 'YurtOS/firefox|mozilla-firefox|FIREFOX_RELEASE|git (clone|fetch).*(firefox|--branch)' ||
    { echo "gate.yml references the fork or a bare tag as the test tree" >&2; return 1; }
  # NightMonkey, once in the build job and once in the shard job
  [ "$(body "$f" | grep -c 'repository:')" = 2 ] || { echo "gate.yml checks out more than NightMonkey" >&2; return 1; }
  [ "$(body "$f" | grep -c 'repository: YurtOS/nightmonkey')" = 2 ] || { echo "gate.yml checks out something besides NightMonkey" >&2; return 1; }
  # nothing may let a failing step pass
  ! body "$f" | grep -q 'continue-on-error' || { echo "gate.yml uses continue-on-error" >&2; return 1; }
  no_or_on "$f" 'ci-suite.sh'
  no_or_on "$f" 'build-engine.sh'
  has_line "$f" 'run: scripts/build-engine.sh' || { echo "the engine step is not exactly build-engine.sh" >&2; return 1; }
  # ~/.mozbuild is restore-only (engine.yml seeds it from main); the ccache is
  # the one cache gate.yml saves, only on main; rust-cache saves only on main,
  # so gated PRs do not fill the repository's cache quota
  ! body "$f" | grep -Eq 'actions/cache@' || { echo "gate.yml uses actions/cache (restore and save)" >&2; return 1; }
  assert_eq 1 "$(body "$f" | grep -cE 'actions/cache/save@')" "gate.yml cache saves"
  step "$f" "Save the SpiderMonkey ccache" | grep -qxF '          path: ~/.ccache' || { echo "gate.yml saves something besides the ccache" >&2; return 1; }
  has_line "$f" "if: \${{ !cancelled() && github.ref == 'refs/heads/main' }}" || { echo "the ccache save is not main-only" >&2; return 1; }
  has_line "$f" "save-if: \${{ github.ref == 'refs/heads/main' }}" || { echo "rust-cache saves on PRs" >&2; return 1; }
  # the gate uses wasmtime only as NightMonkey's crate; no CLI download
  ! body "$f" | grep -q 'bytecodealliance/wasmtime/releases' || { echo "gate.yml downloads an unused wasmtime CLI" >&2; return 1; }
  # logs survive a failing lane
  step "$f" "Upload execution logs" | grep -qE '^[[:space:]]+if: always\(\)$' || { echo "log upload is not if: always()" >&2; return 1; }
  has_line "$f" 'path: ${{ runner.temp }}/nightmonkey-logs' || { echo "log upload path is not the logs dir" >&2; return 1; }
}

# The subset and each shard reach the harness as `ci-suite.sh jit both -- ...`
# from nightmonkey/, the engine step runs build-engine.sh, and a failing
# harness or build fails the step.
t_gate_lanes() {
  local f="$WF/gate.yml" d shard rc s
  has_line "$f" 'shard: [1, 2, 3, 4]' || { echo "gate.yml shards are not [1, 2, 3, 4]" >&2; return 1; }
  has_line "$f" 'SHARDS: 4' || { echo "SHARDS is not 4 (the matrix)" >&2; return 1; }
  ! body "$f" | grep -Eq '^[[:space:]]+(exclude|include):' || { echo "gate.yml matrix has exclude/include" >&2; return 1; }
  for s in "$SUBSET_STEP" "$SHARD_STEP"; do
    step "$f" "$s" | grep -qE '^[[:space:]]+working-directory: nightmonkey$' ||
      { echo "step '$s' does not run in nightmonkey/" >&2; return 1; }
  done
  d=$(mktemp -d)
  mkdir -p "$d/nightmonkey/scripts" "$d/scripts" "$d/tmp"
  printf '#!/bin/sh\necho "$*" >>"$CALLS"\nexit "${STUB_RC:-0}"\n' >"$d/nightmonkey/scripts/ci-suite.sh"
  cp "$d/nightmonkey/scripts/ci-suite.sh" "$d/scripts/build-engine.sh"
  chmod +x "$d/nightmonkey/scripts/ci-suite.sh" "$d/scripts/build-engine.sh"
  : >"$d/calls"
  exec_step "$f" "$SUBSET_STEP" "$d/nightmonkey" JIT_SUBSET="warp/ baseline/" CALLS="$d/calls" >/dev/null 2>&1 ||
    { echo "subset step failed" >&2; rm -rf "$d"; return 1; }
  assert_eq "jit both -- warp/ baseline/" "$(cat "$d/calls")" "subset harness call"
  rc=0
  exec_step "$f" "$SUBSET_STEP" "$d/nightmonkey" JIT_SUBSET="warp/" CALLS="$d/calls" STUB_RC=3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failing harness passes the subset" >&2; rm -rf "$d"; return 1; }
  for shard in 1 2 3 4; do
    : >"$d/calls"
    exec_step "$f" "$SHARD_STEP" "$d/nightmonkey" SHARD="$shard" SHARDS=4 RUNNER_TEMP="$d/tmp" CALLS="$d/calls" >/dev/null 2>&1 ||
      { echo "shard step failed for shard $shard" >&2; rm -rf "$d"; return 1; }
    assert_eq "jit both -- --total-chunks=4 --this-chunk=$shard" "$(cat "$d/calls")" "harness call for shard $shard"
    rc=0
    exec_step "$f" "$SHARD_STEP" "$d/nightmonkey" SHARD="$shard" SHARDS=4 RUNNER_TEMP="$d/tmp" CALLS="$d/calls" STUB_RC=3 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "a failing harness passes shard $shard" >&2; rm -rf "$d"; return 1; }
  done
  rc=0
  exec_step "$f" "$SHARD_STEP" "$d/nightmonkey" SHARD=5 SHARDS=4 RUNNER_TEMP="$d/tmp" CALLS="$d/calls" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "a shard outside 1..SHARDS passes" >&2; rm -rf "$d"; return 1; }
  : >"$d/calls"
  exec_step "$f" "$BUILD_STEP" "$d" CALLS="$d/calls" >/dev/null 2>&1 || { echo "engine step failed" >&2; rm -rf "$d"; return 1; }
  assert_eq "" "$(cat "$d/calls")" "build-engine.sh called once with no arguments"
  [ "$(wc -l <"$d/calls" | tr -d ' ')" = 1 ] || { echo "build-engine.sh not called exactly once" >&2; rm -rf "$d"; return 1; }
  rc=0
  exec_step "$f" "$BUILD_STEP" "$d" CALLS="$d/calls" STUB_RC=3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failing engine build passes" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# The tier step, executed with a stub gh: a `ci:full` or `gate` label runs
# everything; otherwise a changed engine input runs the subset and anything
# else nothing; non-PR events run everything; an API error fails the step.
t_gate_tier() {
  local f="$WF/gate.yml" d inputs c ev labels files want rc
  inputs=$(body "$f" | sed -n "s/^  ENGINE_INPUTS: '\(.*\)'$/\1/p")
  [ -n "$inputs" ] || { echo "gate.yml lacks ENGINE_INPUTS" >&2; return 1; }
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '%s\n' '#!/bin/sh' '[ -z "${GH_FAIL:-}" ] || exit 1' 'case "$*" in' \
    '  *"/labels"*) printf "%b" "$LABELS" ;;' '  *"/files"*) printf "%b" "$FILES" ;;' \
    '  *) exit 1 ;;' 'esac' >"$d/bin/gh"
  chmod +x "$d/bin/gh"
  for c in \
    'pull_request|ci:full\n|docs/x.md\n|full' \
    'pull_request|gate\n|README.md\n|full' \
    'pull_request|ready\n|patches/0001-x.patch\n|subset' \
    'pull_request||NIGHTMONKEY_PIN\n|subset' \
    'pull_request||README.md\nmozconfig\n|subset' \
    'pull_request||scripts/lib/patch-queue.sh\n|subset' \
    'pull_request||.github/workflows/gate.yml\n|subset' \
    'pull_request|ci:fuller\n|scripts/check-queue.sh\ndocs/mozconfig.md\n|none' \
    'schedule|||full' \
    'workflow_dispatch|||full'; do
    IFS='|' read -r ev labels files want <<<"$c"
    : >"$d/out"
    exec_step "$f" "$TIER_STEP" "$d" PATH="$d/bin:$PATH" GITHUB_EVENT_NAME="$ev" GITHUB_REPOSITORY=o/r PR=7 \
      LABELS="$labels" FILES="$files" ENGINE_INPUTS="$inputs" SHARDS=4 JIT_SUBSET=warp/ \
      GITHUB_OUTPUT="$d/out" GITHUB_STEP_SUMMARY="$d/summary" >/dev/null 2>&1 ||
      { echo "tier step failed for $c" >&2; rm -rf "$d"; return 1; }
    assert_eq "mode=$want" "$(cat "$d/out")" "tier for $c"
  done
  : >"$d/out"
  rc=0
  exec_step "$f" "$TIER_STEP" "$d" PATH="$d/bin:$PATH" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r PR=7 GH_FAIL=1 \
    ENGINE_INPUTS="$inputs" GITHUB_OUTPUT="$d/out" GITHUB_STEP_SUMMARY="$d/summary" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "an API error picks a tier" >&2; rm -rf "$d"; return 1; }
  assert_eq "" "$(cat "$d/out")" "no tier on an API error"
  rm -rf "$d"
}

# concurrency_value <file> <key>: the value of <key> in the top-level
# `concurrency:` block.
concurrency_value() {
  body "$1" | awk -v k="$2" '/^concurrency:/{f=1; next} f && /^[^[:space:]]/{exit}
    f { t=$0; sub(/^[[:space:]]+/, "", t); if (index(t, k ": ") == 1) { print substr(t, length(k) + 3); exit } }'
}

# gh_eval <template> <context-json>: evaluate a workflow value containing
# ${{ }} expressions the way Actions does for the subset used here: github.*
# property paths (missing -> null), string/number/boolean/null literals, ==, !=,
# !, &&, || (returning an operand, not a boolean), parentheses; string == is
# case-insensitive; null, false, 0 and '' are falsy; null interpolates as ''.
gh_eval() {
  python3 -I - "$1" "$2" <<'PY'
import json, re, sys

template, ctx = sys.argv[1], {"github": json.loads(sys.argv[2])}
TOK = re.compile(r"\s*(?:(?P<s>'(?:[^']|'')*')|(?P<n>-?\d+(?:\.\d+)?)|(?P<op>==|!=|&&|\|\||!|\(|\))|(?P<id>[A-Za-z_][A-Za-z0-9_.-]*))")

def tokens(src):
    out, i = [], 0
    while i < len(src):
        if src[i:].strip() == "":
            break
        m = TOK.match(src, i)
        if not m:
            sys.exit("gh_eval: cannot parse at: " + src[i:])
        i = m.end()
        out.append((m.lastgroup, m.group(m.lastgroup)))
    return out

def truthy(v):
    return v not in (None, False, 0, "") and v == v

def eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return a == b

class P:
    def __init__(self, t):
        self.t, self.i = t, 0
    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)
    def take(self):
        tok = self.peek()
        self.i += 1
        return tok
    def expr(self):
        v = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            r = self.and_()
            v = v if truthy(v) else r
        return v
    def and_(self):
        v = self.cmp()
        while self.peek() == ("op", "&&"):
            self.take()
            r = self.cmp()
            v = r if truthy(v) else v
        return v
    def cmp(self):
        v = self.unary()
        while self.peek() in (("op", "=="), ("op", "!=")):
            op = self.take()[1]
            r = self.unary()
            v = eq(v, r) if op == "==" else not eq(v, r)
        return v
    def unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.unary())
        kind, val = self.take()
        if kind == "op" and val == "(":
            v = self.expr()
            if self.take() != ("op", ")"):
                sys.exit("gh_eval: missing )")
            return v
        if kind == "s":
            return val[1:-1].replace("''", "'")
        if kind == "n":
            return float(val) if "." in val else int(val)
        if kind == "id":
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            cur = ctx
            for part in val.split("."):
                cur = cur.get(part) if isinstance(cur, dict) else None
            return cur
        sys.exit("gh_eval: unexpected token %r" % (val,))

def ev(src):
    p = P(tokens(src))
    v = p.expr()
    if p.peek() != (None, None):
        sys.exit("gh_eval: trailing tokens in: " + src)
    return v

def show(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)

print(re.sub(r"\$\{\{(.*?)\}\}", lambda m: show(ev(m.group(1))), template))
PY
}

# The gate's concurrency group: a push or any label on a PR replaces the run
# in flight (the tier job then reads the labels afresh). Nightly and dispatch
# runs on main share one group and are never cancelled.
t_gate_concurrency() {
  local f="$WF/gate.yml" group cancel a b c d e
  group=$(concurrency_value "$f" group)
  cancel=$(concurrency_value "$f" cancel-in-progress)
  [ -n "$group" ] && [ -n "$cancel" ] || { echo "gate.yml lacks concurrency group / cancel-in-progress" >&2; return 1; }
  a=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":101,"event":{"action":"synchronize"}}')
  b=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":102,"event":{"action":"labeled","label":{"name":"ci:full"}}}')
  c=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":103,"event":{"action":"labeled","label":{"name":"ready"}}}')
  d=$(gh_eval "$group" '{"event_name":"schedule","ref":"refs/heads/main","run_id":105,"event":{}}')
  e=$(gh_eval "$group" '{"event_name":"workflow_dispatch","ref":"refs/heads/main","run_id":106,"event":{}}')
  [ -n "$a" ] && [ -n "$c" ] && [ -n "$d" ] || { echo "group did not evaluate" >&2; return 1; }
  assert_eq "$a" "$b" "synchronize and a ci:full label share the PR's group"
  assert_eq "$a" "$c" "any label run replaces the PR's run"
  assert_eq "$d" "$e" "nightly and dispatch on main share a group"
  [ "$d" != "$a" ] || { echo "main runs share the PR's group" >&2; return 1; }
  assert_eq true "$(gh_eval "$cancel" '{"event_name":"pull_request"}')" "PR runs cancel in progress"
  assert_eq false "$(gh_eval "$cancel" '{"event_name":"schedule"}')" "nightly runs are not cancelled"
  assert_eq false "$(gh_eval "$cancel" '{"event_name":"workflow_dispatch"}')" "dispatch runs are not cancelled"
}

# The pin is validated where it is read: executed with good and bad pins.
t_gate_pin() {
  check_pin_step "$WF/gate.yml" "Read the pins"
  check_pin_step "$WF/gate.yml" "Read the shard pin"
}

# The logs artifact carries provenance: the logs dir is created (with the pin)
# before anything can fail, and the engine's build-manifest.json is copied in
# and shown in the step summary after the build.
t_gate_provenance() {
  local f="$WF/gate.yml" d pin=0123456789abcdef0123456789abcdef01234567 prep build rec
  prep=$(body "$f" | grep -n -- '- name: Prepare logs$' | head -1 | cut -d: -f1 || true)
  build=$(body "$f" | grep -nF -- "- name: $BUILD_STEP" | cut -d: -f1 || true)
  rec=$(body "$f" | grep -n -- '- name: Record provenance$' | cut -d: -f1 || true)
  [ -n "$prep" ] && [ -n "$build" ] && [ -n "$rec" ] || { echo "missing Prepare logs / build / Record provenance steps" >&2; return 1; }
  [ "$prep" -lt "$build" ] && [ "$build" -lt "$rec" ] || { echo "provenance steps are out of order" >&2; return 1; }
  d=$(mktemp -d)
  mkdir -p "$d/ws" "$d/tmp"
  printf '%s\n' "$pin" >"$d/ws/NIGHTMONKEY_PIN"
  : >"$d/summary"
  exec_step "$f" "Prepare logs" "$d/ws" RUNNER_TEMP="$d/tmp" GITHUB_WORKSPACE="$d/ws" GITHUB_STEP_SUMMARY="$d/summary" >/dev/null 2>&1 ||
    { echo "Prepare logs failed" >&2; rm -rf "$d"; return 1; }
  cmp -s "$d/ws/NIGHTMONKEY_PIN" "$d/tmp/nightmonkey-logs/NIGHTMONKEY_PIN" || { echo "pin not in the logs dir" >&2; rm -rf "$d"; return 1; }
  grep -qF "$pin" "$d/summary" || { echo "pin not in the step summary" >&2; rm -rf "$d"; return 1; }
  printf '{\n  "tree": "feedface"\n}\n' >"$d/ws/build-manifest.json"
  exec_step "$f" "Record provenance" "$d/ws" RUNNER_TEMP="$d/tmp" GITHUB_WORKSPACE="$d/ws" GITHUB_STEP_SUMMARY="$d/summary" >/dev/null 2>&1 ||
    { echo "Record provenance failed" >&2; rm -rf "$d"; return 1; }
  cmp -s "$d/ws/build-manifest.json" "$d/tmp/nightmonkey-logs/build-manifest.json" || { echo "manifest not in the logs dir" >&2; rm -rf "$d"; return 1; }
  grep -qF feedface "$d/summary" || { echo "manifest not in the step summary" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

run_test "workflows exist" t_exist
run_test "workflows pass actionlint" t_actionlint
run_test "every uses: is pinned by 40-hex SHA" t_pinned
run_test "read-only permissions, no secrets" t_permissions
run_test "checkouts do not persist credentials" t_credentials
run_test "engine.yml: smoke, wasmtime digest, triggers" t_engine
run_test "queue.yml: fixtures, real check, drift" t_queue
run_test "gate.yml: triggers, tiers, linked test tree, caches" t_gate
run_test "gate.yml: the subset and each shard reach the harness and failures fail" t_gate_lanes
run_test "gate.yml: the tier comes from the labels and the changed files" t_gate_tier
run_test "gate.yml: the pin step rejects bad pins" t_gate_pin
run_test "gate.yml: PR runs replace each other, main runs queue" t_gate_concurrency
run_test "gate.yml: logs carry the pin and the build manifest" t_gate_provenance
finish
