#!/usr/bin/env bash
# Engine package contract: the checks scripts/package-engine.sh runs on the tree
# it is about to archive, and release.yml re-runs on the extracted archive.
# Source it; it defines functions only. Each check prints one
# "package-contract: <relpath>: <reason>" line per violation on stderr and
# returns 1 if there was any. python3 runs isolated (-I), so PYTHON* variables
# and the cwd cannot change what it does.
#
# The package tree (the archive's top directory `spidermonkey/`) holds include/,
# include-private/ (with js-build-config.json and vm/Opcodes.h),
# system_wrappers/, lib/{libjs_static,libjsrust,libjsshell,libpure_virtual}.a,
# bin/js and MANIFEST.json, as regular files and directories only.
#
# What counts as a leaked producer path: a text file containing one of the
# producer prefixes (pc_prefixes: the dist config's topsrcdir and topobjdir,
# the sysroot and clang directories named in cc/cxx/cxx_base_flags, $HOME and
# MOZBUILD_STATE_PATH). A generic "any absolute path" scan would flag headers
# and is not used. lib/*.a and bin/js embed the workdir and are exempt; every
# other file, MANIFEST.json included, is scanned.

PC_LIBS="libjs_static libjsrust libjsshell libpure_virtual"

# pc_prefixes <js-build-config.json>: print the producer prefixes, one per
# line, sorted and unique. Empty values, relative paths and top-level system
# directories ("/", "/usr", "/usr/local", "/opt") are skipped, so a bare
# `clang` on PATH or an unset MOZBUILD_STATE_PATH never yields a pattern that
# matches everything. A prefix that exists is also printed in its realpath
# form. The clang directory is argv0's directory, minus a trailing /bin.
pc_prefixes() {
  python3 -I - "$1" "${HOME:-}" "${MOZBUILD_STATE_PATH:-}" <<'PY'
import json, os, shlex, sys

path, home, state = sys.argv[1:]
try:
    with open(path) as f:
        cfg = json.load(f)
except (OSError, ValueError) as e:
    sys.exit("package-contract: include-private/js-build-config.json: unreadable: %s" % e)


def tokens(v):
    if isinstance(v, list):
        return [str(t) for t in v]
    if isinstance(v, str):
        return shlex.split(v)
    return []


found = [cfg.get("topsrcdir"), cfg.get("topobjdir"), home, state]
for key in ("cc", "cxx"):
    t = tokens(cfg.get(key))
    if t and os.path.isabs(t[0]):
        d = os.path.dirname(t[0])
        if os.path.basename(d) == "bin":
            d = os.path.dirname(d)
        found.append(d)
for key in ("cc", "cxx", "cxx_base_flags"):
    t = tokens(cfg.get(key))
    for i, tok in enumerate(t):
        if tok in ("--sysroot", "-isysroot") and i + 1 < len(t):
            found.append(t[i + 1])
        elif tok.startswith("--sysroot="):
            found.append(tok[len("--sysroot="):])
        elif tok.startswith("-isysroot") and len(tok) > len("-isysroot"):
            found.append(tok[len("-isysroot"):])

skip = {"", "/", "/usr", "/usr/local", "/opt"}
out = set()
for p in found:
    if not isinstance(p, str) or not os.path.isabs(p):
        continue
    for q in (p, os.path.realpath(p) if os.path.exists(p) else p):
        q = q.rstrip("/")
        if q not in skip:
            out.add(q)
for p in sorted(out):
    print(p)
PY
}

