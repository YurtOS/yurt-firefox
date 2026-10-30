# Baseline qualification (slice A, Task 10)

Result: the engine built from the patch queue is byte-identical to the engine
built from the fork (same build path), and NightMonkey passes against the queue
build with the same totals as the baseline CI run.

## Setup

- Box: EC2 c7a.8xlarge ( 32 vCPU, 61 GiB, Ubuntu 24.04, kernel 7.0.0-1014-aws), 2026-10-22.
- NightMonkey `ffb918ff3c26415f69d877f47e622cdf3196ed1a` (detached checkout).
- Fork engine (A): `YurtOS/firefox@dff5cf5344484c56babebf9b2495c400c03e3538` (shallow fetch of that SHA, as engine.yml does).
- Queue engine (B): this repository at `bcb94b8074374c2300846b7df4000a7b042945fe` (`feat/build-engine`), `scripts/build-engine.sh --workdir <fresh dir>`; manifest: tag `FIREFOX_147_0_4_RELEASE`, commit `310a0cc30b21`, queue sha256 `457bec9a...2ed49`, rustc 1.98.1 (48a229cea 2026-09-01).
- Toolchains: engine.yml steps replicated: Rust 1.98.1 with `wasm32-wasip1` and `rust-src` (`RUSTUP_TOOLCHAIN=1.98.1`, since the fork checkout is not under NightMonkey's `rust-toolchain.toml`), `./mach --no-interactive bootstrap --application-choice=js`, then `mach artifact toolchain --from-build sysroot-wasm32-wasi` from `~/.mozbuild`. Extra packages: `cmake` 3.28.3, `ninja-build` (apt). sccache was not used (not in the mozconfig).
- Wasm runner for every NightMonkey step below: NightMonkey's own
  `wasm-jit-runner`, built by `cmake --build build` from the `ffb918ff3c26`
  checkout (`build/bin/inproc-shell.sh` runs the guest under it). It links the
  `wasmtime` crate 45.0.3, per that commit's `Cargo.lock`. The binary's sha256
  was not recorded. No standalone `wasmtime` CLI was used here. The wasmtime
  50.0.0 CLI (`wasmtime-v50.0.0-x86_64-linux.tar.xz`, sha256
  `77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff`) belongs
  to the Task 8 `dist/bin/js` smoke test, not to this qualification.
- A was built with NightMonkey's own `scripts/build-spidermonkey.sh <checkout>` (mozconfig `spidermonkey/mozconfig`, which is identical to this repo's `mozconfig`); B with `build-engine.sh` (`MOZCONFIG=<repo>/mozconfig ./mach build`).

## dist comparison

`(cd obj-nightmonkey-sm/dist && find . | sort)`: both lists have 2,590 entries
and `diff` is empty (`baseline/dist-files.txt` is that list; no separate
queue list is needed).

sha256 of `lib/*.a` and `bin/js`:

| Build path | | libjs_static.a | libjsrust.a | libjsshell.a | libpure_virtual.a | bin/js |
|---|---|---|---|---|---|---|
| different (`~/qual/fork` vs `~/qual/qfirefox`) | A | 444a449d... | 66f1ed54... | 6dadc258... | b4ecb8f6... | 162c527b... |
| | B | 68fc21a6... | 8b16823d... | e22a408f... | b4ecb8f6... | 8fe6e7a0... |
| **same** (`~/qual/ff` for both, A first, then moved aside) | A | b48d2637... | 2f91cf56... | 65b19a30... | b4ecb8f6... | cc0b24c8... |
| | B | b48d2637... | 2f91cf56... | 65b19a30... | b4ecb8f6... | cc0b24c8... |

Full digests: `sha256sum` of the same-path run is

```
b48d263749fddaf6381a87e7ebfe79b4b12bc8aa74b8cbafa8c2b0488eeb5138  lib/libjs_static.a
2f91cf5696d378f0d6aa0da0b2d9baf18782a912d35a6fc8f8da50e2f745ae01  lib/libjsrust.a
65b19a306ec298b002db827b30fc6863f054d32a4017743c44e08b8d5e375474  lib/libjsshell.a
b4ecb8f6a1c2417113f4759fd076b0ffd43ac0c808918a8f3160d9c4deac1bea  lib/libpure_virtual.a
cc0b24c8e5654214be766efadbae4549876282956ad8f7b64101d569145dbd73  bin/js
```

