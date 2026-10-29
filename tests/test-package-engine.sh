#!/usr/bin/env bash
# Tests for scripts/package-engine.sh and scripts/lib/package-contract.sh on a
# fixture dist (tests/fixture-dist.sh); no Firefox build. The packager needs GNU
# tar (`tar` or `gtar`) and zstd; without them the suite prints SKIP and exits 0
# on a developer machine, but is FATAL (exit 1) when CI or GITHUB_ACTIONS is set,
# so a CI image without them cannot pass the fixtures lane vacuously.
set -euo pipefail

unset PQ_YURT_REPO PQ_YURT_REF PQ_DOM_COUNT PQ_LISTS_DIR PQ_DIFF_REPO GITHUB_WORKSPACE NM_REPO

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=fixture-dist.sh
. "$ROOT/tests/fixture-dist.sh"

PKG="$ROOT/scripts/package-engine.sh"
CONTRACT="$ROOT/scripts/lib/package-contract.sh"
NAME=spidermonkey_147.0.4-1-wasm32-wasi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

BASE=$(mktemp -d)
BASE=$(cd "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT

have_gnu_tar() {
  { tar --version 2>/dev/null | grep -q 'GNU tar'; } || { command -v gtar >/dev/null 2>&1 && gtar --version 2>/dev/null | grep -q 'GNU tar'; }
}

# setup: a fresh fixture dist, and a repo root R (git repo with UPSTREAM pinning
# FIREFOX_147_0_4_RELEASE) standing in for this repository.
setup() {
  local d
  d=$(mktemp -d "$BASE/case.XXXXXX")
  make_fixture_dist "$d/producer"
  R=$d/root
  mkdir -p "$R"
  cp "$ROOT/UPSTREAM" "$R/UPSTREAM"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" commit -q -m root
  OUTDIR=$d/out
  X=$d/extract
}

# run_pkg [args...]: package the fixture (default args) with the producer's
# HOME and MOZBUILD_STATE_PATH; sets OUT and RC.
run_pkg() {
  RC=0
  if [ $# -eq 0 ]; then
    set -- --dist "$FX_DIST" --manifest "$FX_MANIFEST" --out "$OUTDIR" --version 147.0.4 --revision 1
  fi
  OUT=$(cd "$BASE" && HOME=$FX_HOME MOZBUILD_STATE_PATH=$FX_MOZBUILD PQ_ROOT=$R "$PKG" "$@" 2>&1) || RC=$?
}

# extract [archive] [dir]: unpack into a directory unrelated to the producer.
extract() {
  local a=${1:-$OUTDIR/$NAME.tar.zst} x=${2:-$X}
  mkdir -p "$x"
  zstd -dc "$a" | tar -xf - -C "$x"
}

# expect_violation <relpath>: the packager exits 1 naming <relpath> and leaves
# no archive behind.
expect_violation() {
  assert_eq 1 "$RC" "$OUT"
  case $OUT in *"$1"*) ;; *) echo "message does not name $1: $OUT" >&2; return 1 ;; esac
  [ ! -e "$OUTDIR/$NAME.tar.zst" ] || { echo "archive written despite violation" >&2; return 1; }
}

# text_files <tree>: every file but the exempt binaries (lib/*.a, bin/js).
text_files() {
  (cd "$1" && find . -type f ! -path './lib/*.a' ! -path './bin/js' | LC_ALL=C sort)
}

