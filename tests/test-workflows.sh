#!/usr/bin/env bash
# Tests for .github/workflows/{queue,engine,gate}.yml: structure, actionlint, action
# pinning, the smoke command and the pinned wasmtime digest.
# No pipefail: nearly every check here is `producer | grep -q ...`, and grep -q
# exits at its first match, so a producer that flushes per line (BSD grep on
# macOS does) dies of SIGPIPE and pipefail would fail a passing check. Every
# pipeline ends in a content check, so the last command's status is the one
# that matters. (exec_step still runs step scripts with -eo pipefail.)
set -eu

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
    ! body "$WF/$f" | grep -Eq '^[[:space:]]+permissions:' || { echo "$f has job-level permissions" >&2; return 1; }
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
GATE_IF="if: github.event_name != 'pull_request' || (contains(github.event.pull_request.labels.*.name, 'gate') && (github.event.action != 'labeled' || github.event.label.name == 'gate'))"
JIT_STEP='jit-tests (${{ matrix.lane }})'
BUILD_STEP='Build the engine from the queue'

t_gate() {
  local f="$WF/gate.yml"
  [ -f "$f" ] || { echo "missing gate.yml" >&2; return 1; }
  body "$f" | grep -Eq '^  workflow_dispatch:' || { echo "gate.yml lacks workflow_dispatch" >&2; return 1; }
  body "$f" | grep -Eq '^  schedule:' || { echo "gate.yml lacks schedule" >&2; return 1; }
  body "$f" | grep -Eq "cron: '17 3 \* \* \*'" || { echo "gate.yml lacks the 03:17 UTC nightly cron" >&2; return 1; }
  body "$f" | grep -Eq '^  pull_request:' || { echo "gate.yml lacks pull_request" >&2; return 1; }
  body "$f" | grep -Eq 'types: \[labeled, synchronize, reopened\]' || { echo "gate.yml pull_request lacks the label types" >&2; return 1; }
  # PRs run the gate only when labeled `gate`, and adding another label to such
  # a PR does not restart (and, by cancel-in-progress, cancel) a running gate
  has_line "$f" "$GATE_IF" || { echo "gate.yml job if: is not the gate-label condition" >&2; return 1; }
  [ "$(body "$f" | grep -cE '^[[:space:]]+if:')" -ge 1 ]
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
  [ "$(body "$f" | grep -c 'repository:')" = 1 ] || { echo "gate.yml checks out more than NightMonkey" >&2; return 1; }
  # nothing may let a failing step pass
  ! body "$f" | grep -q 'continue-on-error' || { echo "gate.yml uses continue-on-error" >&2; return 1; }
  no_or_on "$f" 'ci-suite.sh'
  no_or_on "$f" 'build-engine.sh'
  has_line "$f" 'run: scripts/ci-suite.sh jit "$CI_LANE"' || { echo "the jit step is not exactly ci-suite.sh jit \"\$CI_LANE\"" >&2; return 1; }
  has_line "$f" 'run: scripts/build-engine.sh' || { echo "the engine step is not exactly build-engine.sh" >&2; return 1; }
  # ~/.mozbuild is restore-only (engine.yml seeds it from main); rust-cache saves
  # only on main, so gated PRs do not fill the repository's cache quota
  ! body "$f" | grep -Eq 'actions/cache(/save)?@' || { echo "gate.yml saves ~/.mozbuild" >&2; return 1; }
  has_line "$f" "save-if: \${{ github.ref == 'refs/heads/main' }}" || { echo "rust-cache saves on PRs" >&2; return 1; }
  # the gate uses wasmtime only as NightMonkey's crate; no CLI download
  ! body "$f" | grep -q 'bytecodealliance/wasmtime/releases' || { echo "gate.yml downloads an unused wasmtime CLI" >&2; return 1; }
  # logs survive a failing lane
  step "$f" "Upload execution logs" | grep -qE '^[[:space:]]+if: always\(\)$' || { echo "log upload is not if: always()" >&2; return 1; }
  has_line "$f" 'path: ${{ runner.temp }}/nightmonkey-logs' || { echo "log upload path is not the logs dir" >&2; return 1; }
}

