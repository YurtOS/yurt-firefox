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

t_exist() {
  [ -f "$WF/queue.yml" ] || { echo "missing queue.yml" >&2; return 1; }
  [ -f "$WF/engine.yml" ] || { echo "missing engine.yml" >&2; return 1; }
}

t_actionlint() {
  if ! command -v actionlint >/dev/null 2>&1; then
    echo "SKIP: actionlint not installed" >&2
    return 0
  fi
  actionlint "$WF/queue.yml" "$WF/engine.yml"
}

t_pinned() {
  local f bad
  for f in queue.yml engine.yml; do
    [ -f "$WF/$f" ] || { echo "missing $f" >&2; return 1; }
    bad=$(grep -E '^[[:space:]-]*uses:' "$WF/$f" | grep -Ev 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]+#.*)?$' || true)
    [ -z "$bad" ] || { printf '%s: unpinned uses:\n%s\n' "$f" "$bad" >&2; return 1; }
    grep -Eq '^[[:space:]-]*uses:' "$WF/$f" || { echo "$f has no uses:" >&2; return 1; }
  done
}

t_permissions() {
  local f
  for f in queue.yml engine.yml; do
    grep -Eq '^permissions:' "$WF/$f" && grep -Eq '^  contents: read$' "$WF/$f" ||
      { echo "$f lacks top-level permissions: contents: read" >&2; return 1; }
    ! grep -q 'secrets\.' "$WF/$f" || { echo "$f uses secrets" >&2; return 1; }
  done
}

t_engine() {
  local f="$WF/engine.yml"
  [ -f "$f" ] || { echo "missing engine.yml" >&2; return 1; }
  grep -qF -- "$SMOKE" "$f" || { echo "engine.yml lacks the smoke command" >&2; return 1; }
  grep -qF "$WASMTIME_SHA" "$f" || { echo "engine.yml lacks the wasmtime sha256" >&2; return 1; }
  grep -q 'scripts/build-engine.sh' "$f" || { echo "engine.yml does not run build-engine.sh" >&2; return 1; }
  grep -q 'build-manifest.json' "$f" || { echo "engine.yml does not upload build-manifest.json" >&2; return 1; }
  grep -Eq '^  pull_request:' "$f" || { echo "engine.yml lacks pull_request" >&2; return 1; }
  grep -Eq '^  push:' "$f" || { echo "engine.yml lacks push" >&2; return 1; }
  grep -Eq '^      - main$' "$f" || { echo "engine.yml push is not limited to main" >&2; return 1; }
  grep -Eq 'timeout-minutes: 120' "$f" || { echo "engine.yml lacks timeout-minutes: 120" >&2; return 1; }
}

t_queue() {
  local f="$WF/queue.yml"
  [ -f "$f" ] || { echo "missing queue.yml" >&2; return 1; }
  grep -Eq 'scripts/check-queue\.sh --fixtures' "$f" || { echo "queue.yml lacks fixtures run" >&2; return 1; }
  grep -Eq 'scripts/check-queue\.sh$' "$f" || { echo "queue.yml lacks the real check-queue run" >&2; return 1; }
  grep -q 'scripts/check-mozconfig-drift.sh' "$f" || { echo "queue.yml lacks the drift check" >&2; return 1; }
  grep -Eq '^  pull_request:' "$f" || { echo "queue.yml lacks pull_request" >&2; return 1; }
}

run_test "workflows exist" t_exist
run_test "workflows pass actionlint" t_actionlint
run_test "every uses: is pinned by 40-hex SHA" t_pinned
run_test "read-only permissions, no secrets" t_permissions
run_test "engine.yml: smoke, wasmtime digest, triggers" t_engine
run_test "queue.yml: fixtures, real check, drift" t_queue
finish
