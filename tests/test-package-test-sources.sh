#!/usr/bin/env bash
# Tests for scripts/package-test-sources.sh on a fixture workdir
# (tests/fixture-testsrc.sh); no Firefox build. Needs GNU tar (`tar` or `gtar`)
# and zstd: without them the suite prints SKIP and exits 0 on a developer
# machine, but is FATAL (exit 1) when CI or GITHUB_ACTIONS is set.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-testsrc.sh
. "$ROOT/tests/fixture-testsrc.sh"

PKG="$ROOT/scripts/package-test-sources.sh"
TESTSRC=spidermonkey_147.0.4-1-testsrc
JSTESTS=spidermonkey_147.0.4-1-jstests

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

BASE=$(mktemp -d)
BASE=$(cd "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT

have_gnu_tar() {
  { tar --version 2>/dev/null | grep -q 'GNU tar'; } || { command -v gtar >/dev/null 2>&1 && gtar --version 2>/dev/null | grep -q 'GNU tar'; }
}

# The bundles' files, written out by hand (not derived from the packager).
EXPECT_TESTSRC='js/src/jit-test/README
js/src/jit-test/jit_test.py
js/src/jit-test/lib/gen/wasm-gc-limits-gen.js
js/src/jit-test/lib/match.js
js/src/jit-test/lib/math.js
js/src/jit-test/lib/non262.js
js/src/jit-test/lib/prologue.js
js/src/jit-test/lib/wasm-binary.js
js/src/jit-test/modules/module1.js
js/src/jit-test/tests/basic/simple.js
js/src/jit-test/tests/basic/uses-non262.js
js/src/jsapi.h
js/src/tests/jstests.py
js/src/tests/lib/__init__.py
js/src/tests/lib/adaptor.py
js/src/tests/lib/jittests.py
js/src/tests/lib/manifest.py
js/src/tests/lib/progressbar.py
js/src/tests/lib/results.py
js/src/tests/lib/structuredlog.py
js/src/tests/lib/tempfile.py
js/src/tests/lib/tests.py
js/src/tests/non262/Math/shell.js
js/src/tests/non262/reflect-parse/Match.js
js/src/tests/non262/shell.js'
EXPECT_JSTESTS='js/src/tests/jstests.list
js/src/tests/non262/Math/abs.js
js/src/tests/non262/Math/shell.js
js/src/tests/non262/Math/skipme.js
js/src/tests/non262/reflect-parse/Match.js
js/src/tests/non262/shell.js
js/src/tests/shell.js
js/src/tests/shell/os.js
js/src/tests/test262/built-ins/Array/length.js
js/src/tests/test262/shell.js
xul-info.txt'

# pin: write R/UPSTREAM pinning the fixture tree's current index tree.
pin() {
  printf 'url=https://github.com/mozilla-firefox/firefox\ntag=FIREFOX_147_0_4_RELEASE\ncommit=%s\ntree=%s\n' \
    "$(git -C "$TS_TREE" rev-parse HEAD)" "$(git -C "$TS_TREE" write-tree)" >"$R/UPSTREAM"
}

# setup: fixture workdir, a repository root R (UPSTREAM pinned to it, the real
# mozconfig for MOZ_OBJDIR), output and extraction directories.
setup() {
  local d
  d=$(mktemp -d "$BASE/case.XXXXXX")
  make_fixture_testsrc "$d"
  R=$d/root
  mkdir -p "$R"
  cp "$ROOT/mozconfig" "$R/mozconfig"
  pin
  OUTDIR=$d/out
  X=$d/extract
  STUB=$d/stub-shell
  write_stub "$STUB"
}

# commit_tree <message>: commit the fixture's worktree and repin UPSTREAM.
commit_tree() {
  git -C "$TS_TREE" add -A -- js
  git -C "$TS_TREE" commit -q -m "$1"
  pin
}

# run_pkg [args...]: package the fixture (default: testsrc only); sets OUT, RC.
run_pkg() {
  RC=0
  if [ $# -eq 0 ]; then
    set -- --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision 1
  fi
  OUT=$(cd "$BASE" && PQ_ROOT=$R "$PKG" "$@" 2>&1) || RC=$?
}

run_pkg_jstests() {
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision 1 --jstests
}

# write_stub <path>: a JS shell stand-in. It "runs" every -p/-f file: the file
# must exist, and every load(libdir + "x") and loadRelativeToScript("x") in it
# is followed recursively and must exist too; a file containing STUB-FAIL
# fails the run. So a test passes only if all it loads is in the bundle.
write_stub() {
  cat >"$1" <<'PY'
#!/usr/bin/env python3
import os, re, sys
args, files, libdir, i = sys.argv[1:], [], None, 0
while i < len(args):
    if args[i] in ("-f", "-p"):
        files.append(args[i + 1]); i += 2
    elif args[i] == "-e":
        m = re.match(r"const libdir='(.*)'$", args[i + 1])
        libdir = m.group(1) if m else libdir; i += 2
    elif args[i] == "--module-load-path":
        i += 2
    else:
        i += 1
seen = set()
def run(p):
    if not os.path.isfile(p):
        sys.exit("stub-shell: cannot load %s" % p)
    if p in seen:
        return
    seen.add(p)
    src = open(p).read()
    if "STUB-FAIL" in src:
        sys.exit("stub-shell: %s fails" % p)
    for m in re.finditer(r'loadRelativeToScript\(\s*"([^"]+)"\s*\)', src):
        run(os.path.normpath(os.path.join(os.path.dirname(p), m.group(1))))
    for m in re.finditer(r'load\(\s*libdir\s*\+\s*"([^"]+)"\s*\)', src):
        run(os.path.join(libdir, m.group(1)))
for f in files:
    run(f)
PY
  chmod +x "$1"
}

# extract <archive> [dir]: unpack into a directory unrelated to the producer.
extract() {
  local x=${2:-$X}
  mkdir -p "$x"
  zstd -dc "$1" | tar -xf - -C "$x"
}

# files_in <archive>: the archive's regular-file members, sorted.
files_in() {
  zstd -dc "$1" | python3 -c '
import sys, tarfile
for m in tarfile.open(fileobj=sys.stdin.buffer, mode="r|"):
    if m.isfile():
        print(m.name)
' | LC_ALL=C sort
}

# hide_producer: move the workdir away so nothing can resolve into it.
hide_producer() {
  mv "$TS_TREE" "$TS_TREE.hidden"
}

# expect_refusal <text>: exit 1, message contains <text>, no archive written.
expect_refusal() {
  assert_eq 1 "$RC" "$OUT"
  case $OUT in *"$1"*) ;; *) echo "message does not contain '$1': $OUT" >&2; return 1 ;; esac
  [ ! -e "$OUTDIR/$TESTSRC.tar.zst" ] || { echo "archive written despite refusal" >&2; return 1; }
}

