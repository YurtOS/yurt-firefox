# yurt-firefox

The SpiderMonkey engine that [Yurt](https://github.com/YurtOS) builds on, kept
as a patch queue on an unmodified Firefox release.

Yurt is a Linux-compatible kernel compiled to WebAssembly; it runs a Linux
sandbox (a shell, CPython, Jupyter) inside a browser tab or natively on your
machine. Try it at <https://yurt-playground.pages.dev>.

## What this is

This repository carries an ordered queue of patches against
[Mozilla Firefox](https://github.com/mozilla-firefox/firefox) at one pinned
release tag (see [`UPSTREAM`](UPSTREAM)), plus the scripts that apply, verify,
export and build it. Only the `js/` engine (SpiderMonkey) matters; there is no
browser GUI. It replaces a fork of the whole Firefox tree, so a Firefox bump is
a rebase of a few patches instead of a history merge.

The queue ([`patches/`](patches/)) adds:

- the JS Streams builtin, and JSAPI to reset the `Math.random` seed and to query
  pending jobs;
- Wizer pre-initialisation and weval annotations for the JS shell on WASI, with
  the vendored `weval.h` and `wizer.h` headers;
- external-compiler hooks (`--enable-external-compiler-hooks`) that a
  compilation tier outside the engine plugs into;
- build fixes for the WASI target and for `wasm32-yurt-linux-musl` (Yurt);
- jit-test harness fixes.

[`PROVENANCE.md`](PROVENANCE.md) records where each patch came from, and
[`data/ics/`](data/ics/) holds the ahead-of-time IC corpus that the build copies
into the engine tree.

## How it relates to NightMonkey

[NightMonkey](https://github.com/YurtOS/nightmonkey) is an ahead-of-time and
in-process JavaScript-to-WebAssembly compiler layered on SpiderMonkey. It links
against the engine this queue builds and uses the external-compiler hooks the
queue adds. NightMonkey pins a commit of this repository (`engine/QUEUE_PIN`
there), and this repository pins a NightMonkey commit
([`NIGHTMONKEY_PIN`](NIGHTMONKEY_PIN)): CI builds the queue engine, builds
NightMonkey against it and runs SpiderMonkey's jit-tests, so a patch that breaks
NightMonkey fails here first.

## Building

```sh
scripts/build-engine.sh --workdir /path/to/firefox
# -> /path/to/firefox/obj-nightmonkey-sm/dist, /path/to/build-manifest.json
```

`build-engine.sh` fetches the pinned tag, applies the queue strictly together
with `data/ics/`, checks the patched tree against the tree hash in `UPSTREAM`,
bootstraps the toolchains and runs `./mach build` with [`mozconfig`](mozconfig)
for `wasm32-wasi`. A full build runs on a Linux x86_64 build host only;
`--dry-run` stops after patching the tree and writing the manifest, and also
works elsewhere. The work directory must be empty or absent, and an
existing `build-manifest.json` next to it is refused rather than overwritten.

`scripts/check-queue.sh` applies the queue to a fresh fetch and compares the
tree hash, and `scripts/check-queue.sh --fixtures` runs the script test suites;
both run in CI.

## Status

Pre-1.0: no compatibility guarantees yet. The engine is built for Yurt and
tracked against NightMonkey; it is not a general-purpose SpiderMonkey
distribution.

## License

Firefox and the files the patches change are licensed under the
[Mozilla Public License 2.0](LICENSE); patches that touch MPL files keep those
files' licence headers. The queue also adds third-party files under other
licences (the weval and wizer headers, Apache-2.0 WITH LLVM-exception); their
licence texts are added by the same patch, next to the files. See
[`NOTICE`](NOTICE) for the list.

## Contact

Open an issue in this repository, or reach the maintainers through their GitHub
profiles: [Sunny](https://github.com/smarcd) and
[Ofer](https://github.com/ofersa).
