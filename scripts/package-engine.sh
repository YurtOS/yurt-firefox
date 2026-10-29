#!/usr/bin/env bash
# Package a queue-built SpiderMonkey dist/ as a relocatable engine archive.
#   package-engine.sh --dist DIR --manifest build-manifest.json --out DIR
#                     --version V --revision N [--test-sources DIR]
# writes <out>/spidermonkey_V-N-wasm32-wasi.tar.zst, its .sha256 (sha256sum
# format) and MANIFEST.json (the copy inside the archive). V must be the
# Firefox version of UPSTREAM's tag (FIREFOX_147_0_4_RELEASE -> 147.0.4) and of
# the build manifest; N is a positive integer. Existing outputs are refused.
#
# The archive's top directory is `spidermonkey/` (passed to NightMonkey as
# SPIDERMONKEY_DIST): include/, include-private/, system_wrappers/,
# lib/{libjs_static,libjsrust,libjsshell,libpure_virtual}.a, bin/js and
# MANIFEST.json; nothing else of the dist (host/, idl/, ...) is taken.
#
# 1. Materialize: every entry is copied by following its symlink (absolute or
#    relative). A dangling symlink, or any entry whose realpath (through a
#    symlinked file or parent directory) is outside the dist, topsrcdir and
#    topobjdir, fails here naming the entry.
# 2. Rewrite include-private/js-build-config.json: argv0 of cc and cxx becomes
#    bare `clang` and `clang++`; `--sysroot X`, `--sysroot=X` and `-isysroot X`
#    are dropped from cc, cxx and cxx_base_flags; ar, topsrcdir and topobjdir
#    become "". Every other field is kept verbatim.
# 3. MANIFEST.json: the build manifest's fields (toolchain_artifacts replaced
#    by the filtered toolchain below) plus firefox_version,
#    queue_commit (this repository's HEAD), dist_files (count and sha256 of the
#    "<sha256>  <relpath>" lines of the package sorted by path, MANIFEST.json
#    excluded),
#    package_version (V-N), toolchain (name, url, sha256 of each recorded
#    toolchain artifact) and test_sources: with --test-sources DIR (the --out
#    directory of scripts/package-test-sources.sh), {"testsrc": {name,
#    sha256}, "jstests": {name, sha256} or null} for
#    spidermonkey_V-N-{testsrc,jstests}.tar.zst. Each present bundle needs its
#    archive and a one-line "<sha256>  <name>" .sha256 naming it, whose digest
#    the archive must match; testsrc is required, jstests optional. Without
#    the flag test_sources is null.
# 4. Contract (scripts/lib/package-contract.sh) on the package tree, Opcodes.h
#    byte-identical to the dist's, then a deterministic archive (GNU tar
#    --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner, zstd -T1)
#    whose member list is checked again. The archive bytes are reproducible for
#    a given GNU tar and zstd version; zstd level 10 output may differ between
#    zstd releases, so compare digests made with the same zstd.
#
# Hermetic like pq_git: paths are resolved up front (no reliance on the cwd),
# LC_ALL, umask, TAR_OPTIONS and ZSTD_* are fixed, git runs through pq_git and
# python3 runs isolated. Needs GNU tar (`tar`, else `gtar`), zstd and python3.
# PQ_ROOT overrides the repository root (tests use it).
# Exit codes: 0 ok, 1 contract violation or failure (the message names the
# file), 2 usage.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"
# shellcheck source=lib/package-contract.sh
. "$SELF/scripts/lib/package-contract.sh"

usage() {
  [ $# -eq 0 ] || echo "package-engine: $*" >&2
  echo "usage: package-engine.sh --dist DIR --manifest build-manifest.json --out DIR --version V --revision N [--test-sources DIR]" >&2
  exit 2
}
die() { echo "package-engine: $*" >&2; exit 1; }

dist= manifest= out= version= revision= test_sources=
while [ $# -gt 0 ]; do
  case $1 in
    --dist | --manifest | --out | --version | --revision | --test-sources)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --test-sources) test_sources=$2 ;;
        --dist) dist=$2 ;;
        --manifest) manifest=$2 ;;
        --out) out=$2 ;;
        --version) version=$2 ;;
        --revision) revision=$2 ;;
      esac
      shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$dist" ] && [ -n "$manifest" ] && [ -n "$out" ] && [ -n "$version" ] && [ -n "$revision" ] ||
  usage "all of --dist --manifest --out --version --revision are required"
