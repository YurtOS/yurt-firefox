#!/usr/bin/env bash
# Offline stand-in for the queue-built Firefox workdir that
# scripts/package-test-sources.sh bundles. Source it after tests/lib.sh; it
# defines functions only.
#
# make_fixture_testsrc <dir> creates <dir>/firefox, a git repository with one
# commit whose js/src has the real directory shape of the test harnesses, plus
# untracked build output (obj-nightmonkey-sm/ with config/autoconf.mk, and a
# __pycache__ in js/src/tests/lib) as a build leaves it. Sets TS_TREE (the
# workdir, pwd -P).
#
# The harness files are reductions of FIREFOX_147_0_4_RELEASE, not copies:
# - jit-test/jit_test.py keeps add_tests_dir_to_path() verbatim (realpath of
#   argv[0] -> js/src, `assert exists(jsapi.h)`, tests/ on sys.path) and the
#   module-level `from lib import ...` imports, so startup needs what the real
#   one needs; a test is run with the real shell invocation shape
#   (-p lib/prologue.js, -e const libdir/scriptdir, --module-load-path, -f test).
# - tests/lib/ has the real module names and inter-module imports (jittests ->
#   .progressbar .results .structuredlog .tempfile) and the TEST_DIR/LIB_DIR/
#   MODULE_DIR derivation from __file__.
# - tests/jstests.py takes --xul-info "ABI:OS:DEBUG" (split on ':', debug
#   compared lower-case to "true"); without it, like XULInfo.create, it looks
#   for config/autoconf.mk above the cwd and the shell and exits 1. It reads
#   tests/jstests.list next to itself (absent: no entries, as upstream) and
#   runs each test with the shell.js chain (-f .../shell.js ... -f test).
# - jit-test/lib/{non262,math,match}.js load ../../tests/non262/... with
#   loadRelativeToScript, as upstream: runtime dependencies outside jit-test/.
# non262/Math/skipme.js contains STUB-FAIL and is skipped only through
# tests/jstests.list, so a bundle without jstests.list fails a jstests run.

# ts_write <path> <content>: write a file under $TS_TREE, creating its directory.
ts_write() {
  mkdir -p "$(dirname "$TS_TREE/$1")" || return 1
  printf '%s\n' "$2" >"$TS_TREE/$1"
}

make_fixture_testsrc() {
  mkdir -p "$1/firefox" || return 1
  TS_TREE=$(cd "$1/firefox" && pwd -P) || return 1
  local j=js/src/jit-test t=js/src/tests

  ts_write js/src/jsapi.h '/* jsapi.h (jit_test.py asserts it exists) */' || return 1
  ts_write js/src/vm/Opcodes.h 'MACRO(Nop, nop, NULL, 1, 0, 0, JOF_BYTE)' || return 1
  ts_write js/public/Value.h '/* not test source */' || return 1
  ts_write other/b.txt 'not js' || return 1

  ts_write $j/README 'jit-test README' || return 1
  ts_write $j/jit_test.py '#!/usr/bin/env python3
# Reduction of FIREFOX_147_0_4_RELEASE js/src/jit-test/jit_test.py (fixture).
import os
import subprocess
import sys


def add_tests_dir_to_path():
    from os.path import dirname, exists, join, realpath

    js_src_dir = dirname(dirname(realpath(sys.argv[0])))
    assert exists(join(js_src_dir, "jsapi.h"))
    sys.path.insert(0, join(js_src_dir, "tests"))


add_tests_dir_to_path()

from lib import jittests
from lib.tempfile import TemporaryDirectory
from lib.tests import change_env


def main(argv):
    import argparse

    op = argparse.ArgumentParser(description="Run jit-test JS shell tests")
    op.add_argument("--format", default="none")
    op.add_argument("js_shell")
    op.add_argument("tests", nargs="*")
    options = op.parse_args(argv)
    tests = jittests.find_tests(options.tests)
    if not tests:
        print("No tests found matching command line arguments.")
        return 2
    failed = 0
    with TemporaryDirectory(), change_env({}):
        for path in tests:
            cmd = [options.js_shell, "-p", os.path.join(jittests.LIB_DIR, "prologue.js"),
                   "-e", "const platform=%r" % sys.platform,
                   "-e", "const libdir=%r" % jittests.LIB_DIR,
                   "-e", "const scriptdir=%r" % (os.path.dirname(path) + os.sep),
                   "--module-load-path", jittests.MODULE_DIR, "-f", path]
            ok = subprocess.call(cmd) == 0
            print("TEST-%s | %s" % ("PASS" if ok else "UNEXPECTED-FAIL",
                                    os.path.relpath(path, jittests.TEST_DIR)))
            failed += not ok
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))' || return 1
  ts_write $j/lib/prologue.js '// prologue' || return 1
  ts_write $j/lib/non262.js 'loadRelativeToScript("../../tests/non262/shell.js");' || return 1
  ts_write $j/lib/math.js 'loadRelativeToScript("../../tests/non262/Math/shell.js");' || return 1
  ts_write $j/lib/match.js 'loadRelativeToScript("../../tests/non262/reflect-parse/Match.js");' || return 1
  ts_write $j/lib/wasm-binary.js '// wasm binary helpers' || return 1
  ts_write $j/lib/gen/wasm-gc-limits-gen.js 'loadRelativeToScript("../wasm-binary.js");' || return 1
  ts_write $j/modules/module1.js 'export default 1;' || return 1
  ts_write $j/tests/basic/simple.js '// simple' || return 1
  ts_write $j/tests/basic/uses-non262.js 'load(libdir + "non262.js");
