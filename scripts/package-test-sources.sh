#!/usr/bin/env bash
# Package the jit-test and jstests sources of a queue-built Firefox workdir.
#   package-test-sources.sh --tree DIR --out DIR --version V --revision N [--jstests]
# writes <out>/spidermonkey_V-N-testsrc.tar.zst and its .sha256 (sha256sum
# format), and with --jstests also spidermonkey_V-N-jstests.tar.zst and its
# .sha256. DIR is the workdir build-engine.sh leaves (the patched tree, never
# the bare tag), at the top level of its git repository. V must be UPSTREAM's
# Firefox version; N is a positive integer. Existing outputs are refused.
#
# Layout: members are js/src/... (and xul-info.txt); NightMonkey's
# NIGHT_FIREFOX_TESTS names the directory both bundles are extracted into.
#
# testsrc: everything the jit lane needs to start and run:
#   js/src/jit-test/**             jit_test.py, lib/, modules/, tests/
#   js/src/tests/lib/**            the harness modules jit_test.py imports
#   js/src/tests/jstests.py        the jstests runner (it needs tests/lib)
#   js/src/jsapi.h                 jit_test.py asserts it exists at startup
#   + every file a jit-test script loads with loadRelativeToScript("<literal>")
#     outside js/src/jit-test (today tests/non262/shell.js, Math/shell.js,
#     reflect-parse/Match.js), found by scanning, recursively; a target that is
#     not tracked or leaves js/src fails naming the loader.
# jstests (added on top of testsrc in the same directory):
#   js/src/tests/{test262,non262,shell}/**  the suites jstests.py walks
#                                  (shell/ holds shell-function tests the
#                                  walker runs from a source tree too)
#   js/src/tests/shell.js          the top-level shell.js every test loads
#   js/src/tests/jstests.list      skip/fails annotations; jstests.py reads it
#                                  from its own directory and silently uses no
#                                  annotations when it is absent
#   xul-info.txt                   one line "ABI:OS:DEBUG" for jstests.py
#                                  --xul-info, read from the objdir's
#                                  config/autoconf.mk exactly as
#                                  XULInfo.create reads it (TARGET_XPCOM_ABI,
#                                  OS_TARGET required; MOZ_DEBUG "1" -> true,
#                                  else false). Without --xul-info jstests.py
#                                  searches for config/autoconf.mk and exits.
#
# Only the tracked tree is packaged, and it must be the pinned one: the index
# tree (git write-tree) must equal UPSTREAM's tree=, no tracked file may differ
# from the index (git diff), and no index entry may hide edits
# (assume-unchanged, skip-worktree). Files are the index's blobs, raw (git
# cat-file --batch): no checkout, so no .gitattributes (tracked or untracked),
# eol/autocrlf setting or smudge filter can change a byte; modes come from the
# index (100755 -> 0755, 100644 -> 0644). The loadRelativeToScript scan reads
# the same blobs. Untracked build output (the objdir, __pycache__) is allowed
# and never archived. Tracked symlinks and submodules in the bundle are
# refused.
#
# Archives are deterministic (scripts/lib/package-contract.sh pc_archive) and
# their members are checked (pc_check_archive). Hermetic like pq_git: paths are
# resolved up front, LC_ALL, umask, TAR_OPTIONS and ZSTD_* are fixed, git runs
# through pq_git and python3 runs isolated. Needs GNU tar (`tar`, else
# `gtar`), zstd, python3 and git 2.32+. The objdir name is read from the
# repository's mozconfig (mk_add_options MOZ_OBJDIR=...).
# PQ_ROOT overrides the repository root (tests use it).
# Exit codes: 0 ok, 1 refused or failed (the message names the file), 2 usage.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"
# shellcheck source=lib/package-contract.sh
. "$SELF/scripts/lib/package-contract.sh"

