#!/usr/bin/env bash
# Patch queue library: read the upstream pin, fetch it, apply the queue and
# report the resulting tree. Source it; it defines functions only.
#
# Functions return non-zero with a "pq:" message on stderr instead of relying on
# `set -e`, which does not apply inside callers' `if`/`||` contexts. None of them
# reset, clean or check out a tree the caller supplied.
#
# Every git call, here and in the scripts, goes through pq_git. The tree hash and
# the patch bytes must be the same for every developer and for CI, and plain git
# lets the caller change both: an exported GIT_DIR, GIT_WORK_TREE or
# GIT_INDEX_FILE (hooks and dotfile setups export them) makes `git -C <dir>` act
# on another repository, and user, system or `-c` config (apply.whitespace,
# apply.ignoreWhitespace, format.suffix, format.thread, core.autocrlf,
# core.excludesFile, status.showUntrackedFiles, diff.orderFile, ...) changes what
# apply, am, status, add and format-patch do. pq_git clears the
# repository-selection environment, ignores user and system config, and sets the
# keys that matter with -c, which also wins over a repository's own config.

# pq_git <git args...>: git with no inherited repository selection or config.
pq_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_NO_REPLACE_OBJECTS \
    GIT_REPLACE_REF_BASE GIT_CEILING_DIRECTORIES GIT_TEMPLATE_DIR \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1
  exec git -c core.autocrlf=false -c core.safecrlf=false -c core.quotePath=false \
    -c core.excludesFile=/dev/null -c core.attributesFile=/dev/null \
    -c apply.whitespace=nowarn -c apply.ignoreWhitespace=no \
    -c status.showUntrackedFiles=all -c diff.orderFile=/dev/null \
    -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c format.signOff=false -c format.thread=false -c format.suffix=.patch "$@"
)

# pq_read_pin <upstream-file>: set PQ_URL PQ_TAG PQ_COMMIT PQ_TREE from key=value lines.
pq_read_pin() {
  local file=$1 key value
  PQ_URL= PQ_TAG= PQ_COMMIT= PQ_TREE=
  [ -f "$file" ] || { echo "pq: no upstream file: $file" >&2; return 1; }
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case $key in
      url) PQ_URL=$value ;;
      tag) PQ_TAG=$value ;;
      commit) PQ_COMMIT=$value ;;
      tree) PQ_TREE=$value ;;
      '' | '#'*) ;;
      *) echo "pq: unknown key in $file: $key" >&2; return 1 ;;
    esac
  done <"$file"
  [ -n "$PQ_URL" ] && [ -n "$PQ_TAG" ] && [ -n "$PQ_COMMIT" ] && [ -n "$PQ_TREE" ] ||
    { echo "pq: $file must set url, tag, commit and tree" >&2; return 1; }
}

# Repository root of this library, for the default lists directory.
PQ_LIB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

# pq_fetch <dest>: shallow-fetch PQ_TAG into a new repo at <dest>; fail if it
# is not PQ_COMMIT. <dest> must not exist or must be an empty directory.
pq_fetch() {
  local dest=$1 head
  if [ -e "$dest" ] && { [ ! -d "$dest" ] || [ -n "$(ls -A "$dest")" ]; }; then
    echo "pq: destination is not empty: $dest" >&2
    return 1
  fi
  pq_git init -q "$dest" || return 1
  pq_git -C "$dest" fetch -q --depth 1 "$PQ_URL" tag "$PQ_TAG" || return 1
  pq_git -C "$dest" checkout -q --detach FETCH_HEAD || return 1
  head=$(pq_git -C "$dest" rev-parse HEAD) || return 1
  [ "$head" = "$PQ_COMMIT" ] ||
    { echo "pq: tag $PQ_TAG is $head, pinned commit is $PQ_COMMIT" >&2; return 1; }
}