# Each matrix lane reaches the harness as `ci-suite.sh jit <lane>`, the engine
# step runs build-engine.sh, and a failing harness or build fails the step.
t_gate_lanes() {
  local f="$WF/gate.yml" d lanes lane rc
  has_line "$f" 'lane: [aot, interpreter]' || { echo "gate.yml lanes are not [aot, interpreter]" >&2; return 1; }
  ! body "$f" | grep -Eq '^[[:space:]]+(exclude|include):' || { echo "gate.yml matrix has exclude/include" >&2; return 1; }
  has_line "$f" 'CI_LANE: ${{ matrix.lane }}' || { echo "CI_LANE is not the matrix lane" >&2; return 1; }
  step "$f" "$JIT_STEP" | grep -qE '^[[:space:]]+working-directory: nightmonkey$' ||
    { echo "the jit step does not run in nightmonkey/" >&2; return 1; }
  lanes=$(body "$f" | sed -n 's/^[[:space:]]*lane: \[\(.*\)\][[:space:]]*$/\1/p' | tr -d ' ' | tr ',' ' ')
  assert_eq "aot interpreter" "$lanes" "matrix lanes"
  d=$(mktemp -d)
  mkdir -p "$d/nightmonkey/scripts" "$d/scripts"
  printf '#!/bin/sh\necho "$*" >>"$CALLS"\nexit "${STUB_RC:-0}"\n' >"$d/nightmonkey/scripts/ci-suite.sh"
  cp "$d/nightmonkey/scripts/ci-suite.sh" "$d/scripts/build-engine.sh"
  chmod +x "$d/nightmonkey/scripts/ci-suite.sh" "$d/scripts/build-engine.sh"
  for lane in $lanes; do
    : >"$d/calls"
    exec_step "$f" "$JIT_STEP" "$d/nightmonkey" CI_LANE="$lane" CALLS="$d/calls" >/dev/null 2>&1 ||
      { echo "jit step failed for lane $lane" >&2; rm -rf "$d"; return 1; }
    assert_eq "jit $lane" "$(cat "$d/calls")" "harness call for lane $lane"
    rc=0
    exec_step "$f" "$JIT_STEP" "$d/nightmonkey" CI_LANE="$lane" CALLS="$d/calls" STUB_RC=3 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "a failing harness passes lane $lane" >&2; rm -rf "$d"; return 1; }
  done
  : >"$d/calls"
  exec_step "$f" "$BUILD_STEP" "$d" CALLS="$d/calls" >/dev/null 2>&1 || { echo "engine step failed" >&2; rm -rf "$d"; return 1; }
  assert_eq "" "$(cat "$d/calls")" "build-engine.sh called once with no arguments"
  [ "$(wc -l <"$d/calls" | tr -d ' ')" = 1 ] || { echo "build-engine.sh not called exactly once" >&2; rm -rf "$d"; return 1; }
  rc=0
  exec_step "$f" "$BUILD_STEP" "$d" CALLS="$d/calls" STUB_RC=3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failing engine build passes" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# concurrency_value <file> <key>: the value of <key> in the top-level
# `concurrency:` block.
concurrency_value() {
  body "$1" | awk -v k="$2" '/^concurrency:/{f=1; next} f && /^[^[:space:]]/{exit}
    f { t=$0; sub(/^[[:space:]]+/, "", t); if (index(t, k ": ") == 1) { print substr(t, length(k) + 3); exit } }'
}