usage() {
  [ $# -eq 0 ] || echo "package-test-sources: $*" >&2
  echo "usage: package-test-sources.sh --tree DIR --out DIR --version V --revision N [--jstests]" >&2
  exit 2
}
die() { echo "package-test-sources: $*" >&2; exit 1; }

tree= out= version= revision= jstests=0
while [ $# -gt 0 ]; do
  case $1 in
    --tree | --out | --version | --revision)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --tree) tree=$2 ;;
        --out) out=$2 ;;
        --version) version=$2 ;;
        --revision) revision=$2 ;;
      esac
      shift 2 ;;
    --jstests) jstests=1; shift ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$tree" ] && [ -n "$out" ] && [ -n "$version" ] && [ -n "$revision" ] ||
  usage "all of --tree --out --version --revision are required"
[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || usage "bad version: $version"
[[ $revision =~ ^[1-9][0-9]*$ ]] || usage "bad revision: $revision"
[ -d "$tree" ] || usage "no such directory: $tree"

export LC_ALL=C
umask 022
unset TAR_OPTIONS ZSTD_CLEVEL ZSTD_NBTHREADS
pq_git_env || exit 1

tree=$(cd "$tree" && pwd -P)
mkdir -p "$out"
out=$(cd "$out" && pwd -P)

base=spidermonkey_$version-$revision
outputs="$base-testsrc.tar.zst $base-testsrc.tar.zst.sha256"
[ "$jstests" -eq 0 ] || outputs="$outputs $base-jstests.tar.zst $base-jstests.tar.zst.sha256"
for f in $outputs; do
  if [ -e "$out/$f" ] || [ -L "$out/$f" ]; then die "$out/$f exists; move it away first"; fi
done

TAR=$(pc_gnu_tar) || exit 1
command -v zstd >/dev/null 2>&1 || die "zstd is required"

pq_read_pin "$ROOT/UPSTREAM" || exit 1
firefox_version=$(pc_firefox_version "$PQ_TAG") || exit 1
[ "$version" = "$firefox_version" ] ||
  die "--version $version is not UPSTREAM's Firefox version $firefox_version"

# The tracked tree, exactly as pinned.
top=$(pq_git -C "$tree" rev-parse --show-toplevel) || die "$tree is not in a git worktree"
top=$(cd "$top" && pwd -P)
[ "$top" = "$tree" ] || die "$tree is not the top level of its repository ($top)"
hidden=$(pq_git -C "$tree" ls-files -v | grep -E '^([a-z]|S) ' | cut -c3-) || true
[ -z "$hidden" ] ||
  die "index entries marked assume-unchanged or skip-worktree hide edits: $(echo "$hidden" | tr '\n' ' ')"
rc=0
pq_git -C "$tree" diff --quiet || rc=$?
case $rc in
  0) ;;
  1) die "tracked files differ from the index: $(pq_git -C "$tree" diff --name-only | tr '\n' ' ')" ;;
  *) die "git diff failed in $tree" ;;
esac
tree_hash=$(pq_tree "$tree") || die "git write-tree failed in $tree"
[ "$tree_hash" = "$PQ_TREE" ] ||
  die "tree mismatch: UPSTREAM says $PQ_TREE, $tree's index is $tree_hash"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Select the bundle files from the index and stage their raw blobs.
pq_git -C "$tree" ls-files -s -z -- js/src >"$work/index" || die "git ls-files failed"
# python3 runs `git cat-file --batch` itself: this shell's environment is
# already hermetic for git (pq_git_env above), and a raw blob read applies no
# attributes, filters or eol conversion.
python3 -I - "$tree" "$work/index" "$work/testsrc" "$work/jstests" "$jstests" <<'PY' || exit 1
import os, posixpath, re, subprocess, sys

tree, index_path, testsrc_dir, jstests_dir, want_jstests = sys.argv[1:]
modes, oids = {}, {}
with open(index_path, "rb") as f:
    for entry in f.read().split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            mode, oid, _stage = meta.decode().split()
            p = path.decode("utf-8", "surrogateescape")
            modes[p], oids[p] = mode, oid
