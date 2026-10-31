#!/usr/bin/env bash
# Assemble, finalize and verify an engine release set (release.yml).
#
#   release-set.sh prepare --package-out DIR --version V --revision N --work DIR
#     accept job, before the acceptance run. DIR is engine.yml's package-out/
#     (spidermonkey_V-N-{wasm32-wasi,testsrc,jstests}.tar.zst, their .sha256,
#     MANIFEST.json). Checks, in order, failing closed:
#       - each archive matches its .sha256, MANIFEST.json's package_version is
#         V-N, its test_sources name and digest are the bundles' (jstests is
#         required: every release ships it);
#       - every member of each archive is a regular file or directory under
#         its root (pc_check_archive);
#       - the extracted engine passes the Y1 contract (pc_check_tree): the
#         producer paths are blank in its config by now, so the prefixes
#         scanned for are this runner's $HOME and $GITHUB_WORKSPACE, which on
#         a hosted runner are the build job's too; its files match
#         MANIFEST.json's dist_files and its MANIFEST.json is package-out's;
#       - the toolchains are mirrored verbatim: MANIFEST.json's toolchain list
#         must be exactly clang.tar.zst and sysroot-wasm32-wasi.tar.zst with
#         https URLs; each is downloaded (curl --retry 3), must match the
#         sha256 recorded at build time, and is copied unchanged into the set
#         as spidermonkey_V-N-toolchain-{clang,sysroot}.tar.zst;
#       - each archive is a single top-level directory (Mozilla's: clang/,
#         sysroot-wasm32-wasi/); clang's holds executable bin/clang and
#         bin/clang++, the sysroot's include/;
#       - every asset is at most 1.9 GiB (2040109465 bytes, a GitHub release
#         asset's cap; RELEASE_SET_MAX_BYTES may lower it, never raise it).
#     Then writes <work>/package (holds spidermonkey/), <work>/testsrc (both
#     bundles), <work>/toolchain/<top> (never ~/.mozbuild) and
#     <work>/release-set (the five archives and their .sha256), and prints
#     package=, testsrc=, toolchain_root=, sysroot= (also to $GITHUB_OUTPUT).
#     <work> must not exist or be empty.
#
#   release-set.sh finalize --work DIR --tag TAG
#     accept job, after the acceptance run: writes <work>/release-set/
#     MANIFEST.json, package-out's manifest plus release: {tag, assets: [{name,
#     sha256, size, mirror_of (toolchains)}]}, and prints manifest_sha256=
#     (also to $GITHUB_OUTPUT), which publish checks against. TAG must be
#     engine-v<package_version>.
#
#   release-set.sh verify --dir DIR --manifest-sha256 H --version V --revision N
#     publish job: DIR holds exactly the ten asset files and MANIFEST.json;
#     MANIFEST.json's sha256 is H (accept's job output, so an artifact swapped
#     after accept is caught even with a self-consistent manifest); every
#     asset's digest and size are the manifest's and its .sha256 agrees.
#
# Needs GNU tar (tar or gtar), zstd, curl (prepare) and python3.
# Exit codes: 0 ok; 1 refused or failed (the message names the file); 2 usage.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/package-contract.sh
. "$SELF/scripts/lib/package-contract.sh"

CAP_DEFAULT=2040109465

usage() {
  [ $# -eq 0 ] || echo "release-set: $*" >&2
  echo "usage: release-set.sh prepare --package-out DIR --version V --revision N --work DIR" >&2
  echo "       release-set.sh finalize --work DIR --tag TAG" >&2
  echo "       release-set.sh verify --dir DIR --manifest-sha256 H --version V --revision N" >&2
  exit 2
}
die() { echo "release-set: $*" >&2; exit 1; }

# emit <key=value>...: print, and append to $GITHUB_OUTPUT when set.
emit() {
  local kv
  for kv in "$@"; do
    printf '%s\n' "$kv"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      printf '%s\n' "$kv" >>"$GITHUB_OUTPUT"
    fi
  done
}

[ $# -ge 1 ] || usage
cmd=$1
shift
package_out= version= revision= work= tag= dir= expected=
while [ $# -gt 0 ]; do
  case $1 in
    --package-out | --version | --revision | --work | --tag | --dir | --manifest-sha256)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --package-out) package_out=$2 ;;
        --version) version=$2 ;;
        --revision) revision=$2 ;;
        --work) work=$2 ;;
        --tag) tag=$2 ;;
        --dir) dir=$2 ;;
        --manifest-sha256) expected=$2 ;;
      esac
      shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

