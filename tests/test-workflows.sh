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

t_permissions() {
  local f
  for f in queue.yml engine.yml gate.yml; do
    { body "$WF/$f" | grep -Eq '^permissions:' && body "$WF/$f" | grep -Eq '^  contents: read$'; } ||
      { echo "$f lacks top-level permissions: contents: read" >&2; return 1; }
    ! body "$WF/$f" | grep -q 'secrets\.' || { echo "$f uses secrets" >&2; return 1; }
  done
}

t_engine() {
  local f="$WF/engine.yml"
  [ -f "$f" ] || { echo "missing engine.yml" >&2; return 1; }
  body "$f" | grep -qF -- "$SMOKE" || { echo "engine.yml lacks the smoke command" >&2; return 1; }
  body "$f" | grep -qF "$WASMTIME_SHA" || { echo "engine.yml lacks the wasmtime sha256" >&2; return 1; }
  body "$f" | grep -q 'scripts/build-engine.sh' || { echo "engine.yml does not run build-engine.sh" >&2; return 1; }
  body "$f" | grep -q 'build-manifest.json' || { echo "engine.yml does not upload build-manifest.json" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "engine.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -Eq '^  push:' || { echo "engine.yml lacks push" >&2; return 1; }
  body "$f" | grep -Eq '^      - main$' || { echo "engine.yml push is not limited to main" >&2; return 1; }
  body "$f" | grep -Eq 'timeout-minutes: 120' || { echo "engine.yml lacks timeout-minutes: 120" >&2; return 1; }
  body "$f" | grep -Eq 'uses: actions/cache/restore@[0-9a-f]{40}' || { echo "engine.yml lacks cache restore" >&2; return 1; }
  body "$f" | grep -Eq 'uses: actions/cache/save@[0-9a-f]{40}' || { echo "engine.yml lacks cache save" >&2; return 1; }
  # the save step must carry `if: always()` and run only on main pushes or dispatch
  body "$f" | awk '/actions\/cache\/save@/{f=1} f&&/if:/{print; exit}' | grep -q 'always()' ||
    { echo "cache save lacks if: always()" >&2; return 1; }
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
  body "$f" | grep -q 'rhysd/actionlint/releases/download' || { echo "queue.yml does not install actionlint" >&2; return 1; }
  body "$f" | grep -q 'sha256sum -c' || { echo "queue.yml does not verify actionlint" >&2; return 1; }
}

# gate.yml: the semantic gate. The engine tree built from the queue is the
# test-source tree; it is never the bare tag or the YurtOS/firefox fork.
t_gate() {
  local f="$WF/gate.yml"
  [ -f "$f" ] || { echo "missing gate.yml" >&2; return 1; }
  body "$f" | grep -Eq '^  workflow_dispatch:' || { echo "gate.yml lacks workflow_dispatch" >&2; return 1; }
  body "$f" | grep -Eq '^  schedule:' || { echo "gate.yml lacks schedule" >&2; return 1; }
  body "$f" | grep -Eq "cron: '17 3 \* \* \*'" || { echo "gate.yml lacks the 03:17 UTC nightly cron" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "gate.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -Eq 'types: \[labeled, synchronize, reopened\]' || { echo "gate.yml pull_request lacks the label types" >&2; return 1; }
  body "$f" | grep -Eq "^    if: .*github\.event_name != 'pull_request'.*contains\(github\.event\.pull_request\.labels\.\*\.name, 'gate'\)" ||
    { echo "gate.yml job lacks the gate label condition" >&2; return 1; }
  body "$f" | grep -q 'NIGHTMONKEY_PIN' || { echo "gate.yml does not read NIGHTMONKEY_PIN" >&2; return 1; }
  body "$f" | grep -q 'steps.pin.outputs.sha' || { echo "gate.yml checkout does not use the pin" >&2; return 1; }
  body "$f" | grep -q 'repository: YurtOS/nightmonkey' || { echo "gate.yml does not check out YurtOS/nightmonkey" >&2; return 1; }
  body "$f" | grep -q 'scripts/build-engine.sh' || { echo "gate.yml does not run build-engine.sh" >&2; return 1; }
  body "$f" | grep -Eq 'ln -s.*GITHUB_WORKSPACE.*/firefox.*nightmonkey/firefox' ||
    { echo "gate.yml does not link the engine tree at nightmonkey/firefox" >&2; return 1; }
  body "$f" | grep -q 'SPIDERMONKEY_DIST=.*firefox/obj-nightmonkey-sm/dist' || { echo "gate.yml does not build against the queue dist" >&2; return 1; }
  body "$f" | grep -q 'scripts/ci-suite.sh jit' || { echo "gate.yml does not run the jit-test lanes" >&2; return 1; }
  body "$f" | grep -Eq 'lane: \[aot, interpreter\]' || { echo "gate.yml lacks the aot/interpreter lanes" >&2; return 1; }
  body "$f" | grep -Eq 'timeout-minutes: 125' || { echo "gate.yml lacks the 125 minute jit-test timeout" >&2; return 1; }
  body "$f" | grep -q 'upload-artifact' || { echo "gate.yml does not upload logs" >&2; return 1; }
  body "$f" | grep -q 'Free disk space' || { echo "gate.yml lacks the free-disk step" >&2; return 1; }
  # the test tree is never the fork or a bare tag checkout
  ! body "$f" | grep -Eiq 'YurtOS/firefox|mozilla-firefox|FIREFOX_RELEASE|git (clone|fetch).*(firefox|--branch)' ||
    { echo "gate.yml references the fork or a bare tag as the test tree" >&2; return 1; }
  [ "$(body "$f" | grep -c 'repository:')" = 1 ] || { echo "gate.yml checks out more than NightMonkey" >&2; return 1; }
}

run_test "workflows exist" t_exist
run_test "workflows pass actionlint" t_actionlint
run_test "every uses: is pinned by 40-hex SHA" t_pinned
run_test "read-only permissions, no secrets" t_permissions
run_test "engine.yml: smoke, wasmtime digest, triggers" t_engine
run_test "queue.yml: fixtures, real check, drift" t_queue
run_test "gate.yml: triggers, pin, linked test tree, lanes" t_gate
finish