# pq_apply <worktree> <patches-dir> <data-ics-dir>: apply the queue, then lay
# the corpus over $PQ_ICS_PATH (default js/src/ics) and stage it. A failed
# pq_apply can leave <worktree> partially patched and dirty; the caller must
# discard it (delete the clone) and must not retry on it.
pq_apply() {
  local wt patches ics ics_path patch top mine status
  wt=$(cd "$1" 2>/dev/null && pwd -P) || { echo "pq: no such worktree: $1" >&2; return 1; }
  patches=$(cd "$2" 2>/dev/null && pwd -P) || { echo "pq: no such patches dir: $2" >&2; return 1; }
  ics=$(cd "$3" 2>/dev/null && pwd -P) || { echo "pq: no such corpus dir: $3" >&2; return 1; }
  ics_path=${PQ_ICS_PATH:-js/src/ics}

  top=$(pq_git -C "$wt" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) ||
    { echo "pq: $wt is not a git worktree" >&2; return 1; }
  [ "$top" = "$wt" ] || { echo "pq: $wt is not a repository toplevel" >&2; return 1; }
  if mine=$(pq_git rev-parse --show-toplevel 2>/dev/null); then
    mine=$(cd "$mine" && pwd -P)
    [ "$mine" != "$wt" ] || { echo "pq: refusing the caller's repository: $wt" >&2; return 1; }
  fi
  [ "$(pq_git -C "$wt" rev-parse HEAD)" = "$PQ_COMMIT" ] ||
    { echo "pq: $wt is not at pinned commit $PQ_COMMIT" >&2; return 1; }
  status=$(pq_git -C "$wt" status --porcelain --untracked-files=all) ||
    { echo "pq: cannot read the status of $wt" >&2; return 1; }
  [ -z "$status" ] || { echo "pq: $wt is not clean" >&2; return 1; }

  while IFS= read -r patch; do
    pq_git -C "$wt" apply --index --whitespace=nowarn "$patch" ||
      { echo "pq: failed to apply $patch" >&2; return 1; }
  done < <(find "$patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)

  mkdir -p "$wt/$ics_path" || return 1
  cp -R "$ics/." "$wt/$ics_path/" || return 1
  pq_git -C "$wt" add -- "$ics_path" || return 1
}

# pq_tree <worktree>: print the tree hash of the index.
pq_tree() {
  pq_git -C "$1" write-tree
}

# pq_classify <path>: print "include" or "exclude" for the longest prefix in
# $PQ_LISTS_DIR (default <root>/lists) include.txt/exclude.txt that matches
# <path> on whole path components; exit 2 if none does.
pq_classify() {
  local path=$1 dir=${PQ_LISTS_DIR:-$PQ_LIB_ROOT/lists} class prefix best= best_len=-1
  for class in include exclude; do
    [ -f "$dir/$class.txt" ] || { echo "pq: no $dir/$class.txt" >&2; return 1; }
    while IFS= read -r prefix || [ -n "$prefix" ]; do
      case $prefix in '' | '#'*) continue ;; esac
      prefix=${prefix%/}
      case $path in
        "$prefix" | "$prefix"/*)
          if [ "${#prefix}" -gt "$best_len" ]; then
            best=$class best_len=${#prefix}
          fi
          ;;
      esac
    done <"$dir/$class.txt"
  done
  if [ -z "$best" ]; then
    echo "pq: unclassified path: $path" >&2
    return 2
  fi
  echo "$best"
}

# pq_leftover <tag-ref> <yurt-ref> [dom-count]: print the paths changed between
# the refs (in $PQ_DIFF_REPO, default the current directory) that are in neither
# list, and fail if there are any. Also fail unless exactly [dom-count] (default
# 19) changed paths are under dom/.
pq_leftover() {
  local tag=$1 yurt=$2 expected_dom=${3:-19} path leftover= dom=0 rc=0 files
  files=$(pq_git -C "${PQ_DIFF_REPO:-.}" diff --name-only --no-renames "$tag" "$yurt") ||
    { echo "pq: cannot diff $tag $yurt" >&2; return 1; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case $path in dom/*) dom=$((dom + 1)) ;; esac
    pq_classify "$path" >/dev/null 2>&1 || {
      [ $? -eq 2 ] || return 1
      leftover="$leftover$path"$'\n'
    }
  done <<<"$files"
  if [ -n "$leftover" ]; then
    printf '%s' "$leftover"
    echo "pq: paths in $tag..$yurt are in neither include.txt nor exclude.txt" >&2
    rc=1
  fi
  if [ "$dom" -ne "$expected_dom" ]; then
    echo "pq: dom/ file count: expected $expected_dom, found $dom" >&2
    rc=1
  fi
  return $rc
}