testsrc_has_listed_paths_only() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$EXPECT_TESTSRC" "$(files_in "$OUTDIR/$TESTSRC.tar.zst")"
  [ ! -e "$OUTDIR/$JSTESTS.tar.zst" ] || { echo "jstests written without --jstests" >&2; return 1; }
  (cd "$OUTDIR" && sha256 <"$TESTSRC.tar.zst" | cut -d' ' -f1) >"$BASE/want.$$"
  assert_eq "$(cat "$BASE/want.$$")  $TESTSRC.tar.zst" "$(cat "$OUTDIR/$TESTSRC.tar.zst.sha256")"
}

jstests_has_listed_paths_only() {
  setup
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$EXPECT_TESTSRC" "$(files_in "$OUTDIR/$TESTSRC.tar.zst")"
  assert_eq "$EXPECT_JSTESTS" "$(files_in "$OUTDIR/$JSTESTS.tar.zst")"
  (cd "$OUTDIR" && sha256 <"$JSTESTS.tar.zst" | cut -d' ' -f1) >"$BASE/want.$$"
  assert_eq "$(cat "$BASE/want.$$")  $JSTESTS.tar.zst" "$(cat "$OUTDIR/$JSTESTS.tar.zst.sha256")"
}

# xul-info.txt is "ABI:OS:DEBUG" from the objdir's config/autoconf.mk, read as
# XULInfo.create reads it (MOZ_DEBUG empty -> false).
xul_info_from_autoconf() {
  setup
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  extract "$OUTDIR/$JSTESTS.tar.zst"
  assert_eq "wasm32-clang:WASI:false" "$(cat "$X/xul-info.txt")"
  setup
  printf 'OS_TARGET = WASI\nTARGET_XPCOM_ABI = wasm32-clang\nMOZ_DEBUG = 1\n' \
    >"$TS_TREE/obj-nightmonkey-sm/config/autoconf.mk"
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  extract "$OUTDIR/$JSTESTS.tar.zst"
  assert_eq "wasm32-clang:WASI:true" "$(cat "$X/xul-info.txt")"
}

