#!/usr/bin/env bash
# Tests for .github/workflows/release.yml and the scripts it runs:
# scripts/require-ref-on-main.sh, scripts/release-check.sh (tag, nightmonkey),
# scripts/release-set.sh (prepare, finalize, verify) and
# scripts/release-publish.sh. Workflow steps are executed against stub scripts
# (the t_gate_lanes style); the scripts run against git fixtures, a package-out
# made by the real packagers from the fixture dist and test tree, fake
# toolchain archives, and stub curl and gh. No build, no network.
set -eu

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO GITHUB_OUTPUT

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=workflow-lib.sh
. "$ROOT/tests/workflow-lib.sh"
# shellcheck source=fixture-dist.sh
. "$ROOT/tests/fixture-dist.sh"
# shellcheck source=fixture-testsrc.sh
. "$ROOT/tests/fixture-testsrc.sh"

WF="$ROOT/.github/workflows"
F="$WF/release.yml"
REQ_ON_MAIN="$ROOT/scripts/require-ref-on-main.sh"
CHECK="$ROOT/scripts/release-check.sh"
SET="$ROOT/scripts/release-set.sh"
PUBLISH="$ROOT/scripts/release-publish.sh"
V=147.0.4
N=1
P=spidermonkey_$V-$N

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
digest() { sha256 <"$1" | cut -d' ' -f1; }

BASE=$(mktemp -d)
BASE=$(cd "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT

have_gnu_tar() {
  { tar --version 2>/dev/null | grep -q 'GNU tar'; } || { command -v gtar >/dev/null 2>&1 && gtar --version 2>/dev/null | grep -q 'GNU tar'; }
}
TAR=tar
if ! tar --version 2>/dev/null | grep -q 'GNU tar'; then TAR=gtar; fi

# job <name>: the job block `  <name>:` of release.yml, written to a file whose
# path is printed (step/step_run/exec_step take a file).
job() {
  local out
  out=$(mktemp "$BASE/job.XXXXXX")
  body "$F" | awk -v j="  $1:" 'f && /^  [^ ]/{exit} f{print} $0 == j{f=1}' >"$out"
  printf '%s\n' "$out"
}

# --- workflow structure ------------------------------------------------------

t_triggers() {
  body "$F" | grep -Eq "^    tags: \['engine-v\*'\]$" || { echo "release.yml is not triggered by engine-v* tags" >&2; return 1; }
  body "$F" | grep -Eq '^  workflow_dispatch:$' || { echo "release.yml lacks workflow_dispatch" >&2; return 1; }
  ! body "$F" | grep -Eq '^  (pull_request|schedule|workflow_run|pull_request_target):' ||
    { echo "release.yml has another trigger" >&2; return 1; }
  local block
  block=$(body "$F" | awk '/^  workflow_dispatch:$/{f=1; next} f && /^  [^ ]/{exit} f{print}')
  printf '%s\n' "$block" | grep -Eq '^      tag:$' || { echo "dispatch has no tag input" >&2; return 1; }
  printf '%s\n' "$block" | grep -Eq '^        required: true$' || { echo "dispatch tag input is not required" >&2; return 1; }
}

# check-tag -> build -> accept -> publish.
t_needs_chain() {
  local j
  j=$(job build); grep -qx '    needs: check-tag' "$j" || { echo "build does not need check-tag" >&2; return 1; }
  j=$(job accept); grep -qx '    needs: \[check-tag, build\]' "$j" || { echo "accept does not need [check-tag, build]" >&2; return 1; }
  j=$(job publish); grep -qx '    needs: \[check-tag, accept\]' "$j" || { echo "publish does not need [check-tag, accept]" >&2; return 1; }
  [ -z "$(cat "$(job check-tag)" | grep -E '^    needs:' || true)" ] || { echo "check-tag needs something" >&2; return 1; }
}

# build is exactly the engine.yml call with package: true and the tag's version
# and revision.
t_build_calls_engine() {
  local j
  j=$(job build)
  assert_eq "    needs: check-tag
    uses: ./.github/workflows/engine.yml
    with:
      package: true
      version: \${{ needs.check-tag.outputs.version }}
      revision: \${{ needs.check-tag.outputs.revision }}" "$(sed '/^[[:space:]]*$/d' "$j")" "build job"
}

# publish runs only for a push of a tag: a dispatch (against a branch or a
# tag) and a branch push skip it.
t_publish_condition() {
  local cond
  cond=$(sed -n 's/^    if: //p' "$(job publish)")
  [ -n "$cond" ] || { echo "publish has no job if:" >&2; return 1; }
  case $cond in '${{'*) ;; *) cond="\${{ $cond }}" ;; esac
  assert_eq true "$(gh_eval "$cond" '{"event_name":"push","ref":"refs/tags/engine-v147.0.4-1","ref_type":"tag"}')" "tag push publishes"
  assert_eq false "$(gh_eval "$cond" '{"event_name":"workflow_dispatch","ref":"refs/heads/main","ref_type":"branch"}')" "dispatch on main"
  assert_eq false "$(gh_eval "$cond" '{"event_name":"workflow_dispatch","ref":"refs/tags/engine-v147.0.4-1","ref_type":"tag"}')" "dispatch on a tag"
  assert_eq false "$(gh_eval "$cond" '{"event_name":"push","ref":"refs/heads/main","ref_type":"branch"}')" "branch push"
}

# Only publish may write; it gets the token through github.token, never a
# secret; and it re-checks main, verifies, then publishes, in that order.
t_publish_job() {
  local j n_main n_dl n_verify n_pub
  j=$(job publish)
  assert_eq "    permissions:
      contents: write" "$(grep -A1 -E '^    permissions:' "$j")" "publish permissions"
  for other in check-tag accept; do
    ! grep -Eq '^    permissions:' "$(job "$other")" || { echo "$other has job permissions" >&2; return 1; }
  done
  ! body "$F" | grep -q 'secrets\.' || { echo "release.yml uses secrets" >&2; return 1; }
  grep -qx '          GH_TOKEN: ${{ github.token }}' "$j" || { echo "publish does not use github.token" >&2; return 1; }
  grep -qx '          fetch-depth: 0' "$j" || { echo "publish checkout is not full history" >&2; return 1; }
  n_main=$(grep -n -- "- name: Require the tag's commit on main$" "$j" | cut -d: -f1)
  n_dl=$(grep -n -- '- name: Download the release set$' "$j" | cut -d: -f1)
  n_verify=$(grep -n -- '- name: Verify the release set$' "$j" | cut -d: -f1)
  n_pub=$(grep -n -- '- name: Publish the release$' "$j" | cut -d: -f1)
  [ -n "$n_main" ] && [ -n "$n_dl" ] && [ -n "$n_verify" ] && [ -n "$n_pub" ] &&
    [ "$n_main" -lt "$n_dl" ] && [ "$n_dl" -lt "$n_verify" ] && [ "$n_verify" -lt "$n_pub" ] ||
    { echo "publish steps are not main < download < verify < publish" >&2; return 1; }
  grep -qx '          MANIFEST_SHA256: ${{ needs.accept.outputs.manifest-sha256 }}' "$j" ||
    { echo "publish does not take the manifest digest from accept's outputs" >&2; return 1; }
  grep -qx '      manifest-sha256: ${{ steps.finalize.outputs.manifest_sha256 }}' "$(job accept)" ||
    { echo "accept does not output the final manifest digest" >&2; return 1; }
}