[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || usage "bad version: $version"
[[ $revision =~ ^[1-9][0-9]*$ ]] || usage "bad revision: $revision"
[ -d "$dist" ] || usage "no such directory: $dist"
[ -f "$manifest" ] || usage "no such file: $manifest"
[ -z "$test_sources" ] || [ -d "$test_sources" ] || usage "no such directory: $test_sources"

export LC_ALL=C
umask 022
unset TAR_OPTIONS ZSTD_CLEVEL ZSTD_NBTHREADS
pq_git_env || exit 1

dist=$(cd "$dist" && pwd -P)
manifest=$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
[ -z "$test_sources" ] || test_sources=$(cd "$test_sources" && pwd -P)

name=spidermonkey_$version-$revision-wasm32-wasi
archive=$out/$name.tar.zst
for f in "$archive" "$archive.sha256" "$out/MANIFEST.json"; do
  if [ -e "$f" ] || [ -L "$f" ]; then die "$f exists; move it away first"; fi
done

TAR=$(pc_gnu_tar) || exit 1
command -v zstd >/dev/null 2>&1 || die "zstd is required"

config=$dist/include-private/js-build-config.json
[ -f "$config" ] || die "include-private/js-build-config.json: missing from $dist"

pq_read_pin "$ROOT/UPSTREAM" || exit 1
firefox_version=$(pc_firefox_version "$PQ_TAG") || exit 1
[ "$version" = "$firefox_version" ] ||
  die "--version $version is not UPSTREAM's Firefox version $firefox_version"
queue_commit=$(pq_git -C "$ROOT" rev-parse --verify 'HEAD^{commit}') || die "cannot read HEAD of $ROOT"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/stage/spidermonkey
pc_prefixes "$config" >"$work/prefixes" || exit 1

echo "package-engine: materialize $dist"
python3 -I - "$dist" "$stage" "$manifest" "$PQ_TAG" "$firefox_version" "$queue_commit" \
  "$version-$revision" "$PC_LIBS" "$test_sources" <<'PY' || exit 1
import hashlib, json, os, re, shlex, shutil, stat, sys

(dist, stage, manifest_path, tag, ff_version, queue_commit, package_version, libs,
 ts_dir) = sys.argv[1:]
errors = []


def fail(rel, why):
    errors.append("package-engine: %s: %s" % (rel, why))


with open(os.path.join(dist, "include-private", "js-build-config.json")) as f:
    cfg = json.load(f)
roots = [os.path.realpath(dist)]
for key in ("topsrcdir", "topobjdir"):
    if isinstance(cfg.get(key), str) and os.path.isabs(cfg[key]):
        roots.append(os.path.realpath(cfg[key]))


def inside(p):
    return any(p == r or p.startswith(r + "/") for r in roots)


def copy(src, rel, dst, active):
    """Copy src (dist entry `rel`) to dst, following symlinks. The realpath of
    every entry is checked, so a symlinked parent directory (dist/lib ->
    elsewhere) cannot carry its files past the containment check."""
    target = os.path.realpath(src)
    if not os.path.exists(target):
        return fail(rel, "dangling symlink -> %s" % (os.readlink(src) if os.path.islink(src) else target))
    if not inside(target):
        return fail(rel, "resolves outside the dist, topsrcdir and topobjdir: %s" % target)
    src = target
    st = os.stat(src)
    if stat.S_ISDIR(st.st_mode):
        real = os.path.realpath(src)
        if real in active:
            return fail(rel, "symlink cycle")
        os.makedirs(dst, exist_ok=True)
        os.chmod(dst, 0o755)
        for name in sorted(os.listdir(src)):
            copy(os.path.join(src, name), rel + "/" + name, os.path.join(dst, name), active | {real})
    elif stat.S_ISREG(st.st_mode):
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o755 if st.st_mode & 0o111 else 0o644)
    else:
        fail(rel, "not a regular file or directory")


os.makedirs(stage)
os.chmod(stage, 0o755)
entries = ["include", "include-private", "system_wrappers", "bin/js"] + \
    ["lib/%s.a" % l for l in libs.split()]
for rel in entries:
    src = os.path.join(dist, rel)
    if not os.path.lexists(src):
        continue  # the contract check names what is missing
    parent = os.path.dirname(os.path.join(stage, rel))
    os.makedirs(parent, exist_ok=True)
    os.chmod(parent, 0o755)
    copy(src, rel, os.path.join(stage, rel), frozenset())
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)


# Config rewrite.
def strip(tokens, key):
    out, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in ("--sysroot", "-isysroot"):
            if i + 1 >= len(tokens):
                fail("include-private/js-build-config.json", "%s: %s without a value" % (key, t))
            i += 2
            continue
        if t.startswith("--sysroot=") or t.startswith("-isysroot"):
            i += 1
            continue
        out.append(t)
        i += 1
    return out


for key, cmd in (("cc", "clang"), ("cxx", "clang++")):
    v = cfg.get(key)
    toks = shlex.split(v) if isinstance(v, str) else list(v) if isinstance(v, list) else None
    if not toks:
        fail("include-private/js-build-config.json", "%s is empty or missing" % key)
        continue
    toks = [cmd] + strip(toks[1:], key)
    cfg[key] = shlex.join(toks) if isinstance(v, str) else toks