load(libdir + "math.js");
load(libdir + "match.js");' || return 1

  ts_write $t/README.txt 'jstests README' || return 1
  ts_write $t/browser.js '// browser only' || return 1
  ts_write $t/shell.js '// top-level shell.js (reportCompare)' || return 1
  ts_write $t/jstests.list '# Skip the folder with tests for the scripts
skip include test/jstests.list
skip script non262/Math/skipme.js # input data' || return 1
  ts_write $t/jstests.py '#!/usr/bin/env python3
# Reduction of FIREFOX_147_0_4_RELEASE js/src/tests/jstests.py (fixture).
import os
import subprocess
import sys
from os.path import abspath, dirname

from lib.adaptor import xdr_annotate
from lib.tests import RefTestCase

here = dirname(abspath(__file__))


def main(argv):
    import argparse

    import lib.manifest as manifest

    op = argparse.ArgumentParser(description="Run jstests JS shell tests")
    op.add_argument("--xul-info", dest="xul_info_src")
    op.add_argument("--wpt", default="if-running-everything")
    op.add_argument("--format", default="none")
    op.add_argument("js_shell")
    op.add_argument("paths", nargs="*")
    options = op.parse_args(argv)
    if options.xul_info_src is None:
        xul_info = manifest.XULInfo.create(dirname(abspath(options.js_shell)))
    else:
        xul_abi, xul_os, xul_debug = options.xul_info_src.split(r":")
        xul_info = manifest.XULInfo(xul_abi, xul_os, xul_debug.lower() == "true")
    tests = [xdr_annotate(t, options) for t in manifest.load_reftests(here, options.paths, xul_info)]
    if not tests:
        print("No tests found.")
        return 2
    failed = 0
    for test in tests:
        ok = subprocess.call([options.js_shell] + test.prefix_command() + ["-f", test.abs_path()]) == 0
        print("TEST-%s | %s" % ("PASS" if ok else "UNEXPECTED-FAIL", test.path))
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))' || return 1
  ts_write $t/lib/__init__.py '' || return 1
  ts_write $t/lib/progressbar.py 'class NullProgressBar:
    pass' || return 1
  ts_write $t/lib/structuredlog.py 'class TestLogger:
    pass' || return 1
  ts_write $t/lib/results.py 'from .structuredlog import TestLogger


def escape_cmdline(args):
    return " ".join(args)' || return 1
  ts_write $t/lib/tempfile.py 'from tempfile import TemporaryDirectory  # noqa: F401' || return 1
  ts_write $t/lib/adaptor.py 'def xdr_annotate(test, options):
    return test' || return 1
  ts_write $t/lib/tests.py 'import os
from contextlib import contextmanager


@contextmanager
def change_env(env_overlay):
    saved = dict(os.environ)
    os.environ.update(env_overlay)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


class RefTestCase:
    def __init__(self, root, path):
        self.root = root
        self.path = path

    def prefix_command(self):
        path, prefix = self.path, []
        while path != "":
            path = os.path.dirname(path)
            shell_path = os.path.join(self.root, path, "shell.js")
            if os.path.exists(shell_path):
                prefix += [shell_path, "-f"]
        prefix.reverse()
        return prefix

    def abs_path(self):
        return os.path.join(self.root, self.path)' || return 1
  ts_write $t/lib/jittests.py 'import os

from .progressbar import NullProgressBar
from .results import escape_cmdline
from .structuredlog import TestLogger
from .tempfile import TemporaryDirectory