for both A and B (`diff` empty). With different checkout paths, the archives
and `bin/js` differ in the expected way (absolute source/object paths are
embedded); `libpure_virtual.a` has no paths and matched even then. The
same-path rebuild removes that cause and the outputs are byte-identical, so
there is no difference other than the build path. (Builds took about 1 to 3
minutes each with warm `~/.mozbuild`.)

## NightMonkey against the queue build

`cmake -S . -B build -DSPIDERMONKEY_DIST=$HOME/qual/ff/obj-nightmonkey-sm/dist`,
`cmake --build build`, `build/bin/inproc-shell.sh` present. The queue tree
(`~/qual/ff`, the `build-engine.sh` workdir) is `~/qual/nm/firefox` (symlink),
the tree `ci-suite.sh` reads jit-tests from. At that point `~/qual/ff` held B
from the same-path pair (A had been built there first and moved aside), so the
artifact under test is the same-path B whose digests are listed above. The
different-path B (`~/qual/qfirefox`) was not tested against NightMonkey. Steps
in engine.yml order, lane
`both` (`CI_LANE=both`, `RUNNER_TEMP=~/qual/logs`):

| Step | Result | Baseline run | Time |
|---|---|---|---|
| `scripts/test-guest-tier-options.py build` | all 8 PASS (guest mir, guest baseline, invalid options, block census, direct eval, large function, accessor, onramp fixture) | all PASS | 5 s |
| `scripts/ci-suite.sh local both` | aot: 131 passed, 0 failed; interpreter: 131 passed, 0 failed | 131/0, 131/0 | 82 s |
| tier regressions (`--pipeline baseline --strict-coverage`; `--pipeline mir --mir-stress 3 --strict-coverage`) | 131 passed, 0 failed; 131 passed, 0 failed | 131/0, 131/0 | 90 s |
| `scripts/ci-suite.sh jit both`, aot lane | PASSED ALL: 12906 passed, 0 failed (night: 12307 passing execution results verified) | 12906/0 (12307) | 270 s (one run, both lanes) |
| `scripts/ci-suite.sh jit both`, interpreter lane | PASSED ALL: 13095 passed, 0 failed (night: 12494 passing execution results verified) | 13095/0 (12494) | (same run as above) |

"aot" here is NightMonkey's lane name. In that lane NightMonkey compiles the
guest's JavaScript to Wasm (`--night-inprocess`). The interpreter lane runs the
same binary without it. The name has nothing to do with SpiderMonkey's AOT IC
corpus: the mozconfig does not pass `--enable-aot-ics`, so the corpus
(`data/ics`, laid in as `js/src/ics`) is not read by this build (see
PROVENANCE.md). A and B carry the same corpus, so their byte-identity does not
by itself show that the corpus is inert. That rests on the flag being off.

Every total equals the baseline CI run. Full jstests are not part of the
baseline and were not run. Logs on the box: `~/qual/logs/*.log` and
`~/qual/logs/nightmonkey-logs/{local,jit}-{aot,interpreter}.log`, step driver
`~/qual/steps.log`, build logs `~/qual/{A,B,B2}.log`.

## Notes

- A first same-path attempt ran out of disk (38 GB volume, each objdir tree is
  about 5.5 GB); the partial tree and stale builds were deleted and B was
  rebuilt into a fresh directory. The results above come from complete runs only.
- B was built with `build-engine.sh` as of `bcb94b8`. Later changes to it (PR #4
  review: the applied tree must equal UPSTREAM's `tree=`, the manifest is written
  by python3 and also records `tree` and `ics_path`, the caller's git environment
  is cleaned for mach, hermetic `pq_git` in the library) do not touch the build
  inputs: `UPSTREAM`, `patches/`, `data/ics`, `mozconfig` and `NIGHTMONKEY_PIN`
  are unchanged since `bcb94b8`, and the current `dir_hash` gives the same queue
  sha256 (`457bec9a...2ed49`). B has not been rebuilt with the current script.