# accept: a fresh runner with no ~/.mozbuild cache; the pinned wasmtime of
# engine.yml; the package from the build; accept-engine.sh with
# --require-clean-runner.
t_accept_job() {
  local j eng_sha
  j=$(job accept)
  ! grep -Eq 'actions/cache(/restore|/save)?@' "$j" || { echo "accept touches the actions cache" >&2; return 1; }
  ! grep -q 'mozbuild' "$j" || { echo "accept mentions ~/.mozbuild" >&2; return 1; }
  eng_sha=$(body "$WF/engine.yml" | sed -n 's/^  WASMTIME_SHA256: //p')
  [ -n "$eng_sha" ] && grep -qx "      WASMTIME_SHA256: $eng_sha" "$j" || { echo "accept's wasmtime digest is not engine.yml's" >&2; return 1; }
  grep -qx '          name: ${{ needs.build.outputs.package-artifact }}' "$j" || { echo "accept does not download the build's package" >&2; return 1; }
  step_run "$j" "Accept the engine" | grep -q -- '--require-clean-runner' || { echo "accept-engine.sh without --require-clean-runner" >&2; return 1; }
  grep -Eq '^    timeout-minutes: [0-9]+$' "$j" || { echo "accept has no timeout" >&2; return 1; }
  [ "$(sed -n 's/^    timeout-minutes: //p' "$j")" -ge 180 ] || { echo "accept timeout below 180 minutes" >&2; return 1; }
  grep -qx '          name: release-set' "$j" || { echo "accept does not upload release-set" >&2; return 1; }
  grep -qx '          if-no-files-found: error' "$j" || { echo "release-set upload tolerates no files" >&2; return 1; }
}

# The release's own concurrency group never equals engine.yml's group for the
# called build (engine-release-<ref>), for a tag push or a dispatch; a release
# is never cancelled in progress.
t_concurrency() {
  local group cancel eng ctx r e
  group=$(concurrency_value "$F" group)
  cancel=$(concurrency_value "$F" cancel-in-progress)
  eng=$(concurrency_value "$WF/engine.yml" group)
  [ -n "$group" ] && [ -n "$cancel" ] && [ -n "$eng" ] || { echo "missing concurrency" >&2; return 1; }
  for ctx in '{"event_name":"push","ref":"refs/tags/engine-v147.0.4-1"}' \
    '{"event_name":"workflow_dispatch","ref":"refs/heads/main"}' \
    '{"event_name":"workflow_dispatch","ref":"refs/tags/engine-v147.0.4-1"}'; do
    r=$(gh_eval "$group" "$ctx")
    e=$(gh_eval "$eng" "$ctx" '{"package":true}')
    [ -n "$r" ] && [ "$r" != "$e" ] || { echo "release group '$r' equals engine group '$e' ($ctx)" >&2; return 1; }
    assert_eq false "$(gh_eval "$cancel" "$ctx")" "release cancel-in-progress ($ctx)"
  done
}

