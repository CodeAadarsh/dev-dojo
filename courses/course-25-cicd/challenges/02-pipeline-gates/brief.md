# Pipeline Gates

The post-incident review found this in the pipeline log:

```
$ make test
.....F
1 failed in 0.42s
make: *** [test] Error 1
```

Wait — it says `Error 1`, but the CI run was green. The on-call engineer pulled the Makefile:

```makefile
test:
    pytest tests/ -q || true
```

There it is. `|| true` turns every `pytest` exit code into 0. The gate that was supposed to catch this regression was not gating. The broken commit merged, and the incident happened. Your job: fix the gates and make CI trustworthy.

## Context

`setup.sh` plants a small project in your work directory:

```
~/.kube-dojo-work/02-pipeline-gates/
├── app.py          # utility functions — contains a bug
├── tests/
│   └── test_app.py # tests that expose the bug
└── Makefile        # lint/test/build defined; 'ci' target missing; test gate broken
```

## Prerequisites

```bash
pip install pytest   # only standard tools needed; make is pre-installed on macOS/Linux
```

## Mission

Make `make ci` exit 0 end-to-end. The verifier will also inject a failing test and confirm `make test` propagates the failure. Three things need fixing:

| What | Where | Fix |
|------|-------|-----|
| Bug in source | `app.py` | find and fix the failing function |
| Broken gate | `Makefile` `test:` target | remove the failure-swallowing idiom |
| Missing pipeline | `Makefile` | add a `ci:` target that chains `lint test build` |

The verifier asserts exactly:

1. `Makefile` contains a `ci:` target
2. `make ci` exits 0 (all three gates pass with your fix)
3. Injecting a failing test makes `make test` exit non-zero (gate actually gates)

## Why `|| true` is dangerous

A gate that never fails is worse than no gate — it gives false confidence. `|| true` is the idiomatic shell way to convert any exit code to 0. It looks harmless when added in a hurry ("the CI was failing on a flaky test, I'll just..."), but it means the entire stage is a no-op as a quality checkpoint.

The same pattern appears as `exit 0` at the end of a test step in GitHub Actions, `continue-on-error: true` on a critical step, or `--ignore-failure` flags in some build tools. In every case, a gate that swallows errors is not a gate.

## Verify

```bash
bash courses/course-25-cicd/challenges/02-pipeline-gates/verify.sh
```

The verifier runs from `~/.kube-dojo-work/02-pipeline-gates/` and prints the flag only when both the happy path and the gate-actually-gates check pass.
