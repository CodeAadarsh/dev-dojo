# Eval Harness

The ML team ships a new "intent classifier" every two weeks. After one bad deploy, the on-call engineer spent six hours manually comparing outputs to a golden spreadsheet before admitting defeat and rolling back. The post-mortem action item reads: *"automated eval must gate every deploy."*

Your job: build the harness that runs a model against a golden dataset, scores it with a deterministic judge, and surfaces a clear pass/fail before the deploy ever happens.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/02-eval-harness/
├── harness.py             # skeleton — EvalCase, EvalResult, EvalHarness stubs
├── golden.csv             # 10-row eval dataset (input, expected)
└── tests/
    └── test_harness_sample.py   # sample tests using a trivial mock model
```

The golden dataset and the mock models used by the verifier are fully deterministic — no real LLM required.

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-eval-harness
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `EvalHarness` in `harness.py`. The class interface is declared; only the method bodies are stubs.

The verifier checks all of the following:

| Requirement | Detail |
|-------------|--------|
| **run(cases)** | Calls `model_fn(case.input)` for each case, then `judge_fn(case.expected, actual)` → `float` score 0.0–1.0; stores `EvalResult` objects in `self.results` |
| **aggregate_score()** | Returns the arithmetic mean of all result scores; raises `ValueError` when `self.results` is empty |
| **passes_threshold()** | Returns `True` iff `aggregate_score() >= self.threshold` |
| **failing_cases()** | Returns the subset of results whose `score < self.threshold` |
| **Good model passes** | A mock that always returns the exact expected value scores 1.0 and passes the default threshold (0.7) |
| **Bad model fails** | A mock that always returns a wrong answer scores 0.0 and fails any threshold > 0 |
| **Partial model correct** | 2 correct out of 3 cases → aggregate 0.667; passes threshold 0.5, fails threshold 0.8 |

## Why this matters

A well-designed eval harness is the difference between "we think quality improved" and "quality improved from 0.71 to 0.84 on the golden set; here are the 4 regressions." The threshold gate enforces a floor: if the model drops below it, CI fails and the deploy does not proceed. The `failing_cases()` list tells you *exactly* which inputs broke — the starting point for every prompt-fix iteration.

## Verify

```bash
bash courses/course-27-llmops/challenges/02-eval-harness/verify.sh
```

All tests green → flag printed.