# No expression is interpolated into a run: script (tag names and job outputs
# reach scripts through env:).
t_no_expressions_in_run() {
  local d n f
  d=$(mktemp -d)
  python3 -I - "$F" "$d" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
i = n = 0
while i < len(lines):
    m = re.match(r"^(\s*)(?:- )?run: (.*)$", lines[i])
    if not m:
        i += 1
        continue
    body = [m.group(2)]
    j, ind = i + 1, None
    if re.fullmatch(r"[|>](?:[+-][1-9]?|[1-9][+-]?)?", m.group(2).strip()):
        while j < len(lines):
            l = lines[j]
            if l.strip():
                k = len(l) - len(l.lstrip())
                if ind is None:
                    ind = k
                if k < ind:
                    break
            body.append(l)
            j += 1
    open("%s/%d.sh" % (sys.argv[2], i + 1), "w").write("\n".join(body) + "\n")
    n += 1
    i = j
PY
  n=0
  for f in "$d"/*.sh; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    if grep -q '\${{' "$f"; then echo "run: at line $(basename "$f" .sh) interpolates an expression" >&2; rm -rf "$d"; return 1; fi
  done
  rm -rf "$d"
  [ "$n" -ge 8 ] || { echo "only $n run: scripts" >&2; return 1; }
}

# check-tag clones NightMonkey's yurt with full history; publish and check-tag
# check out this repository with full history.
t_checkouts() {
  local j
  j=$(job check-tag)
  [ "$(grep -c 'fetch-depth: 0' "$j")" = 2 ] || { echo "check-tag checkouts are not both full history" >&2; return 1; }
  grep -qx '          repository: YurtOS/nightmonkey' "$j" && grep -qx '          ref: yurt' "$j" ||
    { echo "check-tag does not clone NightMonkey's yurt" >&2; return 1; }
}

RRN=76adea3a6764cbcafa50ea4bf7e7608ca4e054bb
t_requires_file() {
  assert_eq "$RRN" "$(cat "$ROOT/RELEASE_REQUIRES_NIGHTMONKEY")" "RELEASE_REQUIRES_NIGHTMONKEY"
  assert_eq 1 "$(wc -l <"$ROOT/RELEASE_REQUIRES_NIGHTMONKEY" | tr -d ' ')" "one line"
}

# --- workflow steps, executed against stub scripts ---------------------------

# stub_scripts <dir>: scripts/{release-check,require-ref-on-main,release-set,
# release-publish,accept-engine}.sh that record "<name> <args>" to $CALLS
# and exit $STUB_RC (default 0).
stub_scripts() {
  local s
  mkdir -p "$1/scripts"
  for s in release-check require-ref-on-main release-set release-publish accept-engine; do
    printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\nexit "${STUB_RC:-0}"\n' "$s" >"$1/scripts/$s.sh"
    chmod +x "$1/scripts/$s.sh"
  done
}

# run_step <job> <step> <expected call> [env...]: the step makes exactly that
# call, and fails when the stub fails.
run_step() {
  local j=$1 name=$2 want=$3 d rc
  shift 3
  d=$(mktemp -d "$BASE/step.XXXXXX")
  stub_scripts "$d"
  : >"$d/calls"
  exec_step "$(job "$j")" "$name" "$d" CALLS="$d/calls" RUNNER_TEMP=/rt GITHUB_SHA=abc123 "$@" >/dev/null 2>&1 ||
    { echo "step '$name' failed" >&2; return 1; }
  assert_eq "$want" "$(cat "$d/calls")" "step '$name'"
  rc=0
  exec_step "$(job "$j")" "$name" "$d" CALLS="$d/calls" RUNNER_TEMP=/rt GITHUB_SHA=abc123 STUB_RC=3 "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "step '$name' passes a failing script" >&2; return 1; }
}

t_steps() {
  run_step check-tag 'Check the tag' 'release-check tag engine-v147.0.4-1' TAG=engine-v147.0.4-1
  run_step check-tag 'Require the commit on main' 'require-ref-on-main abc123'
  run_step check-tag 'Require RELEASE_REQUIRES_NIGHTMONKEY in NIGHTMONKEY_PIN' 'release-check nightmonkey nightmonkey-history'
  run_step accept 'Prepare the release set' \
    'release-set prepare --package-out /rt/package-out --version 147.0.4 --revision 1 --work /rt/release' VERSION=147.0.4 REVISION=1
  run_step accept 'Accept the engine' \
    'accept-engine --package /rt/release/package --testsrc /rt/release/testsrc --toolchain /tc --sysroot /sr --nightmonkey nightmonkey --require-clean-runner' \
    TOOLCHAIN_ROOT=/tc SYSROOT=/sr
  run_step accept 'Finalize the release manifest' 'release-set finalize --work /rt/release --tag engine-v147.0.4-1' TAG=engine-v147.0.4-1
  run_step publish "Require the tag's commit on main" 'require-ref-on-main abc123'
  run_step publish 'Verify the release set' \
    'release-set verify --dir /rt/release-set --manifest-sha256 ff --version 147.0.4 --revision 1' MANIFEST_SHA256=ff VERSION=147.0.4 REVISION=1
  run_step publish 'Publish the release' 'release-publish --tag engine-v147.0.4-1 --dir /rt/release-set' TAG=engine-v147.0.4-1
  # The tag reaches check-tag from the push, or from the dispatch input.
  local env
  env=$(step "$(job check-tag)" 'Check the tag' | sed -n 's/^[[:space:]]*TAG: //p')
  assert_eq engine-v147.0.4-1 "$(gh_eval "$env" '{"event_name":"push","ref_name":"engine-v147.0.4-1"}' '{}')" "TAG on push"
  assert_eq engine-v147.0.4-2 "$(gh_eval "$env" '{"event_name":"workflow_dispatch","ref_name":"main"}' '{"tag":"engine-v147.0.4-2"}')" "TAG on dispatch"
}

# The NightMonkey pin read by accept is validated (40-hex) before use.
t_accept_pin() {
  local d good=0123456789abcdef0123456789abcdef01234567 pin rc
  d=$(mktemp -d "$BASE/pin.XXXXXX")
  printf '%s\n' "$good" >"$d/NIGHTMONKEY_PIN"
  : >"$d/out"
  exec_step "$(job accept)" 'Read NIGHTMONKEY_PIN' "$d" GITHUB_OUTPUT="$d/out" >/dev/null 2>&1 || { echo "valid pin rejected" >&2; return 1; }
  grep -qx "sha=$good" "$d/out" || { echo "no sha= output" >&2; return 1; }
  for pin in main '' "${good%?}" "$good x"; do
    printf '%s\n' "$pin" >"$d/NIGHTMONKEY_PIN"
    : >"$d/out"
    rc=0
    exec_step "$(job accept)" 'Read NIGHTMONKEY_PIN' "$d" GITHUB_OUTPUT="$d/out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && ! grep -q '^sha=' "$d/out" || { echo "pin '$pin' accepted" >&2; return 1; }
  done
}

# --- scripts/require-ref-on-main.sh ----------------------------------------

# main_fixture: an origin with main (M1, M2) and a side branch (X), and a full
# clone C; sets M1, M2, X.
main_fixture() {
  local o
  o=$(mktemp -d "$BASE/origin.XXXXXX")
  git -C "$o" init -q -b main
  echo 1 >"$o/f"; git -C "$o" add f; git -C "$o" commit -q -m m1; M1=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b side; echo x >"$o/f"; git -C "$o" commit -q -am x; X=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q main; echo 2 >"$o/f"; git -C "$o" commit -q -am m2; M2=$(git -C "$o" rev-parse HEAD)
  C=$(mktemp -d "$BASE/clone.XXXXXX")
  git clone -q "$o" "$C"
  git -C "$C" fetch -q origin side
  ORIGIN=$o
}

run_main() {
  RC=0
  OUT=$(cd "$C" && "$REQ_ON_MAIN" "$@" 2>&1) || RC=$?
}

t_require_ref_on_main() {
  main_fixture
  run_main "$M1"; assert_eq 0 "$RC" "M1: $OUT"
  run_main "$M2"; assert_eq 0 "$RC" "M2: $OUT"
  run_main "$X"; assert_eq 1 "$RC" "side commit: $OUT"
  case $OUT in *"is not an ancestor of main"*) ;; *) echo "no reason: $OUT" >&2; return 1 ;; esac
  run_main 0000000000000000000000000000000000000001; assert_eq 2 "$RC" "unknown commit: $OUT"
  run_main; assert_eq 2 "$RC" "no argument: $OUT"
  # main moves after the clone: the fetched origin/main decides.
  echo 3 >"$ORIGIN/f"; git -C "$ORIGIN" commit -q -am m3; local m3
  m3=$(git -C "$ORIGIN" rev-parse HEAD)
  git -C "$C" fetch -q origin "$m3" 2>/dev/null || git -C "$C" fetch -q origin main
  run_main "$m3"; assert_eq 0 "$RC" "new main commit: $OUT"
  # An exported GIT_DIR pointing elsewhere does not change the answer.
  make_decoy "$BASE/decoy.$$"
  RC=0; OUT=$(cd "$C" && GIT_DIR="$BASE/decoy.$$/.git" "$REQ_ON_MAIN" "$X" 2>&1) || RC=$?
  assert_eq 1 "$RC" "GIT_DIR decoy: $OUT"
  # A fetch that keeps failing fails closed.
  git -C "$C" remote set-url origin "$BASE/no-such-origin"
  run_main "$M1"; assert_eq 1 "$RC" "fetch failure: $OUT"
  case $OUT in *"fetch"*) ;; *) echo "fetch failure not reported: $OUT" >&2; return 1 ;; esac
}

# --- scripts/release-check.sh ------------------------------------------------

run_check() {
  RC=0
  : >"$BASE/gh-out"
  OUT=$(cd "$BASE" && GITHUB_OUTPUT="$BASE/gh-out" PQ_ROOT="${CHECK_ROOT:-$ROOT}" "$CHECK" "$@" 2>&1) || RC=$?
}

t_check_tag() {
  run_check tag engine-v147.0.4-1
  assert_eq 0 "$RC" "$OUT"
  assert_eq "version=147.0.4
revision=1
tag=engine-v147.0.4-1" "$(cat "$BASE/gh-out")" "outputs"
  run_check tag engine-v147.0.4-12
  assert_eq 0 "$RC" "$OUT"
  grep -qx 'revision=12' "$BASE/gh-out"
  local t
  for t in engine-v147.0.4 engine-v147.0.4-0 engine-v147.0.5-1 v147.0.4-1 engine-v147.0.4-1x \
    engine-v147.0.4-01 'engine-v147.0.4-1 ' "$(printf 'engine-v147.0.4-1\nx')" engine-v147-1 ''; do
    run_check tag "$t"
    assert_eq 1 "$RC" "tag '$t': $OUT"
    [ ! -s "$BASE/gh-out" ] || { echo "outputs written for '$t'" >&2; return 1; }
  done
  case $(run_check tag engine-v147.0.5-1; echo "$OUT") in *"UPSTREAM"*) ;; *) echo "version mismatch not named" >&2; return 1 ;; esac
  run_check; assert_eq 2 "$RC" "no subcommand"
  run_check bogus x; assert_eq 2 "$RC" "unknown subcommand"
}

# nm_fixture: a NightMonkey-like repo: A (required) -> B (pin) -> C (yurt tip),
# and S, a side commit off A that never merged; a full clone NM; a root R
# with RELEASE_REQUIRES_NIGHTMONKEY=A and NIGHTMONKEY_PIN=B.
nm_fixture() {
  local o
  o=$(mktemp -d "$BASE/nmo.XXXXXX")
  git -C "$o" init -q -b yurt
  echo a >"$o/f"; git -C "$o" add f; git -C "$o" commit -q -m a; A=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b side; echo s >"$o/f"; git -C "$o" commit -q -am s; S=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q yurt; echo b >"$o/f"; git -C "$o" commit -q -am b; B=$(git -C "$o" rev-parse HEAD)
  echo c >"$o/f"; git -C "$o" commit -q -am c; CC=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q --orphan other; echo o >"$o/f"; git -C "$o" add f; git -C "$o" commit -q -m o
  O=$(git -C "$o" rev-parse HEAD); git -C "$o" checkout -q yurt
  NM=$(mktemp -d "$BASE/nm.XXXXXX")
  git clone -q --no-single-branch "$o" "$NM"
  NMO=$o
  CHECK_ROOT=$(mktemp -d "$BASE/croot.XXXXXX")
  cp "$ROOT/UPSTREAM" "$CHECK_ROOT/UPSTREAM"
  echo "$A" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"
  echo "$B" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
}

t_check_nightmonkey() {
  nm_fixture
  run_check nightmonkey "$NM"; assert_eq 0 "$RC" "$OUT"
  echo "$CC" >"$CHECK_ROOT/NIGHTMONKEY_PIN"; run_check nightmonkey "$NM"; assert_eq 0 "$RC" "pin at tip: $OUT"
  echo "$A" >"$CHECK_ROOT/NIGHTMONKEY_PIN"; run_check nightmonkey "$NM"; assert_eq 0 "$RC" "pin equals required: $OUT"
  # The pin does not contain the required commit.
  echo "$B" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"; echo "$A" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
  run_check nightmonkey "$NM"; assert_eq 1 "$RC" "required newer than pin: $OUT"
  case $OUT in *"not an ancestor of NIGHTMONKEY_PIN"*) ;; *) echo "no reason: $OUT" >&2; return 1 ;; esac
  # A pin on a side branch that never reached yurt.
  echo "$A" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"; echo "$S" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
  run_check nightmonkey "$NM"; assert_eq 1 "$RC" "pin off yurt: $OUT"
  case $OUT in *"not on NightMonkey's yurt"*) ;; *) echo "no reason: $OUT" >&2; return 1 ;; esac
  # Unrelated history, unknown commits, malformed files.
  echo "$O" >"$CHECK_ROOT/NIGHTMONKEY_PIN"; run_check nightmonkey "$NM"; assert_eq 1 "$RC" "unrelated pin: $OUT"
  echo "$B" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
  echo 0000000000000000000000000000000000000001 >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"
  run_check nightmonkey "$NM"; assert_eq 1 "$RC" "unknown required: $OUT"
  local bad
  for bad in main '' "${A%?}" "$A extra" "$(echo "$A" | tr a-f A-F)"; do
    echo "$A" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
    printf '%s\n' "$bad" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"
    run_check nightmonkey "$NM"; assert_eq 1 "$RC" "required '$bad': $OUT"
    echo "$A" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"
    printf '%s\n' "$bad" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
    run_check nightmonkey "$NM"; assert_eq 1 "$RC" "pin '$bad': $OUT"
  done
  # A shallow clone cannot prove ancestry: refused.
  echo "$A" >"$CHECK_ROOT/RELEASE_REQUIRES_NIGHTMONKEY"; echo "$B" >"$CHECK_ROOT/NIGHTMONKEY_PIN"
  local sh
  sh=$(mktemp -d "$BASE/shallow.XXXXXX"); rmdir "$sh"
  git clone -q --depth 1 "file://$NMO" "$sh"
  run_check nightmonkey "$sh"; assert_eq 1 "$RC" "shallow: $OUT"
  case $OUT in *"shallow"*) ;; *) echo "shallow not named: $OUT" >&2; return 1 ;; esac
  run_check nightmonkey "$BASE/none"; assert_eq 2 "$RC" "missing clone: $OUT"
}

# --- scripts/release-set.sh ---------------------------------------------------

# make_toolchains <dir>: fake clang.tar.zst (clang/bin/clang, clang++) and
# sysroot-wasm32-wasi.tar.zst (sysroot-wasm32-wasi/include, lib), laid out as
# Mozilla's (one top-level directory each).
make_toolchains() {
  local s
  s=$(mktemp -d "$BASE/tcsrc.XXXXXX")
  mkdir -p "$s/clang/bin" "$s/clang/lib/clang/20/include" "$s/sysroot-wasm32-wasi/include" "$s/sysroot-wasm32-wasi/lib/wasm32-wasi"
  printf '#!/bin/sh\necho clang\n' >"$s/clang/bin/clang"; chmod +x "$s/clang/bin/clang"
  ln -s clang "$s/clang/bin/clang++"
  echo '/* stdint */' >"$s/clang/lib/clang/20/include/stdint.h"
  echo '/* stdio */' >"$s/sysroot-wasm32-wasi/include/stdio.h"
  echo 'libc' >"$s/sysroot-wasm32-wasi/lib/wasm32-wasi/libc.a"
  mkdir -p "$1"
  (cd "$s" && "$TAR" -cf - clang) | zstd -q -c >"$1/clang.tar.zst"
  (cd "$s" && "$TAR" -cf - sysroot-wasm32-wasi) | zstd -q -c >"$1/sysroot-wasm32-wasi.tar.zst"
}