# pc_check_tree <tree> <prefix-file>: the package tree is complete, holds only
# regular files and directories (no symlink, so nothing points outside), no
# non-exempt file contains a line of <prefix-file>, and js-build-config.json
# names no toolchain path (pc_check_config).
pc_check_tree() {
  local rc=0
  python3 -I - "$1" "$2" "$PC_LIBS" <<'PY' || rc=1
import os, stat, sys

tree, prefix_file, libs = sys.argv[1:]
with open(prefix_file, "rb") as f:
    prefixes = [l.rstrip(b"\r\n") for l in f]
prefixes = [p for p in prefixes if p.strip()]
bad = []


def fail(rel, why):
    bad.append("package-contract: %s: %s" % (rel, why))


if not os.path.isdir(tree) or os.path.islink(tree):
    sys.exit("package-contract: %s: not a directory" % tree)
for d in ("include", "include-private", "system_wrappers"):
    p = os.path.join(tree, d)
    if os.path.islink(p) or not os.path.isdir(p):
        fail(d, "missing directory")
required = ["include-private/js-build-config.json", "include-private/vm/Opcodes.h",
            "bin/js", "MANIFEST.json"] + ["lib/%s.a" % l for l in libs.split()]
for r in required:
    p = os.path.join(tree, r)
    if os.path.islink(p) or not os.path.isfile(p):
        fail(r, "missing file")
exempt = {"bin/js"} | {"lib/%s.a" % l for l in libs.split()}

for dirpath, dirnames, filenames in os.walk(tree):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, tree)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            fail(rel, "symlink (-> %s)" % os.readlink(p))
        elif stat.S_ISDIR(st.st_mode):
            pass
        elif not stat.S_ISREG(st.st_mode):
            fail(rel, "not a regular file or directory")
        elif rel not in exempt:
            with open(p, "rb") as f:
                data = f.read()
            for prefix in prefixes:
                if prefix in data:
                    fail(rel, "contains producer path %s" % prefix.decode("utf-8", "replace"))
                    break
for line in bad:
    print(line, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  if [ -f "$1/include-private/js-build-config.json" ]; then
    pc_check_config "$1/include-private/js-build-config.json" || rc=1
  fi
  return "$rc"
}

# pc_check_config <js-build-config.json>: the package's config: argv0 of cc
# and cxx is exactly `clang` and `clang++`, no sysroot option (`--sysroot X`,
# `--sysroot=X`, `-isysroot X`) in cc, cxx or cxx_base_flags, and ar,
# topsrcdir and topobjdir are "". Needs no producer knowledge.
pc_check_config() {
  python3 -I - "$1" <<'PY'
import json, shlex, sys

rel = "include-private/js-build-config.json"
bad = []
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except (OSError, ValueError) as e:
    sys.exit("package-contract: %s: unreadable: %s" % (rel, e))


def tokens(v):
    if isinstance(v, list):
        return [str(t) for t in v]
    if isinstance(v, str):
        return shlex.split(v)
    return None


for key, want in (("cc", "clang"), ("cxx", "clang++")):
    t = tokens(cfg.get(key))
    if not t or t[0] != want:
        bad.append("%s: argv0 is %r, want %r" % (key, t[0] if t else None, want))
for key in ("cc", "cxx", "cxx_base_flags"):
    for tok in tokens(cfg.get(key)) or []:
        if tok == "--sysroot" or tok.startswith("--sysroot=") or tok.startswith("-isysroot"):
            bad.append("%s: sysroot option %r" % (key, tok))
for key in ("ar", "topsrcdir", "topobjdir"):
    if cfg.get(key) != "":
        bad.append("%s is %r, want \"\"" % (key, cfg.get(key)))
for b in bad:
    print("package-contract: %s: %s" % (rel, b), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

# pc_check_opcodes <tree> <dist>: include-private/vm/Opcodes.h in the package
# is byte-identical to the dist's.
pc_check_opcodes() {
  local rel=include-private/vm/Opcodes.h
  [ -f "$1/$rel" ] && [ -f "$2/$rel" ] || { echo "package-contract: $rel: missing" >&2; return 1; }
  cmp -s "$1/$rel" "$2/$rel" || { echo "package-contract: $rel: differs from the dist's" >&2; return 1; }
}

# pc_check_archive <archive.tar.zst>: every member is `spidermonkey` or under
# `spidermonkey/`, has no `..` component, and is a regular file or directory
# (no symlink, hard link or device). Read as a stream; nothing is extracted.
pc_check_archive() (
  set -o pipefail
  command -v zstd >/dev/null 2>&1 || { echo "package-contract: zstd not found" >&2; return 1; }
  zstd -q -dc -- "$1" | python3 -I -c '
import sys, tarfile
bad = []
n = 0
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as t:
    for m in t:
        n += 1
        parts = m.name.split("/")
        if m.name.startswith("/") or ".." in parts or parts[0] != "spidermonkey":
            bad.append("%s: outside spidermonkey/" % m.name)
        elif not (m.isfile() or m.isdir()):
            bad.append("%s: not a regular file or directory" % m.name)
if n == 0:
    bad.append("%s: empty archive" % sys.argv[1])
for b in bad:
    print("package-contract: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
' "$1"
)