errors = []

git = subprocess.Popen(["git", "-C", tree, "cat-file", "--batch"],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE)
blobs = {}


def blob(p):
    """The raw bytes of path p's index blob."""
    if p not in blobs:
        git.stdin.write(oids[p].encode() + b"\n")
        git.stdin.flush()
        header = git.stdout.readline().split()
        if len(header) != 3 or header[0].decode() != oids[p] or header[1] != b"blob":
            sys.exit("package-test-sources: %s: cannot read blob %s" % (p, oids[p]))
        size = int(header[2])
        data = git.stdout.read(size)
        if len(data) != size or git.stdout.read(1) != b"\n":
            sys.exit("package-test-sources: %s: short read of blob %s" % (p, oids[p]))
        blobs[p] = data
    return blobs[p]


def fail(rel, why):
    errors.append("package-test-sources: %s: %s" % (rel, why))


def under(prefix):
    return sorted(p for p in modes if p.startswith(prefix + "/"))


testsrc = set(under("js/src/jit-test") + under("js/src/tests/lib"))
for p in ("js/src/tests/jstests.py", "js/src/jsapi.h"):
    if p in modes:
        testsrc.add(p)
required = ["js/src/jit-test/jit_test.py", "js/src/jsapi.h", "js/src/tests/jstests.py",
            "js/src/tests/lib/__init__.py"]

# Runtime loads outside jit-test: loadRelativeToScript("<literal>"), resolved
# against the loading file's directory, followed through the files they add.
load_re = re.compile(r"""loadRelativeToScript\(\s*(["'])([^"'\\]+)\1\s*\)""")
pending = sorted(p for p in testsrc if p.endswith(".js"))
seen = set()
while pending:
    loader = pending.pop()
    if loader in seen:
        continue
    seen.add(loader)
    if modes[loader] not in ("100644", "100755"):
        continue  # refused below; a symlink's blob is its target path
    src = blob(loader).decode("utf-8", "replace")
    for m in load_re.finditer(src):
        target = posixpath.normpath(posixpath.join(posixpath.dirname(loader), m.group(2)))
        if not target.startswith("js/src/"):
            fail(loader, "loadRelativeToScript(%r) leaves js/src" % m.group(2))
        elif target not in modes:
            fail(loader, "loadRelativeToScript(%r): %s is not tracked" % (m.group(2), target))
        elif target not in testsrc:
            testsrc.add(target)
            pending.append(target)

jstests = set()
if want_jstests == "1":
    for d in ("test262", "non262", "shell"):
        jstests.update(under("js/src/tests/" + d))
    for p in ("js/src/tests/shell.js", "js/src/tests/jstests.list"):
        if p in modes:
            jstests.add(p)
    required += ["js/src/tests/shell.js", "js/src/tests/jstests.list"]
    for d in ("test262", "non262"):
        if not under("js/src/tests/" + d):
            fail("js/src/tests/" + d, "missing directory")

for p in required:
    if p not in modes:
        fail(p, "missing from the tracked tree")
for p in sorted(testsrc | jstests):
    if modes[p] == "120000":
        fail(p, "tracked symlink")
    elif modes[p] == "160000":
        fail(p, "submodule")
    elif modes[p] not in ("100644", "100755"):
        fail(p, "unexpected mode %s" % modes[p])
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
for top, files in ((testsrc_dir, testsrc), (jstests_dir, jstests)):
    os.makedirs(top)
    for p in sorted(files):
        dst = os.path.join(top, p)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(blob(p))
        os.chmod(dst, 0o755 if modes[p] == "100755" else 0o644)
git.stdin.close()
if git.wait() != 0:
    sys.exit("package-test-sources: git cat-file failed in %s" % tree)