TC_URL_CLANG=https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/AAA/artifacts/public/build/clang.tar.zst
TC_URL_SYSROOT=https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/BBB/artifacts/public/build/sysroot-wasm32-wasi.tar.zst

# make_package_out <out> [leak]: package-out/ as engine.yml leaves it, made by
# the real packagers from the fixture dist and fixture test tree, the build
# manifest recording the fake toolchains in $BASE/tc. With <leak>, a header
# carries that absolute path (invisible to the producer's own scan).
make_package_out() {
  local out=$1 leak=${2:-} w r
  w=$(mktemp -d "$BASE/pkg.XXXXXX")
  make_fixture_dist "$w/producer"
  make_fixture_testsrc "$w/ts"
  r=$w/root
  mkdir -p "$r"
  printf 'url=https://github.com/mozilla-firefox/firefox\ntag=FIREFOX_147_0_4_RELEASE\ncommit=%s\ntree=%s\n' \
    "$(git -C "$TS_TREE" rev-parse HEAD)" "$(git -C "$TS_TREE" write-tree)" >"$r/UPSTREAM"
  cp "$ROOT/mozconfig" "$r/mozconfig"
  git -C "$r" init -q; git -C "$r" add -A; git -C "$r" commit -q -m root
  [ -z "$leak" ] || printf '// from %s/x\n' "$leak" >>"$FX_DIST/system_wrappers/stdio.h"
  python3 - "$FX_MANIFEST" "$BASE/tc" "$TC_URL_CLANG" "$TC_URL_SYSROOT" <<'PY'
import hashlib, json, os, sys
path, tc, uc, us = sys.argv[1:]
m = json.load(open(path))
def ent(name, url):
    return {"name": name, "url": url,
            "sha256": hashlib.sha256(open(os.path.join(tc, name), "rb").read()).hexdigest()}
m["toolchain_artifacts"] = [ent("clang.tar.zst", uc), ent("sysroot-wasm32-wasi.tar.zst", us)]
json.dump(m, open(path, "w"), indent=2)
PY
  PQ_ROOT=$r "$ROOT/scripts/package-test-sources.sh" --tree "$TS_TREE" --out "$out" --version "$V" --revision "$N" --jstests >/dev/null
  HOME=$FX_HOME MOZBUILD_STATE_PATH=$FX_MOZBUILD PQ_ROOT=$r "$ROOT/scripts/package-engine.sh" --dist "$FX_DIST" \
    --manifest "$FX_MANIFEST" --out "$out" --version "$V" --revision "$N" --test-sources "$out" >/dev/null
}

