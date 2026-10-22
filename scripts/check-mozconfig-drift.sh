#!/usr/bin/env bash
# Fail unless ./mozconfig is byte-identical to NightMonkey's
# spidermonkey/mozconfig at the SHA in NIGHTMONKEY_PIN (until slice B deletes
# NightMonkey's copy).
#   NM_REPO=<path>  read it from that NightMonkey checkout (git show <pin>:...)
#   unset           fetch it from GitHub with `gh api` (NM_SLUG, default YurtOS/nightmonkey)
# PQ_ROOT overrides the repository root (tests use it).
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
SRC=spidermonkey/mozconfig

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

[ -f "$ROOT/mozconfig" ] || { echo "drift: no $ROOT/mozconfig" >&2; exit 1; }
[ -f "$ROOT/NIGHTMONKEY_PIN" ] || { echo "drift: no $ROOT/NIGHTMONKEY_PIN" >&2; exit 1; }
pin=$(tr -d '[:space:]' <"$ROOT/NIGHTMONKEY_PIN")
case $pin in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#pin}" -eq 40 ] ;;
  *) false ;;
esac || { echo "drift: NIGHTMONKEY_PIN must hold one full 40-hex SHA" >&2; exit 1; }

if [ -n "${NM_REPO:-}" ]; then
  theirs=$(git -C "$NM_REPO" show "$pin:$SRC" | sha256 | cut -d' ' -f1) ||
    { echo "drift: cannot read $SRC at $pin in $NM_REPO" >&2; exit 1; }
else
  theirs=$(gh api -H 'Accept: application/vnd.github.raw' \
    "repos/${NM_SLUG:-YurtOS/nightmonkey}/contents/$SRC?ref=$pin" | sha256 | cut -d' ' -f1) ||
    { echo "drift: cannot fetch $SRC at $pin from GitHub" >&2; exit 1; }
fi
mine=$(sha256 <"$ROOT/mozconfig" | cut -d' ' -f1)

if [ "$mine" != "$theirs" ]; then
  echo "drift: mozconfig drift: this repo $mine, NightMonkey $SRC at $pin is $theirs" >&2
  exit 1
fi
echo "drift: mozconfig matches NightMonkey $pin ($mine)"