export LC_ALL=C
umask 022
unset TAR_OPTIONS ZSTD_CLEVEL ZSTD_NBTHREADS

check_version() {
  [[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || usage "bad version: '$version'"
  [[ $revision =~ ^[1-9][0-9]*$ ]] || usage "bad revision: '$revision'"
}

prepare() {
  [ -n "$package_out" ] && [ -n "$work" ] || usage "prepare needs --package-out and --work"
  check_version
  [ -d "$package_out" ] || usage "no such directory: $package_out"
  local cap=$CAP_DEFAULT
  if [ -n "${RELEASE_SET_MAX_BYTES:-}" ]; then
    [[ $RELEASE_SET_MAX_BYTES =~ ^[0-9]+$ ]] && [ "$RELEASE_SET_MAX_BYTES" -le "$CAP_DEFAULT" ] ||
      usage "RELEASE_SET_MAX_BYTES may only lower the $CAP_DEFAULT-byte cap"
    cap=$RELEASE_SET_MAX_BYTES
  fi
  if [ -e "$work" ] && [ -n "$(ls -A "$work" 2>/dev/null)" ]; then
    die "$work exists and is not empty"
  fi
  mkdir -p "$work"
  work=$(cd "$work" && pwd -P)
  package_out=$(cd "$package_out" && pwd -P)
  local TAR p=spidermonkey_$version-$revision
  TAR=$(pc_gnu_tar) || exit 1
  command -v zstd >/dev/null 2>&1 || die "zstd is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  mkdir -p "$work/package" "$work/testsrc" "$work/toolchain" "$work/download" "$work/set.tmp"

  # Package-out: digests, manifest, sizes. toolchains.json lists what to fetch.
  python3 -I - "$package_out" "$p" "$version-$revision" "$version" "$cap" "$work" <<'PY' || exit 1
import hashlib, json, os, re, sys
po, p, pv, version, cap, work = sys.argv[1:]
cap = int(cap)
errors = []
def fail(name, why):
    errors.append("release-set: %s: %s" % (name, why))
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
digests = {}
for kind in ("wasm32-wasi", "testsrc", "jstests"):
    name = "%s-%s.tar.zst" % (p, kind)
    a, s = os.path.join(po, name), os.path.join(po, name + ".sha256")
    if not os.path.isfile(a) or not os.path.isfile(s):
        fail(name, "missing from package-out (every release ships the %s bundle)" % kind)
        continue
    d = sha(a)
    m = re.fullmatch(r"([0-9a-f]{64})  (\S+)\n?", open(s).read())
    if not m or m.group(2) != name or m.group(1) != d:
        fail(name, "sha256 %s does not match %s.sha256" % (d, name))
    if os.path.getsize(a) > cap:
        fail(name, "%d bytes exceeds the %d-byte release asset cap" % (os.path.getsize(a), cap))
    digests[kind] = d
mpath = os.path.join(po, "MANIFEST.json")
try:
    man = json.load(open(mpath))
except (OSError, ValueError) as e:
    sys.exit("release-set: MANIFEST.json: unreadable: %s" % e)
if man.get("package_version") != pv:
    fail("MANIFEST.json", "package_version %r is not %r" % (man.get("package_version"), pv))
if man.get("firefox_version") != version:
    fail("MANIFEST.json", "firefox_version %r is not %r" % (man.get("firefox_version"), version))
ts = man.get("test_sources") or {}
for kind in ("testsrc", "jstests"):
    e = ts.get(kind) or {}
    name = "%s-%s.tar.zst" % (p, kind)
    if e.get("name") != name or (kind in digests and e.get("sha256") != digests[kind]):
        fail("MANIFEST.json", "test_sources.%s %r does not name %s with its sha256" % (kind, e, name))
# The explicit toolchain mapping: recorded name -> asset.
mapping = {"clang.tar.zst": "toolchain-clang", "sysroot-wasm32-wasi.tar.zst": "toolchain-sysroot"}
tcs = man.get("toolchain") or []
names = sorted(t.get("name") for t in tcs if isinstance(t, dict))
if names != sorted(mapping):
    fail("MANIFEST.json", "toolchain must be exactly %s, got %r" % (sorted(mapping), names))
plan = []
for t in tcs:
    if not isinstance(t, dict) or t.get("name") not in mapping:
        continue
    url, digest = t.get("url"), t.get("sha256")
    if not isinstance(url, str) or not url.startswith("https://") or any(c.isspace() for c in url):
        fail("MANIFEST.json", "toolchain %s url %r is not an https URL" % (t["name"], url))
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("MANIFEST.json", "toolchain %s sha256 %r is not a sha256" % (t["name"], digest))
    plan.append({"name": t["name"], "url": url, "sha256": digest,
                 "asset": "%s-%s.tar.zst" % (p, mapping[t["name"]])})
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
json.dump(plan, open(os.path.join(work, "toolchains.json"), "w"), indent=2)
PY

  # Archive members, then the engine and the test sources, extracted.
  pc_check_archive "$package_out/$p-wasm32-wasi.tar.zst" spidermonkey || die "$p-wasm32-wasi.tar.zst: bad members"
  pc_check_archive "$package_out/$p-testsrc.tar.zst" js || die "$p-testsrc.tar.zst: bad members"
  pc_check_archive "$package_out/$p-jstests.tar.zst" js xul-info.txt || die "$p-jstests.tar.zst: bad members"
  zstd -q -dc "$package_out/$p-wasm32-wasi.tar.zst" | "$TAR" -xf - -C "$work/package" ||
    die "$p-wasm32-wasi.tar.zst: extraction failed"
  local a
  for a in testsrc jstests; do
    zstd -q -dc "$package_out/$p-$a.tar.zst" | "$TAR" -xf - -C "$work/testsrc" || die "$p-$a.tar.zst: extraction failed"
  done
  [ -f "$work/testsrc/js/src/jit-test/jit_test.py" ] || die "$p-testsrc.tar.zst: no js/src/jit-test/jit_test.py"
  [ -f "$work/testsrc/xul-info.txt" ] || die "$p-jstests.tar.zst: no xul-info.txt"

  # The Y1 contract on the extracted engine, with this runner's paths.
  local prefixes=$work/prefixes v
  : >"$prefixes"
  for v in "${HOME:-}" "${GITHUB_WORKSPACE:-}"; do
    case $v in /?*) printf '%s\n' "${v%/}" >>"$prefixes" ;; esac
  done
  pc_check_tree "$work/package/spidermonkey" "$prefixes" || die "$p-wasm32-wasi.tar.zst: violates the package contract"
  cmp -s "$work/package/spidermonkey/MANIFEST.json" "$package_out/MANIFEST.json" ||
    die "MANIFEST.json: the archive's differs from package-out's"
  python3 -I - "$work/package/spidermonkey" "$package_out/MANIFEST.json" <<'PY' || exit 1
import hashlib, json, os, sys
tree, mpath = sys.argv[1:]
files = sorted(os.path.relpath(os.path.join(d, n), tree).encode()
               for d, _, names in os.walk(tree) for n in names)
lines = []
for rel in files:
    if rel == b"MANIFEST.json":
        continue
    with open(os.path.join(tree, rel.decode()), "rb") as f:
        lines.append("%s  %s\n" % (hashlib.sha256(f.read()).hexdigest(), rel.decode()))
listing = "".join(lines).encode()
got = {"count": len(lines), "sha256": hashlib.sha256(listing).hexdigest()}
want = json.load(open(mpath)).get("dist_files")
if got != want:
    sys.exit("release-set: MANIFEST.json: dist_files %r does not match the extracted engine %r" % (want, got))
PY

  # Toolchains: download, verify, check layout, extract, mirror.
  local n name url digest asset got size top
  n=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$work/toolchains.json")
  local i=0 toolchain_root= sysroot=
  while [ "$i" -lt "$n" ]; do
    name=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["name"])' "$work/toolchains.json" "$i")
    url=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["url"])' "$work/toolchains.json" "$i")
    digest=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["sha256"])' "$work/toolchains.json" "$i")
    asset=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["asset"])' "$work/toolchains.json" "$i")
    i=$((i + 1))
    if ! curl --retry 3 -fsSL -o "$work/download/$name" "$url"; then
      die "$name: download failed from $url"
    fi
    got=$(pc_sha256_line "$work/download/$name")
    got=${got%% *}
    [ "$got" = "$digest" ] || die "$name: sha256 $got is not the recorded $digest"
    size=$(wc -c <"$work/download/$name" | tr -d ' ')
    [ "$size" -le "$cap" ] || die "$name: $size bytes exceeds the $cap-byte release asset cap"
    top=$(zstd -q -dc "$work/download/$name" | python3 -I -c '
import sys, tarfile
tops, dirs = set(), set()
for m in tarfile.open(fileobj=sys.stdin.buffer, mode="r|"):
    parts = [x for x in m.name.split("/") if x not in ("", ".")]
    if not parts or m.name.startswith("/") or ".." in parts:
        sys.exit("bad member %r" % m.name)
    tops.add(parts[0])
    if len(parts) == 1 and m.isdir():
        dirs.add(parts[0])
    if len(parts) > 1:
        dirs.add(parts[0])
if len(tops) != 1:
    sys.exit("%d top-level entries %s, want one directory" % (len(tops), sorted(tops)))
top = tops.pop()
if top not in dirs:
    sys.exit("top-level entry %r is not a directory" % top)
print(top)
') || die "$name: layout: $top"
    [ -n "$top" ] || die "$name: no top-level directory"
    [ ! -e "$work/toolchain/$top" ] || die "$name: top-level directory $top clashes with another toolchain"
    zstd -q -dc "$work/download/$name" | "$TAR" -xf - -C "$work/toolchain" || die "$name: extraction failed"
    case $name in
      clang.tar.zst)
        [ -x "$work/toolchain/$top/bin/clang" ] && [ -x "$work/toolchain/$top/bin/clang++" ] ||
          die "$name: $top/bin/clang and $top/bin/clang++ must be executables"
        toolchain_root=$work/toolchain/$top ;;
      sysroot-wasm32-wasi.tar.zst)
        [ -d "$work/toolchain/$top/include" ] || die "$name: $top/include is missing"
        sysroot=$work/toolchain/$top ;;
    esac
    cp "$work/download/$name" "$work/set.tmp/$asset"
  done
  [ -n "$toolchain_root" ] && [ -n "$sysroot" ] || die "toolchain: clang and sysroot not both found"

  for a in wasm32-wasi testsrc jstests; do
    cp "$package_out/$p-$a.tar.zst" "$work/set.tmp/"
  done
  for a in wasm32-wasi testsrc jstests toolchain-clang toolchain-sysroot; do
    pc_sha256_line "$work/set.tmp/$p-$a.tar.zst" >"$work/set.tmp/$p-$a.tar.zst.sha256" || die "cannot hash $p-$a.tar.zst"
  done
  cp "$package_out/MANIFEST.json" "$work/package-manifest.json"
  mv "$work/set.tmp" "$work/release-set"
  rm -rf "$work/download"
  emit "package=$work/package" "testsrc=$work/testsrc" "toolchain_root=$toolchain_root" "sysroot=$sysroot"
}