# write_curl_stub <dir>: a curl that serves $TC_SRC/<url basename> for -o, and
# records the URL; CURL_FAIL=1 makes it fail like an expired URL.
write_curl_stub() {
  mkdir -p "$1"
  cat >"$1/curl" <<'SH'
#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
echo "curl $url" >>"$CALLS"
[ -z "${CURL_FAIL:-}" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
[ -n "$out" ] && [ -n "$url" ] || { echo "curl stub: need -o FILE and an https URL" >&2; exit 2; }
cp "$TC_SRC/${url##*/}" "$out"
SH
  chmod +x "$1/curl"
}

GOLDEN=
golden() {
  [ -z "$GOLDEN" ] || return 0
  make_toolchains "$BASE/tc"
  make_package_out "$BASE/golden"
  make_package_out "$BASE/golden-leak" /home/runner-elsewhere
  write_curl_stub "$BASE/stubs"
  GOLDEN=1
}

# setup_set: a fresh copy of package-out (PO), a work dir (W), a call log.
setup_set() {
  local d
  d=$(mktemp -d "$BASE/set.XXXXXX")
  PO=$d/package-out
  cp -R "$BASE/golden" "$PO"
  W=$d/work
  CALLS=$d/calls
  : >"$CALLS"
  TC=$BASE/tc
}

# run_set <subcommand> [args...]: with the stub curl and the given TC (served
# toolchains); sets OUT and RC; GITHUB_OUTPUT is $W.out.
run_set() {
  RC=0
  : >"$BASE/set-out"
  OUT=$(cd "$BASE" && env PATH="$BASE/stubs:$PATH" CALLS="$CALLS" TC_SRC="$TC" HOME="${SET_HOME:-/home/runner-test}" \
    GITHUB_WORKSPACE=/home/runner-test/work/yurt-firefox/yurt-firefox GITHUB_OUTPUT="$BASE/set-out" \
    ${SET_ENV:+$SET_ENV} "$SET" "$@" 2>&1) || RC=$?
}

prepare() { run_set prepare --package-out "$PO" --version "$V" --revision "$N" --work "$W"; }

ASSETS="$P-jstests.tar.zst
$P-jstests.tar.zst.sha256
$P-testsrc.tar.zst
$P-testsrc.tar.zst.sha256
$P-toolchain-clang.tar.zst
$P-toolchain-clang.tar.zst.sha256
$P-toolchain-sysroot.tar.zst
$P-toolchain-sysroot.tar.zst.sha256
$P-wasm32-wasi.tar.zst
$P-wasm32-wasi.tar.zst.sha256"

t_prepare_ok() {
  golden; setup_set
  prepare
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$ASSETS" "$(ls "$W/release-set" | LC_ALL=C sort)" "release set"
  # The toolchains are mirrored byte for byte; their digest is the recorded one.
  cmp "$TC/clang.tar.zst" "$W/release-set/$P-toolchain-clang.tar.zst"
  cmp "$TC/sysroot-wasm32-wasi.tar.zst" "$W/release-set/$P-toolchain-sysroot.tar.zst"
  local a
  for a in wasm32-wasi testsrc jstests toolchain-clang toolchain-sysroot; do
    assert_eq "$(digest "$W/release-set/$P-$a.tar.zst")  $P-$a.tar.zst" "$(cat "$W/release-set/$P-$a.tar.zst.sha256")" "$a .sha256"
  done
  cmp "$PO/$P-wasm32-wasi.tar.zst" "$W/release-set/$P-wasm32-wasi.tar.zst"
  assert_eq "curl $TC_URL_CLANG
curl $TC_URL_SYSROOT" "$(cat "$CALLS")" "downloads"
  # Extracted inputs for accept-engine.sh, and the outputs naming them.
  [ -f "$W/package/spidermonkey/include-private/js-build-config.json" ]
  [ -f "$W/testsrc/js/src/jit-test/jit_test.py" ] && [ -f "$W/testsrc/xul-info.txt" ]
  [ -x "$W/toolchain/clang/bin/clang" ] && [ -d "$W/toolchain/sysroot-wasm32-wasi/include" ]
  grep -qx "toolchain_root=$W/toolchain/clang" "$BASE/set-out" || { echo "no toolchain_root: $(cat "$BASE/set-out")" >&2; return 1; }
  grep -qx "sysroot=$W/toolchain/sysroot-wasm32-wasi" "$BASE/set-out" || { echo "no sysroot output" >&2; return 1; }
  # Toolchains never land in ~/.mozbuild.
  [ ! -e /home/runner-test/.mozbuild ]
}

# expect_prepare_fails <text>: exit 1, the message has <text>, no release set.
expect_prepare_fails() {
  assert_eq 1 "$RC" "$OUT"
  case $OUT in *"$1"*) ;; *) echo "output lacks '$1': $OUT" >&2; return 1 ;; esac
  [ ! -e "$W/release-set/$P-wasm32-wasi.tar.zst" ] || { echo "release set written despite failure" >&2; return 1; }
}