# gh_eval <template> <github-json> [<inputs-json>]: evaluate a workflow value
# containing ${{ }} expressions the way Actions does for the subset used here:
# github.* and inputs.* property paths (missing -> null; no inputs-json is the
# empty inputs context of a pull_request or push run), string/number/boolean/null literals, ==, !=,
# !, &&, || (returning an operand, not a boolean), parentheses; string == is
# case-insensitive; null, false, 0 and '' are falsy; null interpolates as ''.
gh_eval() {
  local no_inputs='{}'
  python3 -I - "$1" "$2" "${3:-$no_inputs}" <<'PY'
import json, re, sys

template = sys.argv[1]
ctx = {"github": json.loads(sys.argv[2]), "inputs": json.loads(sys.argv[3])}
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

# The gate's concurrency group: a push or a `gate` label on a PR replaces the
# run in flight; adding any other label (whose run the job if: skips) must not
# join that group, or it would cancel the gate. Nightly and dispatch runs on
# main share one group and are never cancelled.
t_gate_concurrency() {
  local f="$WF/gate.yml" group cancel a b c c2 d e
  group=$(concurrency_value "$f" group)
  cancel=$(concurrency_value "$f" cancel-in-progress)
  [ -n "$group" ] && [ -n "$cancel" ] || { echo "gate.yml lacks concurrency group / cancel-in-progress" >&2; return 1; }
  a=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":101,"event":{"action":"synchronize"}}')
  b=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":102,"event":{"action":"labeled","label":{"name":"gate"}}}')
  c=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":103,"event":{"action":"labeled","label":{"name":"ready"}}}')
  c2=$(gh_eval "$group" '{"event_name":"pull_request","ref":"refs/pull/7/merge","run_id":104,"event":{"action":"labeled","label":{"name":"docs"}}}')
  d=$(gh_eval "$group" '{"event_name":"schedule","ref":"refs/heads/main","run_id":105,"event":{}}')
  e=$(gh_eval "$group" '{"event_name":"workflow_dispatch","ref":"refs/heads/main","run_id":106,"event":{}}')
  [ -n "$a" ] && [ -n "$c" ] && [ -n "$d" ] || { echo "group did not evaluate" >&2; return 1; }
  assert_eq "$a" "$b" "synchronize and a gate label share the PR's group"
  [ "$c" != "$a" ] || { echo "an unrelated label joins the gate's group ($c) and would cancel it" >&2; return 1; }
  [ "$c" != "$c2" ] || { echo "unrelated-label runs share a group ($c)" >&2; return 1; }
  assert_eq "$d" "$e" "nightly and dispatch on main share a group"
  [ "$d" != "$a" ] || { echo "main runs share the PR's group" >&2; return 1; }
  assert_eq true "$(gh_eval "$cancel" '{"event_name":"pull_request"}')" "PR runs cancel in progress"
  assert_eq false "$(gh_eval "$cancel" '{"event_name":"schedule"}')" "nightly runs are not cancelled"
  assert_eq false "$(gh_eval "$cancel" '{"event_name":"workflow_dispatch"}')" "dispatch runs are not cancelled"
}

# engine.yml as a reusable workflow (release.yml calls it with package: true).
ENGINE_PKG_STEP='Package the engine and test sources'
ENGINE_UPLOAD_PKG_STEP='Upload the package'
ENGINE_SAVE_STEP='Save ~/.mozbuild'

# step_if <file> <step>: the step's `if:` value, wrapped in ${{ }} if bare.
step_if() {
  local v
  v=$(step "$1" "$2" | sed -n 's/^[[:space:]]*if:[[:space:]]*//p' | head -1)
  case $v in '${{'*) printf '%s\n' "$v" ;; '') ;; *) printf '${{ %s }}\n' "$v" ;; esac
}

# Contexts: an engine PR run, a main push, an engine dispatch, release.yml's
# tag push calling engine.yml, and release.yml's dry-run dispatch on main.
CTX_PR='{"event_name":"pull_request","ref":"refs/pull/7/merge"}'
CTX_PR2='{"event_name":"pull_request","ref":"refs/pull/8/merge"}'
CTX_MAIN='{"event_name":"push","ref":"refs/heads/main"}'
CTX_DISPATCH='{"event_name":"workflow_dispatch","ref":"refs/heads/main"}'
CTX_TAG='{"event_name":"push","ref":"refs/tags/engine-v147.0.4-1"}'
CTX_DRY='{"event_name":"workflow_dispatch","ref":"refs/heads/main"}'
IN_CALL='{"package":true,"version":"147.0.4","revision":"1"}'