jstests_requires_autoconf() {
  setup
  rm "$TS_TREE/obj-nightmonkey-sm/config/autoconf.mk"
  run_pkg_jstests
  expect_refusal config/autoconf.mk
  setup
  printf 'TARGET_XPCOM_ABI = wasm32-clang\n' >"$TS_TREE/obj-nightmonkey-sm/config/autoconf.mk"
  run_pkg_jstests
  expect_refusal OS_TARGET
  setup
  printf 'OS_TARGET = WA:SI\nTARGET_XPCOM_ABI = wasm32-clang\n' >"$TS_TREE/obj-nightmonkey-sm/config/autoconf.mk"
  run_pkg_jstests
  expect_refusal OS_TARGET
  # Without --jstests no autoconf.mk is needed.
  setup
  rm "$TS_TREE/obj-nightmonkey-sm/config/autoconf.mk"
  run_pkg
  assert_eq 0 "$RC" "$OUT"
}

# Two packagings (file times, umask and a hostile environment changed for the
# second) give the same bytes.
deterministic() {
  setup
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  local first=$OUTDIR
  OUTDIR=$BASE/second.$$
  touch "$TS_TREE/js/src/jsapi.h" "$TS_TREE/js/src/tests/shell.js"
  make_decoy "$BASE/decoy.$$"
  RC=0
  OUT=$(cd "$BASE" && umask 077 && PQ_ROOT=$R TAR_OPTIONS=--format=v7 ZSTD_CLEVEL=1 ZSTD_NBTHREADS=4 \
    GIT_DIR="$BASE/decoy.$$/.git" "$PKG" --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision 1 \
    --jstests 2>&1) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  cmp "$first/$TESTSRC.tar.zst" "$OUTDIR/$TESTSRC.tar.zst"
  cmp "$first/$JSTESTS.tar.zst" "$OUTDIR/$JSTESTS.tar.zst"
  cmp "$first/$TESTSRC.tar.zst.sha256" "$OUTDIR/$TESTSRC.tar.zst.sha256"
}

# The extracted testsrc bundle starts jit_test.py with the producer tree gone;
# without jsapi.h it does not.
harness_starts_from_bundle() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract "$OUTDIR/$TESTSRC.tar.zst"
  hide_producer
  (cd "$BASE" && python3 "$X/js/src/jit-test/jit_test.py" --help >/dev/null)
  rm "$X/js/src/jsapi.h"
  if (cd "$BASE" && python3 "$X/js/src/jit-test/jit_test.py" --help >/dev/null 2>&1); then
    echo "harness started without jsapi.h" >&2; return 1
  fi
}

# One tiny jit test whose libdir helpers load tests/non262 files runs through
# the stub shell from the bundle; with one of those files removed it fails.
runs_jit_test_through_stub_shell() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract "$OUTDIR/$TESTSRC.tar.zst"
  hide_producer
  local out
  out=$(cd "$BASE" && python3 "$X/js/src/jit-test/jit_test.py" "$STUB" basic/uses-non262.js 2>&1)
  case $out in *"TEST-PASS | basic/uses-non262.js"*) ;; *) echo "no pass: $out" >&2; return 1 ;; esac
  rm "$X/js/src/tests/non262/reflect-parse/Match.js"
  if (cd "$BASE" && python3 "$X/js/src/jit-test/jit_test.py" "$STUB" basic/uses-non262.js >/dev/null 2>&1); then
    echo "jit test passed with a missing runtime load" >&2; return 1
  fi
}

# testsrc + jstests extracted together run the jstests harness with
# --xul-info from xul-info.txt and no producer tree; jstests.list is honoured.
jstests_runner_starts_with_xul_info() {
  setup
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  extract "$OUTDIR/$TESTSRC.tar.zst"
  extract "$OUTDIR/$JSTESTS.tar.zst"
  hide_producer
  local out
  out=$(cd "$BASE" && python3 "$X/js/src/tests/jstests.py" --xul-info "$(cat "$X/xul-info.txt")" --wpt=disabled "$STUB" 2>&1)
  case $out in *"TEST-PASS | non262/Math/abs.js"*"TEST-PASS | test262/built-ins/Array/length.js"*) ;;
    *) echo "jstests did not run: $out" >&2; return 1 ;; esac
  case $out in *skipme* | *test/run.js*) echo "jstests.list not honoured: $out" >&2; return 1 ;; esac
  # Without --xul-info the harness looks for the producer's autoconf.mk.
  if (cd "$BASE" && python3 "$X/js/src/tests/jstests.py" --wpt=disabled "$STUB" >/dev/null 2>&1); then
    echo "jstests started without --xul-info and without the producer tree" >&2; return 1
  fi
}