# A served toolchain whose bytes differ from the recorded digest is refused.
t_prepare_toolchain_digest() {
  golden; setup_set
  TC=$(mktemp -d "$BASE/tcbad.XXXXXX")
  cp "$BASE/tc/"* "$TC/"
  echo tamper >>"$TC/sysroot-wasm32-wasi.tar.zst"
  prepare
  expect_prepare_fails "sysroot-wasm32-wasi.tar.zst: sha256"
}

t_prepare_toolchain_unreachable() {
  golden; setup_set
  SET_ENV=CURL_FAIL=1 prepare
  expect_prepare_fails "clang.tar.zst: download failed"
}

# edit_manifest <python on m>: rewrite package-out/MANIFEST.json.
edit_manifest() {
  python3 - "$PO/MANIFEST.json" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(m, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
}

# The toolchain mapping is explicit: exactly clang.tar.zst and
# sysroot-wasm32-wasi.tar.zst, https URLs.
t_prepare_toolchain_mapping() {
  golden
  local edit
  for edit in 'm["toolchain"][0]["name"] = "clang-17.tar.zst"' 'm["toolchain"].pop()' \
    'm["toolchain"].append(dict(m["toolchain"][0]))' 'm["toolchain"][1]["url"] = "http://x/sysroot-wasm32-wasi.tar.zst"' \
    'm["toolchain"][0]["url"] = "file:///etc/clang.tar.zst"'; do
    setup_set
    edit_manifest "$edit"
    prepare
    expect_prepare_fails "toolchain"
  done
}

# Each asset must fit a GitHub release asset (< 1.9 GiB); the cap can only be
# lowered (tests), never raised.
t_prepare_size_cap() {
  golden; setup_set
  SET_ENV=RELEASE_SET_MAX_BYTES=1000 prepare
  expect_prepare_fails "exceeds"
  setup_set
  SET_ENV=RELEASE_SET_MAX_BYTES=99999999999 prepare
  assert_eq 2 "$RC" "raised cap: $OUT"
}

# A toolchain archive must have exactly one top-level directory, and the clang
# one must hold bin/clang and bin/clang++.
t_prepare_toolchain_layout() {
  golden
  local s case
  for case in two-tops no-clang file-top; do
    setup_set
    TC=$(mktemp -d "$BASE/tcl.XXXXXX")
    cp "$BASE/tc/sysroot-wasm32-wasi.tar.zst" "$TC/"
    s=$(mktemp -d "$BASE/tcls.XXXXXX")
    mkdir -p "$s/clang/bin"
    printf '#!/bin/sh\n' >"$s/clang/bin/clang"; chmod +x "$s/clang/bin/clang"; ln -s clang "$s/clang/bin/clang++"
    case $case in
      two-tops) mkdir -p "$s/extra"; echo x >"$s/extra/f"; (cd "$s" && "$TAR" -cf - clang extra) | zstd -q -c >"$TC/clang.tar.zst" ;;
      no-clang) rm "$s/clang/bin/clang++"; (cd "$s" && "$TAR" -cf - clang) | zstd -q -c >"$TC/clang.tar.zst" ;;
      file-top) echo x >"$s/README"; (cd "$s" && "$TAR" -cf - README) | zstd -q -c >"$TC/clang.tar.zst" ;;
    esac
    edit_manifest "import hashlib; m['toolchain'][0]['sha256'] = hashlib.sha256(open('$TC/clang.tar.zst','rb').read()).hexdigest()"
    prepare
    expect_prepare_fails "clang.tar.zst"
  done
}