t_engine_call_inputs() {
  local f="$WF/engine.yml" block
  block=$(body "$f" | awk '/^  workflow_call:/{f=1; print; next} f && /^  [^ ]/{exit} f{print}')
  [ -n "$block" ] || { echo "engine.yml lacks on: workflow_call" >&2; return 1; }
  printf '%s\n' "$block" | python3 -c '
import re, sys
text = sys.stdin.read()
def inp(name):
    m = re.search(r"^      %s:\n((?:        .*\n?)+)" % name, text, re.M)
    assert m, "no input " + name
    return m.group(1)
p = inp("package")
assert re.search(r"^        type: boolean$", p, re.M), p
assert re.search(r"^        default: false$", p, re.M), p
assert re.search(r"^        required: false$", p, re.M), p
for n in ("version", "revision"):
    b = inp(n)
    assert re.search(r"^        type: string$", b, re.M), (n, b)
    assert re.search(r"^        required: false$", b, re.M), (n, b)
o = re.search(r"^    outputs:\n      package-artifact:\n((?:        .*\n?)+)", text, re.M)
assert o and "value: ${{ jobs.engine.outputs.package-artifact }}" in o.group(1), "no package-artifact output"
'
  has_line "$f" 'package-artifact: ${{ steps.package.outputs.artifact }}' ||
    { echo "job output package-artifact is not the package step's artifact" >&2; return 1; }
  # The other triggers stay.
  body "$f" | grep -Eq '^  pull_request:$' && body "$f" | grep -Eq '^  push:$' && body "$f" | grep -Eq '^  workflow_dispatch:$'
}

# Packaging runs after the smoke test, only when called with package: true;
# PR, push and dispatch runs never package.
t_engine_package_steps() {
  local f="$WF/engine.yml" s n_smoke n_pkg n_up ctx
  s=$(step "$f" "$ENGINE_PKG_STEP")
  [ -n "$s" ] || { echo "no '$ENGINE_PKG_STEP' step" >&2; return 1; }
  printf '%s\n' "$s" | grep -qE '^[[:space:]]+id: package$' || { echo "package step has no id: package" >&2; return 1; }
  n_smoke=$(body "$f" | grep -n -- '- name: Smoke$' | cut -d: -f1)
  n_pkg=$(body "$f" | grep -n -- "- name: $ENGINE_PKG_STEP\$" | cut -d: -f1)
  n_up=$(body "$f" | grep -n -- "- name: $ENGINE_UPLOAD_PKG_STEP\$" | cut -d: -f1)
  [ -n "$n_smoke" ] && [ -n "$n_pkg" ] && [ -n "$n_up" ] && [ "$n_smoke" -lt "$n_pkg" ] && [ "$n_pkg" -lt "$n_up" ] ||
    { echo "order is not smoke < package < upload ($n_smoke $n_pkg $n_up)" >&2; return 1; }
  # Inputs reach the script through env:, never interpolated into run:.
  ! step_run "$f" "$ENGINE_PKG_STEP" | grep -q '\${{' || { echo "package run: interpolates an expression" >&2; return 1; }
  printf '%s\n' "$s" | grep -qE '^[[:space:]]+PACKAGE_VERSION: \$\{\{ inputs\.version \}\}$' &&
    printf '%s\n' "$s" | grep -qE '^[[:space:]]+PACKAGE_REVISION: \$\{\{ inputs\.revision \}\}$' ||
    { echo "package step env does not bind inputs.version/revision" >&2; return 1; }
  # The upload: package-out/ as engine-package, failing when empty.
  s=$(step "$f" "$ENGINE_UPLOAD_PKG_STEP")
  printf '%s\n' "$s" | grep -qE 'uses: actions/upload-artifact@[0-9a-f]{40}' || { echo "package upload is not upload-artifact" >&2; return 1; }
  printf '%s\n' "$s" | grep -qE '^[[:space:]]+name: engine-package$' || { echo "package artifact is not engine-package" >&2; return 1; }
  printf '%s\n' "$s" | grep -qE '^[[:space:]]+path: package-out/$' || { echo "package upload path is not package-out/" >&2; return 1; }
  printf '%s\n' "$s" | grep -qE '^[[:space:]]+if-no-files-found: error$' || { echo "package upload tolerates no files" >&2; return 1; }
  # Both run only for a call with package: true.
  for s in "$ENGINE_PKG_STEP" "$ENGINE_UPLOAD_PKG_STEP"; do
    [ -n "$(step_if "$f" "$s")" ] || { echo "'$s' has no if:" >&2; return 1; }
    for ctx in "$CTX_PR" "$CTX_MAIN" "$CTX_DISPATCH" "$CTX_TAG"; do
      assert_eq false "$(gh_eval "$(step_if "$f" "$s")" "$ctx")" "'$s' without package input ($ctx)"
    done
    assert_eq false "$(gh_eval "$(step_if "$f" "$s")" "$CTX_TAG" '{"package":false}')" "'$s' with package: false"
    assert_eq true "$(gh_eval "$(step_if "$f" "$s")" "$CTX_TAG" "$IN_CALL")" "'$s' with package: true"
  done
  # zstd is installed for the packagers.
  step_run "$f" "Build prerequisites" | grep -qE 'apt-get install -y .*\bzstd\b' || { echo "zstd not installed" >&2; return 1; }
}

