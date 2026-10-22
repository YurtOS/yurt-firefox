# Migration baseline: NightMonkey engine CI run

The fork build that the queue must reproduce (spec, Migration step 3).

| | |
|---|---|
| Run | https://github.com/YurtOS/nightmonkey/actions/runs/39621345954 (workflow `CI`, push to `yurt`, 2026-10-21T14:56:55Z, success) |
| Job | `engine / jit-test` (job 119295294612, `lane: both`) |
| NightMonkey SHA | `ffb918ff3c26415f69d877f47e622cdf3196ed1a` (merged PR #8, `origin/yurt` on 2026-10-22) |
| Engine SHA | `YurtOS/firefox@dff5cf5344484c56babebf9b2495c400c03e3538` (`FIREFOX_REF: yurt`; log: `SpiderMonkey: YurtOS/firefox@dff5cf53...`, `HEAD is now at dff5cf5344`) |
| mozconfig | NightMonkey `spidermonkey/mozconfig`, objdir `obj-nightmonkey-sm` |

Step results in that job:

| Step | Result |
|---|---|
| `scripts/test-guest-tier-options.py build` | all PASS (guest mir, guest baseline, invalid options, block census, direct eval, large function, accessor, onramp fixture) |
| `scripts/ci-suite.sh local both` | aot: night tests 131 passed, 0 failed; interpreter: 131 passed, 0 failed |
| baseline / MIR-stress night tests | `--pipeline baseline --strict-coverage`: 131 passed, 0 failed; `--pipeline mir --mir-stress 3 --strict-coverage`: 131 passed, 0 failed |
| `scripts/ci-suite.sh jit both`, aot lane | jit-test PASSED ALL: 12906 passed, 0 failed (night: 12307 passing execution results verified) |
| `scripts/ci-suite.sh jit both`, interpreter lane | jit-test PASSED ALL: 13095 passed, 0 failed (night: 12494 passing execution results verified) |

The scheduled `Full jstests` workflow on `yurt` was failing at the same time
(runs 39534388550 and 39712757121); it is not part of this baseline.

`dist-files.txt` (the `dist` file list of this build, 2,590 entries) was
captured in Task 10; see [qualification.md](qualification.md).