# The package must be consistent: archive digests match their .sha256 and
# MANIFEST.json, the version, and the extracted tree matches dist_files.
t_prepare_package_consistency() {
  golden
  setup_set; echo x >>"$PO/$P-wasm32-wasi.tar.zst"; prepare; expect_prepare_fails "$P-wasm32-wasi.tar.zst"
  setup_set; echo x >>"$PO/$P-jstests.tar.zst"; prepare; expect_prepare_fails "$P-jstests.tar.zst"
  setup_set; rm "$PO/$P-jstests.tar.zst" "$PO/$P-jstests.tar.zst.sha256"; prepare; expect_prepare_fails "jstests"
  setup_set; edit_manifest 'm["test_sources"]["testsrc"]["sha256"] = "0" * 64'; prepare; expect_prepare_fails "testsrc"
  setup_set; edit_manifest 'm["package_version"] = "147.0.4-2"'; prepare; expect_prepare_fails "package_version"
  setup_set; edit_manifest 'm["dist_files"]["count"] += 1'; prepare; expect_prepare_fails "dist_files"
  setup_set; run_set prepare --package-out "$PO" --version 147.0.5 --revision 1 --work "$W"; expect_prepare_fails "147.0.5"
}

# The Y1 contract is re-run on the extracted archive; producer prefixes are
# gone from its config, so the runner's own $HOME and workspace (the build
# job's paths on the same runner image) are the prefixes scanned for.
t_prepare_contract_recheck() {
  golden; setup_set
  rm -rf "$PO"; cp -R "$BASE/golden-leak" "$PO"
  SET_HOME=/home/runner-elsewhere prepare
  expect_prepare_fails "contains producer path /home/runner-elsewhere"
  setup_set
  rm -rf "$PO"; cp -R "$BASE/golden-leak" "$PO"
  prepare
  assert_eq 0 "$RC" "leak of another host's HOME: $OUT"
}

finalize() { run_set finalize --work "$W" --tag engine-v147.0.4-1; }

t_finalize() {
  golden; setup_set
  prepare; assert_eq 0 "$RC" "$OUT"
  finalize; assert_eq 0 "$RC" "$OUT"
  [ -f "$W/release-set/MANIFEST.json" ]
  grep -qx "manifest_sha256=$(digest "$W/release-set/MANIFEST.json")" "$BASE/set-out" || { echo "no manifest_sha256 output" >&2; return 1; }
  python3 - "$W/release-set" "$PO/MANIFEST.json" "$TC_URL_CLANG" "$TC_URL_SYSROOT" <<'PY'
import hashlib, json, os, sys
d, y1, uc, us = sys.argv[1:]
m = json.load(open(os.path.join(d, "MANIFEST.json")))
base = json.load(open(y1))
for k, v in base.items():
    assert m[k] == v, k
r = m["release"]
assert r["tag"] == "engine-v147.0.4-1", r
names = sorted(f for f in os.listdir(d) if f.endswith(".tar.zst"))
assert [a["name"] for a in r["assets"]] == names, r["assets"]
for a in r["assets"]:
    data = open(os.path.join(d, a["name"]), "rb").read()
    assert a["sha256"] == hashlib.sha256(data).hexdigest() and a["size"] == len(data), a
mirrors = {a["name"]: a.get("mirror_of") for a in r["assets"]}
assert mirrors["spidermonkey_147.0.4-1-toolchain-clang.tar.zst"] == uc, mirrors
assert mirrors["spidermonkey_147.0.4-1-toolchain-sysroot.tar.zst"] == us, mirrors
tc = {t["name"]: t["sha256"] for t in m["toolchain"]}
by = {a["name"]: a["sha256"] for a in r["assets"]}
assert by["spidermonkey_147.0.4-1-toolchain-clang.tar.zst"] == tc["clang.tar.zst"]
assert by["spidermonkey_147.0.4-1-toolchain-sysroot.tar.zst"] == tc["sysroot-wasm32-wasi.tar.zst"]
PY
  # finalize needs a prepared work dir, and refuses to run twice.
  finalize; assert_eq 1 "$RC" "second finalize: $OUT"
  setup_set; finalize; assert_eq 1 "$RC" "finalize without prepare: $OUT"
}

# setup_final: a finalized release set copied to D (as publish downloads it)
# and its manifest digest H.
setup_final() {
  golden; setup_set
  prepare; finalize
  D=$(mktemp -d "$BASE/final.XXXXXX")
  cp "$W/release-set/"* "$D/"
  H=$(digest "$D/MANIFEST.json")
}

verify() { run_set verify --dir "$D" --manifest-sha256 "${1:-$H}" --version "$V" --revision "$N"; }

t_verify() {
  setup_final
  verify; assert_eq 0 "$RC" "$OUT"
  # A swapped asset, its .sha256 updated too: the manifest catches it.
  setup_final
  echo x >>"$D/$P-toolchain-clang.tar.zst"
  printf '%s  %s\n' "$(digest "$D/$P-toolchain-clang.tar.zst")" "$P-toolchain-clang.tar.zst" >"$D/$P-toolchain-clang.tar.zst.sha256"
  verify; assert_eq 1 "$RC" "swapped toolchain: $OUT"
  # A swapped asset and a manifest rewritten to match: accept's digest catches it.
  setup_final
  echo x >>"$D/$P-wasm32-wasi.tar.zst"
  printf '%s  %s\n' "$(digest "$D/$P-wasm32-wasi.tar.zst")" "$P-wasm32-wasi.tar.zst" >"$D/$P-wasm32-wasi.tar.zst.sha256"
  python3 - "$D" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
p = os.path.join(d, "MANIFEST.json")
m = json.load(open(p))
for a in m["release"]["assets"]:
    data = open(os.path.join(d, a["name"]), "rb").read()
    a["sha256"], a["size"] = hashlib.sha256(data).hexdigest(), len(data)
json.dump(m, open(p, "w"), indent=2, sort_keys=True)
PY
  verify; assert_eq 1 "$RC" "swapped artifact with consistent manifest: $OUT"
  case $OUT in *"MANIFEST.json"*) ;; *) echo "manifest digest mismatch not named: $OUT" >&2; return 1 ;; esac
  # A stale .sha256, a missing or an extra file, a wrong expected digest.
  setup_final; echo "0000  $P-testsrc.tar.zst" >"$D/$P-testsrc.tar.zst.sha256"; verify; assert_eq 1 "$RC" "bad .sha256: $OUT"
  setup_final; rm "$D/$P-jstests.tar.zst.sha256"; verify; assert_eq 1 "$RC" "missing file: $OUT"
  setup_final; echo x >"$D/extra.txt"; verify; assert_eq 1 "$RC" "extra file: $OUT"
  setup_final; verify 0000000000000000000000000000000000000000000000000000000000000000; assert_eq 1 "$RC" "wrong digest: $OUT"
  setup_final; verify ''; assert_eq 2 "$RC" "empty digest: $OUT"
  setup_final; run_set verify --dir "$D" --manifest-sha256 "$H" --version "$V" --revision 2; assert_eq 1 "$RC" "other revision: $OUT"
}

