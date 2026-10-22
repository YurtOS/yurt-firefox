#!/usr/bin/env bash
# Build SpiderMonkey for wasm32-wasi from the pinned tag + patch queue + data/ics.
#   build-engine.sh [--workdir DIR] [--dry-run]
# DIR defaults to ${GITHUB_WORKSPACE:-$PWD}/firefox and must not exist or must be
# empty. The patched tree left there is the test-source tree NightMonkey's
# ci-suite.sh runs jit-tests/jstests from (never the bare tag). build-manifest.json
# is written next to DIR. --dry-run does fetch + apply + manifest only: no
# toolchain bootstrap, no mach.
# PQ_ROOT overrides the repository root (tests use it).
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=${PQ_ROOT:-$SELF}
# shellcheck source=lib/patch-queue.sh
. "$SELF/scripts/lib/patch-queue.sh"

# Rust per NightMonkey's rust-toolchain.toml.
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
  (cd "$dir" && find . "$@" -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 <"$f" | cut -d' ' -f1)" "${f#./}"
  done) | sha256 | cut -d' ' -f1
}

step() { echo "build-engine: $*"; }

pq_read_pin "$ROOT/UPSTREAM"

step "fetch $PQ_TAG ($PQ_COMMIT) into $workdir"
pq_fetch "$workdir"
step "apply patches/ and data/ics"
pq_apply "$workdir" "$ROOT/patches" "$ROOT/data/ics"
workdir=$(cd "$workdir" && pwd -P)

toolchain_json=
if [ "$dry" -eq 1 ]; then
  step "toolchain bootstrap skipped (dry run)"
  step "mach build skipped (dry run)"
else
  step "rust $RUST_VERSION"
  rustup toolchain install "$RUST_VERSION" --profile minimal
  case $(uname -s) in
    Darwin) clang=macosx64-clang ;;
    *) clang=linux64-clang ;;
  esac
  step "toolchain bootstrap: $clang $SYSROOT_ARTIFACT"
  log=$(mktemp)
  (cd "$workdir" && ./mach artifact toolchain --from-build "$clang" --from-build "$SYSROOT_ARTIFACT") 2>&1 | tee "$log"
  # The artifact names and the digests of the files mach downloaded into the
  # state dir (matched by artifact name).
  state=${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}
  for name in "$clang" "$SYSROOT_ARTIFACT"; do
    digest=
    file=$(find "$state" -type f -name "*${name}*" 2>/dev/null | LC_ALL=C sort | head -n 1)
    [ -z "$file" ] || digest=$(sha256 <"$file" | cut -d' ' -f1)
    toolchain_json="${toolchain_json:+$toolchain_json, }{\"name\": \"$name\", \"sha256\": \"$digest\"}"
  done
  rm -f "$log"
  step "mach build"
  (cd "$workdir" && MOZCONFIG="$ROOT/mozconfig" ./mach build)
fi

manifest=$(dirname "$workdir")/build-manifest.json
printf '{\n  "tag": "%s",\n  "commit": "%s",\n  "queue_sha256": "%s",\n  "data_ics_sha256": "%s",\n  "mozconfig_sha256": "%s",\n  "toolchain_artifacts": [%s],\n  "rust_version": "%s"\n}\n' \
  "$PQ_TAG" "$PQ_COMMIT" \
  "$(dir_hash "$ROOT/patches" -maxdepth 1 -name '*.patch')" \
  "$(dir_hash "$ROOT/data/ics")" \
  "$(sha256 <"$ROOT/mozconfig" | cut -d' ' -f1)" \
  "$toolchain_json" "$RUST_VERSION" >"$manifest"
step "wrote $manifest"