packages_relocatable_tree() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  [ -f "$OUTDIR/$NAME.tar.zst" ] && [ -f "$OUTDIR/$NAME.tar.zst.sha256" ] && [ -f "$OUTDIR/MANIFEST.json" ]
  extract
  assert_eq spidermonkey "$(ls "$X")" "single top-level directory"
  assert_eq "" "$(find "$X" -type l)" "symlinks in archive"
  local f
  for f in include/jsapi.h include/js/Value.h include/mozilla/Types.h include-private/vm/Opcodes.h \
    include-private/js-build-config.json include-private/js-confdefs.h system_wrappers/stdio.h \
    lib/libjs_static.a lib/libjsrust.a lib/libjsshell.a lib/libpure_virtual.a bin/js MANIFEST.json; do
    [ -f "$X/spidermonkey/$f" ] || { echo "missing $f" >&2; return 1; }
  done
  [ -x "$X/spidermonkey/bin/js" ]
  cmp "$FX_SRC/js/src/jsapi.h" "$X/spidermonkey/include/jsapi.h"
  cmp "$FX_SRC/mfbt/Types.h" "$X/spidermonkey/include/mozilla/Types.h"
  cmp "$FX_OBJ/js/src/build/libjs_static.a" "$X/spidermonkey/lib/libjs_static.a"
  [ ! -e "$X/spidermonkey/host" ] || { echo "dist/host packaged" >&2; return 1; }
  cmp "$OUTDIR/MANIFEST.json" "$X/spidermonkey/MANIFEST.json"
  (cd "$OUTDIR" && sha256 <"$NAME.tar.zst" | cut -d' ' -f1) >"$BASE/want"
  assert_eq "$(cat "$BASE/want")  $NAME.tar.zst" "$(cat "$OUTDIR/$NAME.tar.zst.sha256")"
}

no_producer_prefix_in_text_files() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract
  local f p
  [ -n "$(text_files "$X/spidermonkey")" ]
  for f in $(text_files "$X/spidermonkey"); do
    for p in "$FX_ROOT" "$FX_SRC" "$FX_OBJ" "$FX_CLANG" "$FX_SYSROOT" "$FX_HOME" "$FX_MOZBUILD"; do
      if grep -aqF "$p" "$X/spidermonkey/$f"; then echo "$f contains $p" >&2; return 1; fi
    done
  done
  # The exempt binaries really do embed the workdir: the exemption is exercised.
  grep -aqF "$FX_OBJ" "$X/spidermonkey/lib/libjs_static.a"
}

config_is_rewritten() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract
  python3 - "$FX_DIST/include-private/js-build-config.json" "$X/spidermonkey/include-private/js-build-config.json" <<'PY'
import json, shlex, sys
old = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
assert set(old) == set(new), (sorted(old), sorted(new))
assert new["cc"] == "clang -std=gnu17 --target=wasm32-wasi", new["cc"]
assert new["cxx"] == "clang++ -std=gnu++20 --target=wasm32-wasi", new["cxx"]
assert new["cxx_base_flags"] == ["-fno-exceptions"], new["cxx_base_flags"]
for k in ("ar", "topsrcdir", "topobjdir"):
    assert new[k] == "", (k, new[k])
for k in old:
    if k not in ("cc", "cxx", "cxx_base_flags", "ar", "topsrcdir", "topobjdir"):
        assert new[k] == old[k], k
for k in ("cc", "cxx"):
    for t in shlex.split(new[k]):
        assert "sysroot" not in t, (k, t)
PY
}

# leak_in <relpath> <prefix>: append a line naming <prefix> to the dist file
# <relpath> (following its link, as the producer's file would carry it).
leak_in() {
  printf '// built from %s/x\n' "$2" >>"$FX_DIST/$1"
}

fails_on_leaked_topobjdir() {
  setup
  leak_in include-private/js-confdefs.h "$FX_OBJ"
  run_pkg
  expect_violation include-private/js-confdefs.h
}

fails_on_leaked_topsrcdir_via_link() {
  setup
  leak_in include/js/Value.h "$FX_SRC"
  run_pkg
  expect_violation include/js/Value.h
}

fails_on_leaked_sysroot() {
  setup
  leak_in system_wrappers/stdio.h "$FX_SYSROOT"
  run_pkg
  expect_violation system_wrappers/stdio.h
}

fails_on_leaked_clang_dir() {
  setup
  leak_in include-private/gcc_hidden.h "$FX_CLANG/lib/clang/20/include"
  run_pkg
  expect_violation include-private/gcc_hidden.h
}

