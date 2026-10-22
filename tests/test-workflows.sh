#!/usr/bin/env bash
# Tests for .github/workflows/{queue,engine}.yml: structure, actionlint, action
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
  actionlint "$WF/queue.yml" "$WF/engine.yml"
}

t_pinned() {
  local f bad
  for f in queue.yml engine.yml; do
    [ -f "$WF/$f" ] || { echo "missing $f" >&2; return 1; }
    bad=$(body "$WF/$f" | grep -E '^[[:space:]-]*uses:' | grep -Ev 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]+#.*)?$' || true)
    [ -z "$bad" ] || { printf '%s: unpinned uses:\n%s\n' "$f" "$bad" >&2; return 1; }
    body "$WF/$f" | grep -Eq '^[[:space:]-]*uses:' || { echo "$f has no uses:" >&2; return 1; }
  done
}

t_permissions() {
  local f
  for f in queue.yml engine.yml; do
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

run_test "workflows exist" t_exist
run_test "workflows pass actionlint" t_actionlint
run_test "every uses: is pinned by 40-hex SHA" t_pinned
run_test "read-only permissions, no secrets" t_permissions
run_test "engine.yml: smoke, wasmtime digest, triggers" t_engine
run_test "queue.yml: fixtures, real check, drift" t_queue
finish