# --- scripts/release-publish.sh ----------------------------------------------

# write_gh_stub <dir>: gh api .../releases prints $GH_RELEASES (one tag per
# line; GH_API_FAIL=1 fails); gh release create records its arguments.
write_gh_stub() {
  mkdir -p "$1"
  cat >"$1/gh" <<'SH'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$1 $2" in
  "api "*)
    [ -z "${GH_API_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    cat "$GH_RELEASES" ;;
  "release create") exit "${GH_CREATE_RC:-0}" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 2 ;;
esac
SH
  chmod +x "$1/gh"
}

run_publish() {
  RC=0
  OUT=$(cd "$BASE" && env PATH="$BASE/ghstub:$PATH" CALLS="$CALLS" GH_RELEASES="$BASE/releases" GH_REPO=YurtOS/yurt-firefox \
    ${PUB_ENV:+$PUB_ENV} "$PUBLISH" "$@" 2>&1) || RC=$?
}

t_publish() {
  setup_final
  write_gh_stub "$BASE/ghstub"
  printf 'engine-v147.0.4-0\nengine-v147.0.4-10\n' >"$BASE/releases"
  : >"$CALLS"
  run_publish --tag engine-v147.0.4-1 --dir "$D"
  assert_eq 0 "$RC" "$OUT"
  local create
  create=$(grep '^gh release create' "$CALLS")
  case $create in "gh release create engine-v147.0.4-1 --verify-tag "*) ;; *) echo "create: $create" >&2; return 1 ;; esac
  local f
  for f in MANIFEST.json $ASSETS; do
    case " $create " in *" $D/$f "*) ;; *) echo "asset $f not uploaded: $create" >&2; return 1 ;; esac
  done
  grep -q '^gh api .*repos/YurtOS/yurt-firefox/releases' "$CALLS" || { echo "existing releases not listed" >&2; return 1; }
  # An existing release (a draft included: the listing has drafts) is refused.
  printf 'engine-v147.0.4-1\n' >"$BASE/releases"; : >"$CALLS"
  run_publish --tag engine-v147.0.4-1 --dir "$D"
  assert_eq 1 "$RC" "existing release: $OUT"
  ! grep -q '^gh release create' "$CALLS" || { echo "created over an existing release" >&2; return 1; }
  # The listing failing is not "no release".
  printf '' >"$BASE/releases"; : >"$CALLS"
  PUB_ENV=GH_API_FAIL=1 run_publish --tag engine-v147.0.4-1 --dir "$D"
  assert_eq 1 "$RC" "listing failed: $OUT"
  ! grep -q '^gh release create' "$CALLS" || { echo "created after a failed listing" >&2; return 1; }
  # A failing create fails; usage errors exit 2.
  : >"$CALLS"
  PUB_ENV=GH_CREATE_RC=1 run_publish --tag engine-v147.0.4-1 --dir "$D"
  assert_eq 1 "$RC" "create failed: $OUT"
  run_publish --tag engine-v147.0.4-1; assert_eq 2 "$RC" "no dir: $OUT"
  RC=0; OUT=$(cd "$BASE" && env -u GH_REPO PATH="$BASE/ghstub:$PATH" CALLS="$CALLS" GH_RELEASES="$BASE/releases" \
    "$PUBLISH" --tag engine-v147.0.4-1 --dir "$D" 2>&1) || RC=$?
  assert_eq 2 "$RC" "no GH_REPO: $OUT"
}

if ! have_gnu_tar || ! command -v zstd >/dev/null 2>&1; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "FATAL test-release-workflow.sh: GNU tar (tar or gtar) and zstd are required on CI and were not found" >&2
    exit 1
  fi
  echo "SKIP test-release-workflow.sh: GNU tar (tar or gtar) and zstd are required and were not found; no case ran"
  exit 0
fi

# The package-out fixtures are made once, before the cases (each case runs
# in a subshell).
golden || { echo "FAIL: could not build the package-out fixtures" >&2; exit 1; }

run_test "release.yml: triggers" t_triggers
run_test "release.yml: check-tag -> build -> accept -> publish" t_needs_chain
run_test "release.yml: build is the engine.yml call with package: true" t_build_calls_engine
run_test "release.yml: publish only for a tag push" t_publish_condition
run_test "release.yml: publish is the only writer, re-checks and verifies" t_publish_job
run_test "release.yml: accept on a clean runner" t_accept_job
run_test "release.yml: own concurrency group, never cancelled" t_concurrency
run_test "release.yml: no expression in a run: script" t_no_expressions_in_run
run_test "release.yml: full-history checkouts" t_checkouts
run_test "RELEASE_REQUIRES_NIGHTMONKEY" t_requires_file
run_test "release.yml: each step calls its script" t_steps
run_test "release.yml: accept validates the NightMonkey pin" t_accept_pin
run_test "require-ref-on-main.sh" t_require_ref_on_main
run_test "release-check.sh tag" t_check_tag
run_test "release-check.sh nightmonkey" t_check_nightmonkey
run_test "release-set.sh prepare" t_prepare_ok
run_test "release-set.sh prepare: toolchain digest" t_prepare_toolchain_digest
run_test "release-set.sh prepare: toolchain unreachable" t_prepare_toolchain_unreachable
run_test "release-set.sh prepare: toolchain mapping" t_prepare_toolchain_mapping
run_test "release-set.sh prepare: size cap" t_prepare_size_cap
run_test "release-set.sh prepare: toolchain layout" t_prepare_toolchain_layout
run_test "release-set.sh prepare: package consistency" t_prepare_package_consistency
run_test "release-set.sh prepare: contract recheck" t_prepare_contract_recheck
run_test "release-set.sh finalize" t_finalize
run_test "release-set.sh verify" t_verify
run_test "release-publish.sh" t_publish
finish