fails_on_leaked_home() {
  setup
  leak_in include/mozilla/Types.h "$FX_HOME"
  run_pkg
  expect_violation include/mozilla/Types.h
}

fails_on_leaked_mozbuild_state() {
  setup
  leak_in include-private/jsapi.h "$FX_MOZBUILD"
  run_pkg
  expect_violation include-private/jsapi.h
}

# A config field the rewrite keeps verbatim may not carry a producer path.
fails_on_leak_in_kept_config_field() {
  setup
  python3 - "$FX_DIST/include-private/js-build-config.json" "$FX_SYSROOT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["os_ldflags"].append("-L" + sys.argv[2] + "/lib")
json.dump(c, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  run_pkg
  expect_violation include-private/js-build-config.json
}

fails_on_dangling_symlink() {
  setup
  ln -s "$FX_SRC/js/public/Gone.h" "$FX_DIST/include/js/Gone.h"
  run_pkg
  expect_violation include/js/Gone.h
}

fails_on_symlink_outside() {
  setup
  mkdir -p "$FX_ROOT/elsewhere"
  echo '#define OUTSIDE 1' >"$FX_ROOT/elsewhere/outside.h"
  ln -s "$FX_ROOT/elsewhere/outside.h" "$FX_DIST/include/outside.h"
  run_pkg
  expect_violation include/outside.h
}

fails_on_relative_symlink_outside() {
  setup
  mkdir -p "$FX_ROOT/elsewhere"
  echo '#define OUTSIDE 1' >"$FX_ROOT/elsewhere/outside.h"
  ln -s ../../../../../elsewhere/outside.h "$FX_DIST/include/js/rel-outside.h"
  [ -f "$FX_DIST/include/js/rel-outside.h" ]
  run_pkg
  expect_violation include/js/rel-outside.h
}

fails_on_missing_lib() {
  local lib
  for lib in libjs_static libjsrust libjsshell libpure_virtual; do
    setup
    rm "$FX_DIST/lib/$lib.a"
    run_pkg
    expect_violation "lib/$lib.a"
  done
}

fails_on_missing_opcodes() {
  setup
  rm "$FX_DIST/include-private/vm/Opcodes.h"
  run_pkg
  expect_violation include-private/vm/Opcodes.h
}

fails_on_missing_system_wrappers() {
  setup
  rm -r "$FX_DIST/system_wrappers"
  run_pkg
  expect_violation system_wrappers
}

opcodes_byte_identical() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract
  cmp "$FX_DIST/include-private/vm/Opcodes.h" "$X/spidermonkey/include-private/vm/Opcodes.h"
}

# Two packagings of the same dist, with different file times and umask and a
# hostile tar/zstd/git environment for the second, give the same bytes.
reproducible() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  local first=$OUTDIR
  OUTDIR=$BASE/second.$$
  touch "$FX_DIST/include-private/vm/Opcodes.h" "$FX_SRC/js/src/jsapi.h"
  make_decoy "$BASE/decoy.$$"
  RC=0
  OUT=$(cd "$BASE" && umask 077 && HOME=$FX_HOME MOZBUILD_STATE_PATH=$FX_MOZBUILD PQ_ROOT=$R \
    TAR_OPTIONS=--format=v7 ZSTD_CLEVEL=1 ZSTD_NBTHREADS=4 GIT_DIR="$BASE/decoy.$$/.git" \
    "$PKG" --dist "$FX_DIST" --manifest "$FX_MANIFEST" --out "$OUTDIR" --version 147.0.4 --revision 1 2>&1) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  cmp "$first/$NAME.tar.zst.sha256" "$OUTDIR/$NAME.tar.zst.sha256"
  cmp "$first/$NAME.tar.zst" "$OUTDIR/$NAME.tar.zst"
  cmp "$first/MANIFEST.json" "$OUTDIR/MANIFEST.json"
}