TESTS_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
JS_DIR = os.path.dirname(os.path.dirname(TESTS_LIB_DIR))
TOP_SRC_DIR = os.path.dirname(os.path.dirname(JS_DIR))
TEST_DIR = os.path.join(JS_DIR, "jit-test", "tests")
LIB_DIR = os.path.join(JS_DIR, "jit-test", "lib") + os.path.sep
MODULE_DIR = os.path.join(JS_DIR, "jit-test", "modules") + os.path.sep


def find_tests(substrings):
    found = []
    for dirpath, dirnames, filenames in os.walk(TEST_DIR):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, TEST_DIR)
            if name.endswith(".js") and (not substrings or any(s in rel for s in substrings)):
                found.append(path)
    return found' || return 1
  ts_write $t/lib/manifest.py 'import os
import posixpath
import re
import sys

from .tests import RefTestCase


class XULInfo:
    def __init__(self, abi, os, isdebug):
        self.abi, self.os, self.isdebug = abi, os, isdebug

    @classmethod
    def create(cls, jsdir):
        dirs = []
        for start in (os.getcwd(), jsdir):
            d = start
            while True:
                dirs.append(d)
                parent = os.path.dirname(d)
                if parent == d:
                    break
                d = parent
        path = None
        for d in dirs:
            p = posixpath.join(d, "config", "autoconf.mk")
            if os.path.isfile(p):
                path = p
                break
        if path is None:
            print("Can'"'"'t find config/autoconf.mk on a directory containing"
                  " the JS shell (searched from %s)" % jsdir)
            sys.exit(1)
        val_re = re.compile(r"(TARGET_XPCOM_ABI|OS_TARGET|MOZ_DEBUG)\s*=\s*(.*)")
        kw = {"isdebug": False}
        for line in open(path, encoding="utf-8"):
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
        return cls(**kw)


EXCLUDED = {"browser.js", "shell.js", "template.js", "user.js",
            "js-test-driver-begin.js", "js-test-driver-end.js"}


def _external_manifest(location):
    filename = os.path.join(location, "jstests.list")
    if not os.path.exists(filename):
        return [], []
    skip_dirs, skip_scripts = [], []
    for line in open(filename, encoding="utf-8"):
        words = line.split("#")[0].split()
        if words[:2] == ["skip", "include"]:
            skip_dirs.append(posixpath.dirname(words[2]))
        elif words[:2] == ["skip", "script"]:
            skip_scripts.append(words[2])
    return skip_dirs, skip_scripts


def load_reftests(location, requested_paths, xul_tester):
    skip_dirs, skip_scripts = _external_manifest(location)
    for root, dirnames, filenames in os.walk(location):
        dirnames.sort()
        rel_root = os.path.relpath(root, location)
        if rel_root == ".":
            continue
        if any(rel_root == d or rel_root.startswith(d + "/") for d in skip_dirs):
            continue
        for name in sorted(filenames):
            rel = posixpath.join(rel_root, name)
            if not name.endswith(".js") or name in EXCLUDED or rel in skip_scripts:
                continue
            if requested_paths and not any(rel.startswith(p) for p in requested_paths):
                continue
            yield RefTestCase(location, rel)' || return 1

  ts_write $t/non262/shell.js '// non262 shell.js' || return 1
  ts_write $t/non262/Math/shell.js '// non262 Math shell.js' || return 1
  ts_write $t/non262/Math/abs.js '// Math.abs test' || return 1
  ts_write $t/non262/Math/skipme.js '// STUB-FAIL: input data, skipped by jstests.list' || return 1
  ts_write $t/non262/reflect-parse/Match.js '// Match helpers' || return 1
  ts_write $t/test262/shell.js '// test262 shell.js' || return 1
  ts_write $t/test262/built-ins/Array/length.js '// test262 test' || return 1
  ts_write $t/shell/os.js '// shell os test' || return 1
  ts_write $t/test/run.js '// STUB-FAIL: script tests, skipped by jstests.list' || return 1
  ts_write $t/test/jstests.list 'script run.js' || return 1

  git -C "$TS_TREE" init -q || return 1
  git -C "$TS_TREE" add -A || return 1
  git -C "$TS_TREE" commit -q -m "fixture firefox workdir" || return 1

  # Untracked build output.
  ts_write obj-nightmonkey-sm/config/autoconf.mk 'OS_ARCH = WASI
OS_TARGET = WASI
TARGET_XPCOM_ABI = wasm32-clang
MOZ_DEBUG =' || return 1
  ts_write obj-nightmonkey-sm/dist/bin/js 'binary' || return 1
  ts_write obj-nightmonkey-sm/js/src/jit-test/tests/generated.js '// objdir copy' || return 1
  ts_write $t/lib/__pycache__/jittests.cpython-312.pyc 'bytecode' || return 1
}