# The package step, executed with stub packagers: exact arguments, refuses
# missing inputs, and a failing packager fails the step.
t_engine_package_exec() {
  local f="$WF/engine.yml" d rc
  d=$(mktemp -d)
  mkdir -p "$d/scripts"
  printf '#!/bin/sh\necho "${0##*/} $*" >>"$CALLS"\nexit "${STUB_RC:-0}"\n' >"$d/scripts/package-test-sources.sh"
  cp "$d/scripts/package-test-sources.sh" "$d/scripts/package-engine.sh"
  chmod +x "$d/scripts/"*.sh
  : >"$d/calls"; : >"$d/out"
  exec_step "$f" "$ENGINE_PKG_STEP" "$d" CALLS="$d/calls" GITHUB_OUTPUT="$d/out" PACKAGE_VERSION=147.0.4 \
    PACKAGE_REVISION=1 >/dev/null 2>&1 || { echo "package step failed" >&2; rm -rf "$d"; return 1; }
  assert_eq "package-test-sources.sh --tree firefox --out package-out --version 147.0.4 --revision 1 --jstests
package-engine.sh --dist firefox/obj-nightmonkey-sm/dist --manifest build-manifest.json --out package-out --version 147.0.4 --revision 1 --test-sources package-out" \
    "$(cat "$d/calls")" "packager calls" || { rm -rf "$d"; return 1; }
  grep -qx 'artifact=engine-package' "$d/out" || { echo "no artifact=engine-package output" >&2; rm -rf "$d"; return 1; }
  for env in "PACKAGE_VERSION= PACKAGE_REVISION=1" "PACKAGE_VERSION=147.0.4 PACKAGE_REVISION="; do
    : >"$d/calls"
    rc=0
    # shellcheck disable=SC2086 # two name=value words
    exec_step "$f" "$ENGINE_PKG_STEP" "$d" CALLS="$d/calls" GITHUB_OUTPUT="$d/out" $env >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$d/calls" ] || { echo "package step ran with $env" >&2; rm -rf "$d"; return 1; }
  done
  rc=0
  exec_step "$f" "$ENGINE_PKG_STEP" "$d" CALLS="$d/calls" GITHUB_OUTPUT="$d/out" PACKAGE_VERSION=147.0.4 \
    PACKAGE_REVISION=1 STUB_RC=1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failing packager passes the step" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# Cache save, evaluated in the caller's context: a release call (tag push or
# dry-run dispatch) never saves; main pushes and engine dispatches still do;
# PRs never do. (!cancelled() is checked by t_engine and taken as true here.)
t_engine_call_cache() {
  local f="$WF/engine.yml" cond
  cond=$(step_if "$f" "$ENGINE_SAVE_STEP" | sed 's/!cancelled() && //')
  [ -n "$cond" ] || { echo "no save condition" >&2; return 1; }
  assert_eq false "$(gh_eval "$cond" "$CTX_TAG" "$IN_CALL")" "tag-called release saves the cache"
  assert_eq false "$(gh_eval "$cond" "$CTX_DRY" "$IN_CALL")" "release dry run saves the cache"
  assert_eq false "$(gh_eval "$cond" "$CTX_PR")" "PR saves the cache"
  assert_eq true "$(gh_eval "$cond" "$CTX_MAIN")" "main push does not save the cache"
  assert_eq true "$(gh_eval "$cond" "$CTX_DISPATCH")" "engine dispatch does not save the cache"
}

# Concurrency, evaluated in the caller's context: PR and main groups are what
# they were; a release call has its own group (also when dispatched on main),
# so it neither cancels nor displaces a PR or main run, and is not cancelled.
t_engine_call_concurrency() {
  local f="$WF/engine.yml" group cancel pr pr2 main tag dry
  group=$(concurrency_value "$f" group)
  cancel=$(concurrency_value "$f" cancel-in-progress)
  [ -n "$group" ] && [ -n "$cancel" ] || { echo "engine.yml lacks concurrency" >&2; return 1; }
  pr=$(gh_eval "$group" "$CTX_PR"); pr2=$(gh_eval "$group" "$CTX_PR2"); main=$(gh_eval "$group" "$CTX_MAIN")
  tag=$(gh_eval "$group" "$CTX_TAG" "$IN_CALL"); dry=$(gh_eval "$group" "$CTX_DRY" "$IN_CALL")
  assert_eq "engine-refs/pull/7/merge" "$pr" "PR group unchanged"
  assert_eq "engine-refs/heads/main" "$main" "main group unchanged"
  [ "$pr" != "$pr2" ] || { echo "two PRs share a group" >&2; return 1; }
  for g in "$pr" "$pr2" "$main"; do
    [ "$tag" != "$g" ] || { echo "the tag-called run shares group $g" >&2; return 1; }
    [ "$dry" != "$g" ] || { echo "the release dry run shares group $g" >&2; return 1; }
  done
  assert_eq true "$(gh_eval "$cancel" "$CTX_PR")" "PR runs cancel in progress"
  assert_eq false "$(gh_eval "$cancel" "$CTX_MAIN")" "main runs are not cancelled"
  assert_eq false "$(gh_eval "$cancel" "$CTX_TAG" "$IN_CALL")" "the tag-called run cancels in progress"
  assert_eq false "$(gh_eval "$cancel" "$CTX_DRY" "$IN_CALL")" "the release dry run cancels in progress"
}

# The pin is validated where it is read: executed with good and bad pins.
t_gate_pin() {
  check_pin_step "$WF/gate.yml" "Read the pins"
}

# The logs artifact carries provenance: the logs dir is created (with the pin)
# before anything can fail, and the engine's build-manifest.json is copied in
# and shown in the step summary after the build.
t_gate_provenance() {
  local f="$WF/gate.yml" d pin=0123456789abcdef0123456789abcdef01234567 prep build rec
  prep=$(body "$f" | grep -n -- '- name: Prepare logs$' | cut -d: -f1 || true)
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
run_test "engine.yml: workflow_call inputs and output" t_engine_call_inputs
run_test "engine.yml: packaging only when called with package: true" t_engine_package_steps
run_test "engine.yml: the package step runs both packagers" t_engine_package_exec
run_test "engine.yml: a release call never saves the cache" t_engine_call_cache
run_test "engine.yml: a release call has its own concurrency group" t_engine_call_concurrency
run_test "queue.yml: fixtures, real check, drift" t_queue
run_test "gate.yml: triggers, label condition, linked test tree, caches" t_gate
run_test "gate.yml: each lane reaches the harness and failures fail" t_gate_lanes
run_test "gate.yml: the pin step rejects bad pins" t_gate_pin
run_test "gate.yml: an unrelated label does not cancel the gate" t_gate_concurrency
run_test "gate.yml: logs carry the pin and the build manifest" t_gate_provenance
finish