v = cfg.get("cxx_base_flags", [])
if isinstance(v, str):
    cfg["cxx_base_flags"] = shlex.join(strip(shlex.split(v), "cxx_base_flags"))
else:
    cfg["cxx_base_flags"] = strip([str(t) for t in v], "cxx_base_flags")
for key in ("ar", "topsrcdir", "topobjdir"):
    cfg[key] = ""
cfg_path = os.path.join(stage, "include-private", "js-build-config.json")
os.chmod(cfg_path, 0o644)
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True, ensure_ascii=False)

# Manifest.
with open(manifest_path) as f:
    bm = json.load(f)
if bm.get("tag") != tag:
    fail("build-manifest.json", "tag %r is not UPSTREAM's %r" % (bm.get("tag"), tag))
toolchain = []
for a in bm.get("toolchain_artifacts") or []:
    entry = {k: a.get(k) for k in ("name", "url", "sha256")}
    if not all(isinstance(x, str) and x for x in entry.values()) or len(entry["sha256"]) != 64:
        fail("build-manifest.json", "toolchain artifact without name, url and sha256: %r" % a)
    toolchain.append(entry)
if len(toolchain) != 2:
    fail("build-manifest.json", "expected 2 toolchain artifacts (clang, sysroot), found %d" % len(toolchain))


def bundle(kind, required):
    """{name, sha256} of spidermonkey_<V-N>-<kind>.tar.zst in ts_dir, checked
    against its .sha256; None when optional and absent."""
    name = "spidermonkey_%s-%s.tar.zst" % (package_version, kind)
    archive, sums = os.path.join(ts_dir, name), os.path.join(ts_dir, name + ".sha256")
    if not required and not os.path.lexists(archive) and not os.path.lexists(sums):
        return None
    if not os.path.isfile(sums):
        return fail(name + ".sha256", "missing from %s" % ts_dir)
    with open(sums, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    m = re.fullmatch(r"([0-9a-f]{64})  (\S+)\n?", text)
    if not m:
        return fail(name + ".sha256", "not one \"<sha256>  <name>\" line")
    if m.group(2) != name:
        return fail(name + ".sha256", "names %s, want %s" % (m.group(2), name))
    if not os.path.isfile(archive):
        return fail(name, "missing from %s" % ts_dir)
    h = hashlib.sha256()
    with open(archive, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != m.group(1):
        return fail(name, "sha256 %s differs from %s.sha256" % (h.hexdigest(), name))
    return {"name": name, "sha256": m.group(1)}


test_sources = None
if ts_dir:
    test_sources = {"testsrc": bundle("testsrc", True), "jstests": bundle("jstests", False)}
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

# Ordered by path (as build-engine.sh's dir_hash), byte order.
files = sorted(os.path.relpath(os.path.join(d, n), stage).encode()
               for d, _, names in os.walk(stage) for n in names)
lines = []
for rel in files:
    with open(os.path.join(stage, rel.decode()), "rb") as f:
        lines.append("%s  %s\n" % (hashlib.sha256(f.read()).hexdigest(), rel.decode()))
listing = "".join(lines).encode()
m = dict(bm)
m.pop("toolchain_artifacts", None)  # replaced by the filtered "toolchain"
m.update({
    "firefox_version": ff_version,
    "queue_commit": queue_commit,
    "dist_files": {"count": len(lines), "sha256": hashlib.sha256(listing).hexdigest()},
    "package_version": package_version,
    "toolchain": toolchain,
    "test_sources": test_sources,
})
with open(os.path.join(stage, "MANIFEST.json"), "w") as f:
    json.dump(m, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
os.chmod(os.path.join(stage, "MANIFEST.json"), 0o644)
PY

echo "package-engine: contract"
rc=0
pc_check_tree "$stage" "$work/prefixes" || rc=1
pc_check_opcodes "$stage" "$dist" || rc=1
[ "$rc" -eq 0 ] || die "contract violated; no archive written"

echo "package-engine: archive $name.tar.zst"
pc_archive "$TAR" "$work/stage" "$work/$name.tar.zst" spidermonkey || die "archiving failed"
pc_check_archive "$work/$name.tar.zst" spidermonkey || die "archive member check failed"
pc_sha256_line "$work/$name.tar.zst" >"$work/$name.tar.zst.sha256" || die "cannot hash $name.tar.zst"
cp "$stage/MANIFEST.json" "$work/MANIFEST.json"
mv "$work/$name.tar.zst" "$archive"
mv "$work/$name.tar.zst.sha256" "$archive.sha256"
mv "$work/MANIFEST.json" "$out/MANIFEST.json"
echo "package-engine: wrote $archive"
