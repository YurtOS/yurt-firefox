#!/usr/bin/env bash
# Build SpiderMonkey for wasm32-wasi from the pinned tag + patch queue + data/ics.
#   build-engine.sh [--workdir DIR] [--dry-run]
# DIR defaults to ${GITHUB_WORKSPACE:-$PWD}/firefox and must not exist or must be
# empty. The patched tree left there is the test-source tree NightMonkey's
# ci-suite.sh runs jit-tests/jstests from (never the bare tag). build-manifest.json
# is written next to DIR (in DIR's parent); an existing one there is refused, not
# overwritten. python3 writes it, so it is needed for a dry run too. --dry-run does fetch + apply + manifest only: no
# toolchain bootstrap, no mach.
# The applied tree must equal UPSTREAM's tree=, as check-queue requires; the
# manifest records it and the corpus path. Exit codes: 0 ok, 1 failed, 2 UPSTREAM
# not initialised or bad usage.
# PQ_ROOT overrides the repository root and PQ_ICS_PATH the corpus path (tests
# use them).
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

# Rust per NightMonkey's rust-toolchain.toml; wasm32-wasip1 and rust-src as in its CI.
RUST_VERSION=1.98.1
SYSROOT_ARTIFACT=sysroot-wasm32-wasi

workdir=${GITHUB_WORKSPACE:-$PWD}/firefox
dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --workdir) [ $# -ge 2 ] || { echo "usage: build-engine.sh [--workdir DIR] [--dry-run]" >&2; exit 2; }
      workdir=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: build-engine.sh [--workdir DIR] [--dry-run]" >&2; exit 2 ;;
  esac
done

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

# dir_hash <dir> <find-args...>: sha256 over the sorted "<sha256>  <relpath>"
# lines of the matching files.
dir_hash() {
  local dir=$1
  shift
  [ -d "$dir" ] || { echo "build-engine: no such directory: $dir" >&2; return 1; }
  (cd "$dir" && find . "$@" -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 <"$f" | cut -d' ' -f1)" "${f#./}"
  done) | sha256 | cut -d' ' -f1
}

step() { echo "build-engine: $*"; }

ZERO=0000000000000000000000000000000000000000
ICS_PATH=${PQ_ICS_PATH:-js/src/ics}

pq_read_pin "$ROOT/UPSTREAM"
case $PQ_URL in *example.invalid*) PQ_COMMIT=$ZERO ;; esac
if [ "$PQ_COMMIT" = "$ZERO" ] || [ "$PQ_TREE" = "$ZERO" ]; then
  echo "build-engine: UPSTREAM not initialised (placeholder values)" >&2
  exit 2
fi

manifest=$(dirname "$workdir")/build-manifest.json
if [ -e "$manifest" ] || [ -L "$manifest" ]; then
  echo "build-engine: $manifest exists; move it away first" >&2
  exit 1
fi

step "fetch $PQ_TAG ($PQ_COMMIT) into $workdir"
pq_fetch "$workdir"
step "apply patches/ and data/ics"
PQ_ICS_PATH=$ICS_PATH pq_apply "$workdir" "$ROOT/patches" "$ROOT/data/ics"
tree=$(pq_tree "$workdir")
[ "$tree" = "$PQ_TREE" ] ||
  { echo "build-engine: tree mismatch: UPSTREAM says $PQ_TREE, applied queue is $tree" >&2; exit 1; }
step "tree ok ($tree)"
workdir=$(cd "$workdir" && pwd -P)

toolchain_json='[]'
rust_version=
if [ "$dry" -eq 1 ]; then
  step "toolchain bootstrap skipped (dry run)"
  step "mach build skipped (dry run)"
else
  # Mirrors NightMonkey's engine.yml (Install Rust, Bootstrap SpiderMonkey).
  [ "$(uname -s)" = Linux ] || { echo "build-engine: real builds are Linux only" >&2; exit 1; }
  step "rust $RUST_VERSION"
  rustup toolchain install "$RUST_VERSION" --profile minimal \
    -c rustfmt -c clippy -c rust-src -t wasm32-wasip1
  export RUSTUP_TOOLCHAIN=$RUST_VERSION
  rust_version=$(rustc --version)
  case $rust_version in "rustc $RUST_VERSION "*) ;; *)
    echo "build-engine: rustc is '$rust_version', want $RUST_VERSION" >&2; exit 1 ;; esac

  # Host toolchains (clang, sysroot, cbindgen, ...) come from mach bootstrap; it
  # writes <workdir>/mozconfig, which MOZCONFIG below overrides, so drop it.
  step "mach bootstrap (js)"
  (cd "$workdir" && ./mach --no-interactive bootstrap --application-choice=js)
  rm -f "$workdir/mozconfig"
  # Bootstrap fetches host-target toolchains only; the wasm32-wasi sysroot is
  # fetched explicitly. mach unpacks into the cwd, so run it from the state dir.
  # The artifact manifest records the URL and sha256 of what was fetched; the
  # clang is the one bootstrap already installed (same cached artifact).
  state=${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}
  # mach keeps only the last build's entry in --artifact-manifest, so fetch one
  # at a time into separate manifests.
  artifacts=$(mktemp -d)
  trap 'rm -rf "$artifacts"' EXIT
  for name in linux64-clang "$SYSROOT_ARTIFACT"; do
    step "artifact toolchain: $name"
    (cd "$state" && "$workdir/mach" --log-no-times artifact toolchain \
      --from-build "$name" --artifact-manifest "$artifacts/$name.json")
  done
  toolchain_json=$(python3 - "$artifacts" <<'PY'
import glob, json, sys
out = []
for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    for url, info in sorted(json.load(open(f)).items()):
        digest = info.get("sha256", "")
        if len(digest) != 64:
            sys.exit("build-engine: no sha256 for " + url)
        out.append({"name": url.rsplit("/", 1)[1], "url": url, "sha256": digest})
if len(out) != 2:
    sys.exit("build-engine: expected 2 toolchain artifacts, mach recorded %d" % len(out))
print(json.dumps(out))
PY
  ) || exit 1
  step "mach build"
  (cd "$workdir" && MOZCONFIG="$ROOT/mozconfig" ./mach build)
fi

queue_hash=$(dir_hash "$ROOT/patches" -maxdepth 1 -name '*.patch')
ics_hash=$(dir_hash "$ROOT/data/ics")
mozconfig_hash=$(sha256 <"$ROOT/mozconfig" | cut -d' ' -f1)
python3 - "$manifest" "$PQ_TAG" "$PQ_COMMIT" "$tree" "$ICS_PATH" "$queue_hash" "$ics_hash" \
  "$mozconfig_hash" "$toolchain_json" "$rust_version" <<'PY'
import json, sys
path, tag, commit, tree, ics_path, queue, ics, mozconfig, toolchain, rust = sys.argv[1:]
m = {"tag": tag, "commit": commit, "tree": tree, "ics_path": ics_path,
     "queue_sha256": queue, "data_ics_sha256": ics, "mozconfig_sha256": mozconfig,
     "toolchain_artifacts": json.loads(toolchain), "rust_version": rust}
with open(path, "x") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
step "wrote $manifest"