PY

entries_jstests=js
if [ "$jstests" -eq 1 ]; then
  objdir=$(sed -n 's/^[[:space:]]*mk_add_options[[:space:]]\{1,\}MOZ_OBJDIR=\([^[:space:]]*\)[[:space:]]*$/\1/p' \
    "$ROOT/mozconfig" | tail -n 1)
  case $objdir in
    '' | /* | *..* | *@*) die "mozconfig: no plain relative MOZ_OBJDIR=... (got '$objdir')" ;;
  esac
  python3 -I - "$tree" "$objdir/config/autoconf.mk" "$work/jstests/xul-info.txt" <<'PY' || exit 1
import os, re, sys

tree, rel, out = sys.argv[1:]
path = os.path.join(tree, rel)
if not os.path.isfile(path):
    sys.exit("package-test-sources: %s: missing (needed for xul-info.txt; build first)" % rel)
# XULInfo.create's reading of autoconf.mk.
val_re = re.compile(r"(TARGET_XPCOM_ABI|OS_TARGET|MOZ_DEBUG)\s*=\s*(.*)")
kw = {"isdebug": False}
with open(path, encoding="utf-8") as f:
    for line in f:
        m = val_re.match(line)
        if m:
            key, val = m.groups()
            val = val.rstrip()
            if key == "TARGET_XPCOM_ABI":
                kw["abi"] = val
            if key == "OS_TARGET":
                kw["os"] = val
            if key == "MOZ_DEBUG":
                kw["isdebug"] = val == "1"
bad = [k for k, name in (("abi", "TARGET_XPCOM_ABI"), ("os", "OS_TARGET")) if k not in kw]
if bad:
    sys.exit("package-test-sources: %s: %s not set" % (
        rel, " and ".join({"abi": "TARGET_XPCOM_ABI", "os": "OS_TARGET"}[k] for k in bad)))
for k, name in (("abi", "TARGET_XPCOM_ABI"), ("os", "OS_TARGET")):
    if ":" in kw[k] or "\n" in kw[k]:
        sys.exit("package-test-sources: %s: %s %r cannot be passed as --xul-info" % (rel, name, kw[k]))
with open(out, "w") as f:
    f.write("%s:%s:%s\n" % (kw["abi"], kw["os"], "true" if kw["isdebug"] else "false"))
PY
  entries_jstests="js xul-info.txt"
fi

# Directories 0755 (files already carry the index's mode); nothing but regular
# files and directories may be staged.
python3 -I - "$work/testsrc" "$work/jstests" <<'PY' || exit 1
import os, stat, sys

for top in sys.argv[1:]:
    if not os.path.isdir(top):
        continue
    os.chmod(top, 0o755)
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            st = os.lstat(p)
            if stat.S_ISDIR(st.st_mode):
                os.chmod(p, 0o755)
            elif not stat.S_ISREG(st.st_mode):
                sys.exit("package-test-sources: %s: not a regular file or directory"
                         % os.path.relpath(p, top))
PY

# archive <name> <entries...>: archive, check, hash; outputs move into place
# only after every archive is made.
archive() {
  local name=$1 file=$base-$1.tar.zst
  shift
  echo "package-test-sources: archive $file"
  # shellcheck disable=SC2086 # entries are fixed words
  pc_archive "$TAR" "$work/$name" "$work/$file" "$@" || die "archiving $file failed"
  pc_check_archive "$work/$file" "$@" || die "archive member check failed for $file"
  pc_sha256_line "$work/$file" >"$work/$file.sha256" || die "cannot hash $file"
}
archive testsrc js
if [ "$jstests" -eq 1 ]; then
  # shellcheck disable=SC2086 # "js xul-info.txt": two fixed words
  archive jstests $entries_jstests
fi
for f in $outputs; do
  mv "$work/$f" "$out/$f"
done
echo "package-test-sources: wrote $outputs into $out"