manifest_fields() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract
  local head
  head=$(git -C "$R" rev-parse HEAD)
  (cd "$X/spidermonkey" && find . -type f ! -path ./MANIFEST.json | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 <"$f" | cut -d' ' -f1)" "${f#./}"
  done) >"$BASE/listing.$$"
  python3 - "$OUTDIR/MANIFEST.json" "$FX_MANIFEST" "$head" "$BASE/listing.$$" <<'PY'
import hashlib, json, sys
m = json.load(open(sys.argv[1]))
bm = json.load(open(sys.argv[2]))
for k, v in bm.items():
    if k != "toolchain_artifacts":
        assert m[k] == v, k
assert m["firefox_version"] == "147.0.4", m["firefox_version"]
assert m["queue_commit"] == sys.argv[3], m["queue_commit"]
assert m["package_version"] == "147.0.4-1", m["package_version"]
listing = open(sys.argv[4], "rb").read()
assert m["dist_files"] == {"count": listing.count(b"\n"),
                           "sha256": hashlib.sha256(listing).hexdigest()}, m["dist_files"]
assert m["toolchain"] == [{k: a[k] for k in ("name", "url", "sha256")}
                          for a in bm["toolchain_artifacts"]], m["toolchain"]
for a in m["toolchain"]:
    assert set(a) == {"name", "url", "sha256"}, a
assert any(set(a) - {"name", "url", "sha256"} for a in bm["toolchain_artifacts"]), \
    "fixture has no extra toolchain key: the filter is not exercised"
assert "toolchain_artifacts" not in m, "unfiltered toolchain_artifacts copied"
assert "test_sources" in m
PY
  local p
  for p in "$FX_ROOT" "$FX_SRC" "$FX_OBJ" "$FX_CLANG" "$FX_SYSROOT" "$FX_HOME" "$FX_MOZBUILD"; do
    if grep -qF "$p" "$OUTDIR/MANIFEST.json"; then echo "MANIFEST.json contains $p" >&2; return 1; fi
  done
}

fails_on_manifest_with_producer_path() {
  setup
  python3 - "$FX_MANIFEST" "$FX_MOZBUILD" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["rust_version"] = "rustc 1.98.1 (" + sys.argv[2] + "/rustc)"
json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
  run_pkg
  expect_violation MANIFEST.json
}

refuses_version_not_upstream() {
  setup
  run_pkg --dist "$FX_DIST" --manifest "$FX_MANIFEST" --out "$OUTDIR" --version 148.0 --revision 1
  assert_eq 1 "$RC" "$OUT"
  [ ! -e "$OUTDIR/spidermonkey_148.0-1-wasm32-wasi.tar.zst" ]
}

refuses_existing_output() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  cp "$OUTDIR/$NAME.tar.zst" "$BASE/keep.$$"
  run_pkg
  assert_eq 1 "$RC" "$OUT"
  cmp "$BASE/keep.$$" "$OUTDIR/$NAME.tar.zst"
}

usage_errors() {
  setup
  local good="--dist $FX_DIST --manifest $FX_MANIFEST --out $OUTDIR"
  RC=0; OUT=$("$PKG" 2>&1) || RC=$?
  assert_eq 2 "$RC" "no args: $OUT"
  # shellcheck disable=SC2086 # $good is word-split on purpose (no spaces in BASE)
  {
    run_pkg $good --version 147.0.4; assert_eq 2 "$RC" "no revision: $OUT"
    run_pkg $good --version 147.0.4 --revision 0; assert_eq 2 "$RC" "revision 0: $OUT"
    run_pkg $good --version 'v147' --revision 1; assert_eq 2 "$RC" "bad version: $OUT"
    run_pkg $good --version 147.0.4 --revision 1 --bogus; assert_eq 2 "$RC" "unknown flag: $OUT"
    run_pkg $good --version 147.0.4 --revision; assert_eq 2 "$RC" "flag without value: $OUT"
  }
  run_pkg --dist "$BASE/none" --manifest "$FX_MANIFEST" --out "$OUTDIR" --version 147.0.4 --revision 1
  assert_eq 2 "$RC" "missing dist: $OUT"
}

