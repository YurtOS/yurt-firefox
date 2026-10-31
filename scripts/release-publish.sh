#!/usr/bin/env bash
# Publish a verified release set as a GitHub release (release.yml's publish).
#   release-publish.sh --tag TAG --dir DIR
# GH_REPO (owner/name) and GH_TOKEN come from the environment (the workflow's
# github.token; no other credential). DIR has been checked by
# `release-set.sh verify`. The release is refused if any release with TAG
# exists, a draft included (the listing of an authenticated writer has
# drafts), and a failing listing fails closed instead of reading as "none".
# Then `gh release create TAG --verify-tag` (the tag must already exist on
# GitHub) uploads MANIFEST.json and every file in DIR, in name order.
# Exit codes: 0 published; 1 refused or failed; 2 usage.
set -euo pipefail

usage() {
  [ $# -eq 0 ] || echo "release-publish: $*" >&2
  echo "usage: release-publish.sh --tag TAG --dir DIR (GH_REPO and GH_TOKEN in the environment)" >&2
  exit 2
}
die() { echo "release-publish: $*" >&2; exit 1; }

tag= dir=
while [ $# -gt 0 ]; do
  case $1 in
    --tag | --dir)
      [ $# -ge 2 ] || usage "$1 needs a value"
      if [ "$1" = --tag ]; then tag=$2; else dir=$2; fi
      shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$tag" ] && [ -n "$dir" ] || usage "--tag and --dir are required"
[ -d "$dir" ] || usage "no such directory: $dir"
[ -n "${GH_REPO:-}" ] || usage "GH_REPO is not set"
[[ $GH_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "GH_REPO '$GH_REPO' is not owner/name"
[[ $tag =~ ^engine-v[0-9]+(\.[0-9]+)+-[1-9][0-9]*$ ]] || usage "tag '$tag' is not engine-v<version>-<n>"

listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
if ! gh api --paginate "repos/$GH_REPO/releases" --jq '.[].tag_name' >"$listing"; then
  die "cannot list the releases of $GH_REPO; refusing to publish without knowing $tag is new"
fi
if grep -qxF -- "$tag" "$listing"; then
  die "a release for $tag already exists (possibly a draft); releases are never overwritten"
fi

files=()
while IFS= read -r f; do
  files+=("$dir/$f")
done < <(cd "$dir" && find . -maxdepth 1 -type f | sed 's|^\./||' | LC_ALL=C sort)
[ "${#files[@]}" -gt 0 ] || die "$dir holds no files"

echo "release-publish: creating $tag with ${#files[@]} assets"
gh release create "$tag" --verify-tag --title "$tag" \
  --notes "SpiderMonkey engine release $tag. See MANIFEST.json for the inputs and the digest of every asset." \
  "${files[@]}" || die "gh release create $tag failed"
echo "release-publish: published $tag"
