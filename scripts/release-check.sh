#!/usr/bin/env bash
# release.yml's check-tag guards.
#   release-check.sh tag <tag>
#     <tag> must be engine-v<version>-<n> (version: dotted numbers; n: 1, 2,
#     ... without leading zeros) and <version> UPSTREAM's Firefox version
#     (FIREFOX_147_0_4_RELEASE -> 147.0.4). Prints version=, revision= and
#     tag= lines, also to $GITHUB_OUTPUT when set (only on success).
#   release-check.sh nightmonkey <dir>
#     <dir> is a full-history NightMonkey clone with yurt checked out.
#     RELEASE_REQUIRES_NIGHTMONKEY (the NightMonkey commit that can consume
#     packages) must be an ancestor of NIGHTMONKEY_PIN, and the pin an
#     ancestor of the clone's HEAD (yurt). Both files hold one full 40-hex
#     SHA. A shallow clone cannot prove ancestry and is refused.
# git runs through pq_git. PQ_ROOT overrides the repository root (tests).
# Exit codes: 0 ok; 1 refused; 2 usage or a missing clone.
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"
# shellcheck source=lib/package-contract.sh
. "$SELF/scripts/lib/package-contract.sh"

usage() {
  echo "usage: release-check.sh tag <tag> | nightmonkey <dir>" >&2
  exit 2
}
die() { echo "release-check: $*" >&2; exit 1; }

# read_sha <file>: the file's one line, which must be a full 40-hex SHA.
read_sha() {
  local f=$1 v n
  [ -f "$f" ] || die "${f##*/}: missing"
  n=$(wc -l <"$f" | tr -d ' ')
  v=$(cat "$f")
  [ "$n" = 1 ] || die "${f##*/} must hold one line, has $n"
  [[ $v =~ ^[0-9a-f]{40}$ ]] || die "${f##*/} must hold one full 40-hex SHA, got '$v'"
  printf '%s\n' "$v"
}

check_tag() {
  local tag=$1 version revision upstream_version
  [[ $tag =~ ^engine-v([0-9]+(\.[0-9]+)+)-([1-9][0-9]*)$ ]] ||
    die "tag '$tag' is not engine-v<version>-<n> (e.g. engine-v147.0.4-1)"
  version=${BASH_REMATCH[1]}
  revision=${BASH_REMATCH[3]}
  pq_read_pin "$ROOT/UPSTREAM" || exit 1
  upstream_version=$(pc_firefox_version "$PQ_TAG") || exit 1
  [ "$version" = "$upstream_version" ] ||
    die "tag '$tag' names version $version; UPSTREAM pins $PQ_TAG ($upstream_version)"
  local out
  out=$(printf 'version=%s\nrevision=%s\ntag=%s' "$version" "$revision" "$tag")
  printf '%s\n' "$out"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$out" >>"$GITHUB_OUTPUT"
  fi
}

# ancestor <dir> <a> <b> <what>: <a> is an ancestor of <b> in <dir>, or fail
# with <what> (status 1 is "not an ancestor"; anything else, an unknown commit).
ancestor() {
  local rc=0
  pq_git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null || rc=$?
  case $rc in
    0) ;;
    1) die "$4" ;;
    *) die "$4 (git exited $rc: is $2 or $3 missing from the clone?)" ;;
  esac
}

check_nightmonkey() {
  local dir=$1 required pin head shallow
  [ -d "$dir" ] || { echo "release-check: no NightMonkey clone at $dir" >&2; exit 2; }
  required=$(read_sha "$ROOT/RELEASE_REQUIRES_NIGHTMONKEY") || exit 1
  pin=$(read_sha "$ROOT/NIGHTMONKEY_PIN") || exit 1
  shallow=$(pq_git -C "$dir" rev-parse --is-shallow-repository) || die "$dir is not a git repository"
  [ "$shallow" = false ] || die "$dir is a shallow clone; ancestry needs full history (fetch-depth: 0)"
  head=$(pq_git -C "$dir" rev-parse --verify 'HEAD^{commit}') || die "$dir has no HEAD"
  ancestor "$dir" "$required" "$pin" "RELEASE_REQUIRES_NIGHTMONKEY $required is not an ancestor of NIGHTMONKEY_PIN $pin"
  ancestor "$dir" "$pin" "$head" "NIGHTMONKEY_PIN $pin is not on NightMonkey's yurt ($head)"
  echo "release-check: NIGHTMONKEY_PIN $pin contains RELEASE_REQUIRES_NIGHTMONKEY $required and is on yurt"
}

[ $# -eq 2 ] || usage
case $1 in
  tag) check_tag "$2" ;;
  nightmonkey) check_nightmonkey "$2" ;;
  *) usage ;;
esac