# contract <function> <args...>: run a package-contract.sh function in a subshell.
contract() (
  # shellcheck source=../scripts/lib/package-contract.sh
  . "$CONTRACT"
  "$@"
)

# release.yml re-runs the contract on the extracted archive through the library.
contract_rechecks_extracted_tree() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  extract
  printf '%s\n' "$FX_SRC" "$FX_OBJ" >"$BASE/prefixes.$$"
  contract pc_check_archive "$OUTDIR/$NAME.tar.zst"
  contract pc_check_tree "$X/spidermonkey" "$BASE/prefixes.$$"
  ln -s include/jsapi.h "$X/spidermonkey/link.h"
  local rc=0 out
  out=$(contract pc_check_tree "$X/spidermonkey" "$BASE/prefixes.$$" 2>&1) || rc=$?
  assert_eq 1 "$rc" "$out"
  case $out in *link.h*) ;; *) echo "symlink not named: $out" >&2; return 1 ;; esac
  rm "$X/spidermonkey/link.h"
  python3 - "$X/spidermonkey/include-private/js-build-config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["cxx"] = "/opt/clang/bin/clang++ -std=gnu++20"
json.dump(c, open(sys.argv[1], "w"))
PY
  rc=0
  out=$(contract pc_check_tree "$X/spidermonkey" "$BASE/prefixes.$$" 2>&1) || rc=$?
  assert_eq 1 "$rc" "$out"
  case $out in *js-build-config.json*) ;; *) echo "config not named: $out" >&2; return 1 ;; esac
}