refuses_unstaged_edit() {
  setup
  echo '# local edit' >>"$TS_TREE/js/src/tests/lib/jittests.py"
  run_pkg
  expect_refusal js/src/tests/lib/jittests.py
}

refuses_edit_hidden_by_assume_unchanged() {
  setup
  git -C "$TS_TREE" update-index --assume-unchanged js/src/jit-test/lib/prologue.js
  echo '// local edit' >>"$TS_TREE/js/src/jit-test/lib/prologue.js"
  run_pkg
  expect_refusal js/src/jit-test/lib/prologue.js
}

refuses_tree_mismatch() {
  setup
  echo '// new' >"$TS_TREE/js/src/jit-test/tests/basic/new.js"
  git -C "$TS_TREE" add -A -- js
  git -C "$TS_TREE" commit -q -m drift
  run_pkg
  expect_refusal "tree mismatch"
}

# Untracked build output (objdir, __pycache__) is allowed and not archived.
objdir_allowed_and_absent() {
  setup
  [ -f "$TS_TREE/obj-nightmonkey-sm/js/src/jit-test/tests/generated.js" ]
  [ -f "$TS_TREE/js/src/tests/lib/__pycache__/jittests.cpython-312.pyc" ]
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  local a
  for a in "$OUTDIR/$TESTSRC.tar.zst" "$OUTDIR/$JSTESTS.tar.zst"; do
    if zstd -dc "$a" | tar -tf - | grep -E 'obj-nightmonkey-sm|__pycache__'; then
      echo "build output archived in $a" >&2; return 1
    fi
  done
}

# A required file removed from the tracked tree (committed and repinned, so the
# hash check and the clean-worktree check both pass) is refused by name.
fails_on_missing_required_file() {
  local f
  for f in js/src/jit-test/jit_test.py js/src/jsapi.h js/src/tests/jstests.py; do
    setup
    git -C "$TS_TREE" rm -q "$f"
    git -C "$TS_TREE" commit -q -m "drop $f"
    pin
    run_pkg
    expect_refusal "$f"
  done
  for f in js/src/tests/shell.js js/src/tests/jstests.list; do
    setup
    git -C "$TS_TREE" rm -q "$f"
    git -C "$TS_TREE" commit -q -m "drop $f"
    pin
    run_pkg_jstests
    expect_refusal "$f"
  done
}

# A jit-test loadRelativeToScript target that is not tracked, or that leaves
# js/src, is refused naming the loader.
fails_on_bad_runtime_load() {
  setup
  printf 'loadRelativeToScript("../../tests/non262/Gone.js");\n' >"$TS_TREE/js/src/jit-test/lib/gone.js"
  commit_tree "dangling load"
  run_pkg
  expect_refusal js/src/jit-test/lib/gone.js
  setup
  printf 'loadRelativeToScript("../../../../other/b.txt");\n' >"$TS_TREE/js/src/jit-test/lib/escape.js"
  commit_tree "escaping load"
  run_pkg
  expect_refusal js/src/jit-test/lib/escape.js
}

fails_on_tracked_symlink() {
  setup
  ln -s ../jsapi.h "$TS_TREE/js/src/jit-test/jsapi-link.h"
  commit_tree "symlink"
  run_pkg
  expect_refusal js/src/jit-test/jsapi-link.h
}

refuses_version_not_upstream() {
  setup
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 148.0 --revision 1
  assert_eq 1 "$RC" "$OUT"
  [ ! -e "$OUTDIR/spidermonkey_148.0-1-testsrc.tar.zst" ]
}

refuses_existing_output() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  cp "$OUTDIR/$TESTSRC.tar.zst" "$BASE/keep.$$"
  run_pkg
  assert_eq 1 "$RC" "$OUT"
  cmp "$BASE/keep.$$" "$OUTDIR/$TESTSRC.tar.zst"
}

refuses_non_toplevel_tree() {
  setup
  run_pkg --tree "$TS_TREE/js" --out "$OUTDIR" --version 147.0.4 --revision 1
  assert_eq 1 "$RC" "$OUT"
}

