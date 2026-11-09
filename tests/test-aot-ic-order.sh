#!/usr/bin/env bash
# The AOT IC corpus must be numbered the same whatever order the filesystem lists
# it in (patches/0014). The patch's loop header is run against a listing in two
# different orders, with a body that only records the visiting order, and compared.
# AOT_IC_PATCH overrides the patch under test (used to check the test can fail).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"

PATCH=${AOT_IC_PATCH:-$(ls "$ROOT"/patches/*-AOT-ICs-read-the-corpus-in-sorted-order.patch)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# loop_header <patch> <side>: the `for entry in ...:` line of read_aot_ics as it
# reads after the patch (new, an added line) or before it (old, a removed line).
loop_header() {
  awk -v side="$2" '
    /^@@ / { inhunk = 1; next }
    inhunk && /^[-+ ][ ]+for entry in / {
      c = substr($0, 1, 1)
      if ((side == "new" && c != "-") || (side == "old" && c != "+")) { print substr($0, 2); exit }
    }
  ' "$1"
}

run_listing() { # <order: forward|reverse> -> JS_AOT_IC_DATA text on stdout
  python3 -I - "$WORK/ics" "$1" "$WORK/fn.py" <<'PY'
import os, sys
ic_dir, order, fn = sys.argv[1:4]
real = os.scandir
class E:
    def __init__(self, e): self.name, self.path, self._e = e.name, e.path, e
    def is_file(self): return self._e.is_file()
def fake_scandir(path):
    entries = [E(e) for e in real(path)]
    entries.sort(key=lambda e: e.name, reverse=(order == "reverse"))
    return iter(entries)
os.scandir = fake_scandir
ns = {"os": os}
exec(compile(open(fn).read(), fn, "exec"), ns)
sys.stdout.write(ns["read_aot_ics"](ic_dir))
PY
}

numbers_ics_independently_of_directory_order() {
  mkdir "$WORK/ics"
  local n
  for n in 30 7 100 2; do echo "{ \"ic\": $n }" >"$WORK/ics/IC-$n"; done
  echo skipped >"$WORK/ics/README"
  local header
  header=$(loop_header "$PATCH" new)
  [ -n "$header" ] || { echo "no 'for entry in' line found in $PATCH" >&2; return 1; }
  # The loop under test, with a body that only records the visiting order.
  printf 'def read_aot_ics(ic_path):\n    ics = ""\n    idx = 0\n%s\n        if entry.is_file() and entry.name.startswith("IC-"):\n            ics += f"  _({idx}, {entry.name}) \\\\\\n"\n            idx += 1\n    return ics\n' "$header" >"$WORK/fn.py"
  local fwd rev
  fwd=$(run_listing forward)
  rev=$(run_listing reverse)
  assert_eq "$fwd" "$rev" "IC numbering differs between directory orders"
  assert_eq 4 "$(grep -c '^  _(' <<<"$fwd")" "four ICs numbered"
}

run_test numbers_ics_independently_of_directory_order numbers_ics_independently_of_directory_order
finish