# A parent directory symlink (dist/lib, include/js) resolving outside the
# producer tree is caught, not only a symlinked file.
fails_on_dir_symlink_outside() {
  setup
  mkdir -p "$FX_ROOT/elsewhere/lib"
  cp -L "$FX_DIST"/lib/*.a "$FX_ROOT/elsewhere/lib/"
  rm -r "${FX_DIST:?}/lib"
  ln -s "$FX_ROOT/elsewhere/lib" "$FX_DIST/lib"
  run_pkg
  expect_violation lib/libjs_static.a
  setup
  mkdir -p "$FX_ROOT/elsewhere/js"
  echo '#define V 1' >"$FX_ROOT/elsewhere/js/Value.h"
  rm -r "$FX_DIST/include/js"
  ln -s "$FX_ROOT/elsewhere/js" "$FX_DIST/include/js"
  run_pkg
  expect_violation include/js
}

# edit_config <python statements on c>: rewrite the dist's js-build-config.json
# (json.dump defaults, so non-ASCII is \u-escaped as the 0009 writer leaves it).
edit_config() {
  python3 - "$FX_DIST/include-private/js-build-config.json" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(c, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
}

# A producer root that is a broad system directory cannot be scanned for;
# refuse it instead of silently not scanning.
refuses_broad_producer_root() {
  local root
  for root in /usr /opt /usr/local /; do
    setup
    S=$root edit_config 'import os; s = os.environ["S"]
c["cc"] = "%s/bin/clang --sysroot=%s -std=gnu17" % ("'"$FX_CLANG"'", s)'
    run_pkg
    expect_violation include-private/js-build-config.json
    case $OUT in *broad*) ;; *) echo "no broad-root message for $root: $OUT" >&2; return 1 ;; esac
  done
  setup
  edit_config 'c["topobjdir"] = "/usr"'
  run_pkg
  expect_violation include-private/js-build-config.json
}

# A non-ASCII producer path is found though json.dump writes it \u-escaped.
fails_on_non_ascii_leak_in_json() {
  setup
  local s
  s="$FX_ROOT/tc/"$'\xc3\xa9'"-sysroot"
  S=$s edit_config 'import os; s = os.environ["S"]
c["cc"] = "clang --sysroot=%s -std=gnu17" % s
c["cxx"] = "clang++ --sysroot %s -std=gnu++20" % s
c["cxx_base_flags"] = ["--sysroot", s]
c["os_ldflags"].append("-L%s/lib" % s)'
  run_pkg
  expect_violation include-private/js-build-config.json
  # The library alone, on a tree whose JSON carries the escaped form.
  mkdir -p "$BASE/esc.$$"
  python3 -c 'import json, sys; json.dump({"x": sys.argv[1] + "/y"}, open(sys.argv[2], "w"))' \
    "$s" "$BASE/esc.$$/MANIFEST.json"
  grep -q 'u00e9' "$BASE/esc.$$/MANIFEST.json"
  printf '%s\n' "$s" >"$BASE/esc-prefix.$$"
  local rc=0 out
  out=$(contract pc_check_tree "$BASE/esc.$$" "$BASE/esc-prefix.$$" 2>&1) || rc=$?
  assert_eq 1 "$rc" "$out"
  case $out in *"MANIFEST.json: contains producer path"*) ;; *) echo "escaped leak not found: $out" >&2; return 1 ;; esac
}

# Path-valued config fields CMake joins onto SPIDERMONKEY_DIST must stay inside.
fails_on_escaping_config_path() {
  local edit
  for edit in 'c["include_dirs"].append("../../etc")' 'c["libraries"].append("lib/../../x.a")' \
    'c["force_includes"].append("../x.h")' 'c["include_dirs"].append("/etc")'; do
    setup
    edit_config "$edit"
    run_pkg
    expect_violation include-private/js-build-config.json
    case $OUT in *include_dirs* | *libraries* | *force_includes*) ;; *)
      echo "field not named for $edit: $OUT" >&2; return 1 ;; esac
  done
}

# make_archive <out.tar.zst> <kind>: a hand-made archive with one bad member.
make_archive() {
  python3 - "$1.tar" "$2" <<'PY'
import io, sys, tarfile
out, kind = sys.argv[1:]
with tarfile.open(out, "w", format=tarfile.GNU_FORMAT) as t:
    d = tarfile.TarInfo("spidermonkey"); d.type = tarfile.DIRTYPE; t.addfile(d)
    f = tarfile.TarInfo("spidermonkey/ok.h"); f.size = 1; t.addfile(f, io.BytesIO(b"x"))
    m = tarfile.TarInfo({"abs": "/etc/evil", "dotdot": "spidermonkey/../evil",
                         "other": "other/evil", "symlink": "spidermonkey/link",
                         "hardlink": "spidermonkey/hard"}[kind])
    if kind == "symlink":
        m.type, m.linkname = tarfile.SYMTYPE, "/etc/passwd"
    elif kind == "hardlink":
        m.type, m.linkname = tarfile.LNKTYPE, "spidermonkey/ok.h"
    t.addfile(m, io.BytesIO(b"") if m.isreg() else None)
PY
  zstd -q -f "$1.tar" -o "$1"
}

contract_rejects_bad_archive_members() {
  local kind rc out
  for kind in abs dotdot other symlink hardlink; do
    make_archive "$BASE/bad-$kind.$$.tar.zst" "$kind"
    rc=0
    out=$(contract pc_check_archive "$BASE/bad-$kind.$$.tar.zst" 2>&1) || rc=$?
    assert_eq 1 "$rc" "$kind: $out"
    case $kind:$out in
      abs:*"/etc/evil: outside spidermonkey/"* | dotdot:*"spidermonkey/../evil: outside spidermonkey/"* | \
        other:*"other/evil: outside spidermonkey/"* | \
        symlink:*"spidermonkey/link: not a regular file or directory"* | \
        hardlink:*"spidermonkey/hard: not a regular file or directory"*) ;;
      *) echo "$kind: unexpected message: $out" >&2; return 1 ;;
    esac
  done
}

# Members are in --sort=name order: each directory's entries byte-sorted,
# depth first, so the order does not depend on the filesystem's readdir.
archive_members_sorted() {
  setup
  run_pkg
  assert_eq 0 "$RC" "$OUT"
  zstd -dc "$OUTDIR/$NAME.tar.zst" | python3 -c '
import sys, tarfile
names = [m.name.rstrip("/") for m in tarfile.open(fileobj=sys.stdin.buffer, mode="r|")]
tree = {}
for n in names:
    parent, _, base = n.rpartition("/")
    tree.setdefault(parent, []).append(base)
want = []
def walk(d):
    for b in sorted(tree.get(d, []), key=lambda s: s.encode()):
        p = d + "/" + b if d else b
        want.append(p)
        walk(p)
walk("")
assert names == want, "\n".join(names)
assert len(names) > 10, names
'
}

# Without GNU tar or zstd the suite SKIPs locally but is FATAL under CI.
missing_tools_fatal_on_ci() {
  local d=$BASE/notools.$$ t rc out
  mkdir -p "$d"
  for t in bash dirname mktemp rm grep; do ln -s "$(command -v "$t")" "$d/$t"; done
  rc=0
  out=$(env -i PATH="$d" HOME="$BASE" "$d/bash" "$ROOT/tests/test-package-engine.sh" 2>&1) || rc=$?
  assert_eq 0 "$rc" "local: $out"
  case $out in *SKIP*) ;; *) echo "no SKIP locally: $out" >&2; return 1 ;; esac
  for t in CI=true GITHUB_ACTIONS=true; do
    rc=0
    out=$(env -i PATH="$d" HOME="$BASE" "$t" "$d/bash" "$ROOT/tests/test-package-engine.sh" 2>&1) || rc=$?
    assert_eq 1 "$rc" "$t: $out"
    case $out in *FATAL*) ;; *) echo "no FATAL under $t: $out" >&2; return 1 ;; esac
  done
}

if ! have_gnu_tar || ! command -v zstd >/dev/null 2>&1; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "FATAL test-package-engine.sh: GNU tar (tar or gtar) and zstd are required on CI and were not found" >&2
    exit 1
  fi
  echo "SKIP test-package-engine.sh: GNU tar (tar or gtar) and zstd are required and were not found; no package case ran"
  exit 0
fi

run_test "packages a relocatable tree" packages_relocatable_tree
run_test "no producer prefix in text files" no_producer_prefix_in_text_files
run_test "config is rewritten" config_is_rewritten
run_test "fails on leaked topobjdir" fails_on_leaked_topobjdir
run_test "fails on leaked topsrcdir via link" fails_on_leaked_topsrcdir_via_link
run_test "fails on leaked sysroot" fails_on_leaked_sysroot
run_test "fails on leaked clang dir" fails_on_leaked_clang_dir
run_test "fails on leaked HOME" fails_on_leaked_home
run_test "fails on leaked MOZBUILD_STATE_PATH" fails_on_leaked_mozbuild_state
run_test "fails on leak in kept config field" fails_on_leak_in_kept_config_field
run_test "fails on dangling symlink" fails_on_dangling_symlink
run_test "fails on symlink outside" fails_on_symlink_outside
run_test "fails on relative symlink outside" fails_on_relative_symlink_outside
run_test "fails on missing lib" fails_on_missing_lib
run_test "fails on missing Opcodes.h" fails_on_missing_opcodes
run_test "fails on missing system_wrappers" fails_on_missing_system_wrappers
run_test "Opcodes.h byte-identical" opcodes_byte_identical
run_test "reproducible" reproducible
run_test "manifest fields" manifest_fields
run_test "fails on manifest with producer path" fails_on_manifest_with_producer_path
run_test "refuses version not in UPSTREAM" refuses_version_not_upstream
run_test "refuses existing output" refuses_existing_output
run_test "usage errors" usage_errors
run_test "contract rechecks extracted tree" contract_rechecks_extracted_tree
run_test "fails on directory symlink outside" fails_on_dir_symlink_outside
run_test "refuses broad producer root" refuses_broad_producer_root
run_test "fails on non-ASCII leak in JSON" fails_on_non_ascii_leak_in_json
run_test "fails on escaping config path" fails_on_escaping_config_path
run_test "contract rejects bad archive members" contract_rejects_bad_archive_members
run_test "archive members sorted" archive_members_sorted
run_test "missing tools fatal on CI" missing_tools_fatal_on_ci
finish