usage_errors() {
  setup
  RC=0; OUT=$("$PKG" 2>&1) || RC=$?
  assert_eq 2 "$RC" "no args: $OUT"
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4; assert_eq 2 "$RC" "no revision: $OUT"
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision 0; assert_eq 2 "$RC" "revision 0: $OUT"
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version v147 --revision 1; assert_eq 2 "$RC" "bad version: $OUT"
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision 1 --bogus; assert_eq 2 "$RC" "unknown: $OUT"
  run_pkg --tree "$TS_TREE" --out "$OUTDIR" --version 147.0.4 --revision; assert_eq 2 "$RC" "no value: $OUT"
  run_pkg --tree "$BASE/none" --out "$OUTDIR" --version 147.0.4 --revision 1; assert_eq 2 "$RC" "missing tree: $OUT"
}

# Members are js/... (and xul-info.txt), regular files and directories only;
# the shared archive check accepts exactly those roots.
archive_members_rooted() {
  setup
  run_pkg_jstests
  assert_eq 0 "$RC" "$OUT"
  (
    # shellcheck source=../scripts/lib/package-contract.sh
    . "$ROOT/scripts/lib/package-contract.sh"
    pc_check_archive "$OUTDIR/$TESTSRC.tar.zst" js
    pc_check_archive "$OUTDIR/$JSTESTS.tar.zst" js xul-info.txt
    if pc_check_archive "$OUTDIR/$JSTESTS.tar.zst" js 2>/dev/null; then
      echo "xul-info.txt accepted without being an allowed root" >&2; exit 1
    fi
  )
}

# Without GNU tar or zstd the suite SKIPs locally but is FATAL under CI.
missing_tools_fatal_on_ci() {
  local d=$BASE/notools.$$ t rc out
  mkdir -p "$d"
  for t in bash dirname mktemp rm grep; do ln -s "$(command -v "$t")" "$d/$t"; done
  rc=0
  out=$(env -i PATH="$d" HOME="$BASE" "$d/bash" "$ROOT/tests/test-package-test-sources.sh" 2>&1) || rc=$?
  assert_eq 0 "$rc" "local: $out"
  case $out in *SKIP*) ;; *) echo "no SKIP locally: $out" >&2; return 1 ;; esac
  for t in CI=true GITHUB_ACTIONS=true; do
    rc=0
    out=$(env -i PATH="$d" HOME="$BASE" "$t" "$d/bash" "$ROOT/tests/test-package-test-sources.sh" 2>&1) || rc=$?
    assert_eq 1 "$rc" "$t: $out"
    case $out in *FATAL*) ;; *) echo "no FATAL under $t: $out" >&2; return 1 ;; esac
  done
}

if ! have_gnu_tar || ! command -v zstd >/dev/null 2>&1; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "FATAL test-package-test-sources.sh: GNU tar (tar or gtar) and zstd are required on CI and were not found" >&2
    exit 1
  fi
  echo "SKIP test-package-test-sources.sh: GNU tar (tar or gtar) and zstd are required and were not found; no case ran"
  exit 0
fi

run_test "testsrc has the listed paths only" testsrc_has_listed_paths_only
run_test "jstests has the listed paths only" jstests_has_listed_paths_only
run_test "xul-info.txt from autoconf.mk" xul_info_from_autoconf
run_test "jstests requires autoconf.mk" jstests_requires_autoconf
run_test "deterministic" deterministic
run_test "harness starts from the bundle" harness_starts_from_bundle
run_test "runs a jit test through a stub shell" runs_jit_test_through_stub_shell
run_test "jstests runner starts with --xul-info" jstests_runner_starts_with_xul_info
run_test "refuses an unstaged edit" refuses_unstaged_edit
run_test "refuses an edit hidden by assume-unchanged" refuses_edit_hidden_by_assume_unchanged
run_test "refuses a tree mismatch" refuses_tree_mismatch
run_test "objdir allowed and absent" objdir_allowed_and_absent
run_test "fails on a missing required file" fails_on_missing_required_file
run_test "fails on a bad runtime load" fails_on_bad_runtime_load
run_test "fails on a tracked symlink" fails_on_tracked_symlink
run_test "refuses version not in UPSTREAM" refuses_version_not_upstream
run_test "refuses existing output" refuses_existing_output
run_test "refuses a tree that is not the top level" refuses_non_toplevel_tree
run_test "usage errors" usage_errors
run_test "archive members rooted" archive_members_rooted
run_test "missing tools fatal on CI" missing_tools_fatal_on_ci
finish
