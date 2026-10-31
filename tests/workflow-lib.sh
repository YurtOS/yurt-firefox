#!/usr/bin/env bash
# Helpers for the workflow tests (tests/test-workflows.sh,
# tests/test-release-workflow.sh). Source it after tests/lib.sh; it defines
# functions only.

# body <file>: the workflow text without full-line comments, so a commented-out
# line cannot satisfy an assertion.
body() { grep -Ev '^[[:space:]]*#' "$1"; }

# has_line <file> <text>: some body line, leading blanks stripped, is exactly <text>.
# It counts (grep -c reads all its input) rather than grep -q, which exits at
# the first match and, under pipefail, fails the check when GNU sed then dies
# of SIGPIPE ("sed: couldn't flush stdout: Broken pipe").
has_line() { [ "$(body "$1" | sed 's/^[[:space:]]*//' | grep -cxF -- "$2")" -ge 1 ]; }

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

# no_or_on <file> <pattern>: no body line matching <pattern> carries `||`, so a
# failing check cannot be swallowed.
no_or_on() {
  local bad
  bad=$(body "$1" | grep -F -- "$2" | grep -F '||' || true)
  [ -z "$bad" ] || { printf '%s: failure swallowed:\n%s\n' "${1##*/}" "$bad" >&2; return 1; }
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

# step_if <file> <step>: the step's `if:` value, wrapped in ${{ }} if bare.
step_if() {
  local v
  v=$(step "$1" "$2" | sed -n 's/^[[:space:]]*if:[[:space:]]*//p' | head -1)
  case $v in '${{'*) printf '%s\n' "$v" ;; '') ;; *) printf '${{ %s }}\n' "$v" ;; esac
}

# run_scripts <workflow> <dir>: write every `run:` script of <workflow> to
# <dir>/<line>.sh, ${{ }} expressions replaced by a placeholder as actionlint
# does before shellcheck. Prints the number of scripts.
run_scripts() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
path, out = sys.argv[1:]
lines = open(path).read().split("\n")
n, i = 0, 0
while i < len(lines):
    m = re.match(r"^(\s*)(?:- )?run: (.*)$", lines[i])
    if not m or lines[i].lstrip().startswith("#"):
        i += 1
        continue
    start = i + 1
    # Any block scalar header: | or > with an optional chomping (+ -) and
    # indentation (1-9) indicator, in either order.
    if re.fullmatch(r"[|>](?:[+-][1-9]?|[1-9][+-]?)?", m.group(2).strip()):
        body, j, ind = [], i + 1, None
        while j < len(lines):
            l = lines[j]
            if l.strip() == "":
                body.append(""); j += 1; continue
            k = len(l) - len(l.lstrip())
            if ind is None:
                ind = k
            if k < ind:
                break
            body.append(l[ind:]); j += 1
        script, i = "\n".join(body), j
    else:
        script, i = m.group(2), i + 1
    script = re.sub(r"\$\{\{.*?\}\}", "_GH_EXPR_", script)
    with open("%s/%d.sh" % (out, start), "w") as f:
        f.write("#!/bin/bash\n" + script + "\n")
    n += 1
print(n)
PY
}

# sc2015_shape <script>: print the joined logical lines holding both && and
# || (shellcheck SC2015 is `A && B || C`: C also runs when B fails). This is a
# conservative backstop for CI's shellcheck 0.9 (the hosted actionlint is the
# real gate): quotes, heredocs, `;`, $( ) and [[ ]] are not parsed, so it may
# over-flag; a flagged line is rewritten as an explicit if/then. A line ending
# in && || | or \ (an inline comment after && || | allowed) continues onto the
# next; comment-only lines, and blank lines inside a join, are skipped
# without ending the joined line.
sc2015_shape() {
  python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
logical, cur = [], ""
for line in text.split("\n"):
    if re.match(r"^\s*#", line):
        continue
    # A blank line inside an open join (after a trailing && || |) does not
    # end the command in bash, so it does not end the joined line either.
    if cur and not line.strip():
        continue
    cur += line + " "
    if re.search(r"(&&|\|\||\|)\s*(#.*)?$", line) or re.search(r"\\$", line):
        continue
    logical.append(cur)
    cur = ""
logical.append(cur)
for l in logical:
    if "&&" in l and "||" in l:
        print(l.strip())
PY
}

# lint_flags_shape <workflow>: lint_runs fails on <workflow> (nonzero status)
# and reports the SC2015 shape; either alone is not enough.
lint_flags_shape() {
  local out rc=0
  out=$(lint_runs "$1" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || return 1
  case $out in *"has the SC2015 shape"*) return 0 ;; *) return 1 ;; esac
}

# lint_runs <workflow>: every run: script is free of the SC2015 shape (which
# CI's actionlint + shellcheck 0.9 report as info and fail on, while a newer
# local shellcheck does not) and passes shellcheck -S info. If shellcheck is
# not installed, that is FATAL when CI or GITHUB_ACTIONS is set, and an
# explicit SKIP of the shellcheck part otherwise.
lint_runs() {
  local d f bad=0 hits sc=1
  if ! command -v shellcheck >/dev/null 2>&1; then
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "FATAL: shellcheck is required to lint run: scripts under CI" >&2
      return 1
    fi
    echo "SKIP: shellcheck not installed; ${1##*/} run: scripts get the SC2015 shape check only" >&2
    sc=0
  fi
  d=$(mktemp -d)
  run_scripts "$1" "$d" >/dev/null || { rm -rf "$d"; return 1; }
  for f in "$d"/*.sh; do
    [ -e "$f" ] || continue
    hits=$(sc2015_shape "$f")
    if [ -n "$hits" ]; then
      printf '%s: run: at line %s has the SC2015 shape (A && B || C):\n%s\n' "${1##*/}" "$(basename "$f" .sh)" "$hits" >&2
      bad=1
    fi
    if [ "$sc" = 1 ] && ! shellcheck -S info -s bash "$f" >&2; then
      echo "${1##*/}: run: at line $(basename "$f" .sh) has shellcheck findings" >&2
      bad=1
    fi
  done
  rm -rf "$d"
  return "$bad"
}