finalize() {
  [ -n "$work" ] && [ -n "$tag" ] || usage "finalize needs --work and --tag"
  [ -d "$work/release-set" ] && [ -f "$work/package-manifest.json" ] && [ -f "$work/toolchains.json" ] ||
    die "$work is not a prepared work directory (run prepare first)"
  [ ! -e "$work/release-set/MANIFEST.json" ] || die "$work/release-set/MANIFEST.json exists; finalize runs once"
  python3 -I - "$work" "$tag" <<'PY' || exit 1
import hashlib, json, os, sys
work, tag = sys.argv[1:]
d = os.path.join(work, "release-set")
m = json.load(open(os.path.join(work, "package-manifest.json")))
if tag != "engine-v" + str(m.get("package_version")):
    sys.exit("release-set: tag %r is not engine-v%s" % (tag, m.get("package_version")))
mirrors = {t["asset"]: t["url"] for t in json.load(open(os.path.join(work, "toolchains.json")))}
assets = []
for name in sorted(os.listdir(d)):
    if not name.endswith(".tar.zst"):
        continue
    data = open(os.path.join(d, name), "rb").read()
    a = {"name": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    if name in mirrors:
        a["mirror_of"] = mirrors[name]
    assets.append(a)
m["release"] = {"tag": tag, "assets": assets}
with open(os.path.join(d, "MANIFEST.json"), "x") as f:
    json.dump(m, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  local h
  h=$(pc_sha256_line "$work/release-set/MANIFEST.json")
  emit "manifest_sha256=${h%% *}"
}

verify() {
  [ -n "$dir" ] || usage "verify needs --dir"
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || usage "--manifest-sha256 must be a sha256, got '$expected'"
  check_version
  [ -d "$dir" ] || usage "no such directory: $dir"
  python3 -I - "$dir" "$expected" "spidermonkey_$version-$revision" "$version-$revision" <<'PY'
import hashlib, json, os, re, sys
d, expected, p, pv = sys.argv[1:]
kinds = ("wasm32-wasi", "testsrc", "jstests", "toolchain-clang", "toolchain-sysroot")
archives = ["%s-%s.tar.zst" % (p, k) for k in kinds]
want = sorted(archives + [a + ".sha256" for a in archives] + ["MANIFEST.json"])
have = sorted(os.listdir(d))
if have != want:
    sys.exit("release-set: %s holds %s; want exactly %s" % (d, have, want))
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
got = sha(os.path.join(d, "MANIFEST.json"))
if got != expected:
    sys.exit("release-set: MANIFEST.json: sha256 %s is not %s, the digest accept recorded" % (got, expected))
m = json.load(open(os.path.join(d, "MANIFEST.json")))
if m.get("package_version") != pv:
    sys.exit("release-set: MANIFEST.json: package_version %r is not %r" % (m.get("package_version"), pv))
recorded = {a.get("name"): a for a in (m.get("release") or {}).get("assets", [])}
if sorted(recorded) != sorted(archives):
    sys.exit("release-set: MANIFEST.json: release.assets %s is not %s" % (sorted(recorded), sorted(archives)))
bad = []
for name in archives:
    path = os.path.join(d, name)
    digest, size = sha(path), os.path.getsize(path)
    a = recorded[name]
    if a.get("sha256") != digest or a.get("size") != size:
        bad.append("%s: sha256 %s / %d bytes, MANIFEST.json says %s / %s" % (name, digest, size, a.get("sha256"), a.get("size")))
    if open(path + ".sha256").read() != "%s  %s\n" % (digest, name):
        bad.append("%s.sha256: does not hold %s" % (name, digest))
if bad:
    sys.exit("release-set: " + "\nrelease-set: ".join(bad))
print("release-set: verified %d assets against MANIFEST.json %s" % (len(archives), expected))
PY
}

case $cmd in
  prepare) prepare ;;
  finalize) finalize ;;
  verify) verify ;;
  *) usage "unknown subcommand: $cmd" ;;
esac
