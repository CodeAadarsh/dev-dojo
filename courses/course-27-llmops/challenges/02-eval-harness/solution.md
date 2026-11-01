# Solution — Eval Harness

## The complete implementation

```python
# harness.py
from typing import List, Callable


class EvalCase:
    def __init__(self, input: str, expected: str) -> None:
        self.input = input
        self.expected = expected


class EvalResult:
    def __init__(self, case: EvalCase, actual: str, score: float) -> None:
        self.case = case
        self.actual = actual
        self.score = score


class EvalHarness:
    def __init__(
        self,
        model_fn: Callable[[str], str],
        judge_fn: Callable[[str, str], float],
        threshold: float = 0.7,
    ) -> None:
        self.model_fn = model_fn
        self.judge_fn = judge_fn
        self.threshold = threshold
        self.results: List[EvalResult] = []

    def run(self, cases: List[EvalCase]) -> None:
        self.results = []
        for case in cases:
            actual = self.model_fn(case.input)
            score = self.judge_fn(case.expected, actual)
            self.results.append(EvalResult(case, actual, score))

    def aggregate_score(self) -> float:
        if not self.results:
            raise ValueError("no results — call run() first")
        return sum(r.score for r in self.results) / len(self.results)

    def passes_threshold(self) -> bool:
        return self.aggregate_score() >= self.threshold

    def failing_cases(self) -> List[EvalResult]:
        return [r for r in self.results if r.score < self.threshold]
```

## Why each piece is correct

**`run` resets `self.results`** to an empty list before iterating. If you `append` on top of the old list, calling `run()` twice doubles the result count — a subtle bug that makes the score appear more stable than it is.

**`aggregate_score` raises on empty** instead of returning 0.0 or NaN. Returning 0.0 would cause `passes_threshold()` to return `False` silently — a CI job would fail without any indication that the harness never ran. A `ValueError` surfaces immediately.

**`judge_fn(expected, actual)` is passed `expected` first** — the natural order for a rubric: "compared to the gold standard, how good is the actual?" Any judge you plug in should follow the same convention.

**`failing_cases` uses `< threshold`** — results that exactly hit the threshold are considered passing. This matches the semantics of `passes_threshold` (`>=`).

## Extending the judge

The `exact_judge` used in the challenge is the simplest possible rubric. Production alternatives, all usable as drop-in replacements:

| Judge | Signal |
|-------|--------|
| Token F1 | Word-overlap; tolerates synonyms |
| ROUGE-L | Longest common subsequence; good for summaries |
| Embedding cosine | Semantic similarity without exact word match |
| LLM-as-judge | GPT-4 scores on rubric dimensions (correctness, tone) |
| Rule-based | Regex / schema / keyword checks for structured outputs |

The harness itself never changes — you swap the `judge_fn` argument.

## The deploy-gate pattern

```python
# In CI:
harness = EvalHarness(model_fn=my_classifier, judge_fn=exact_judge, threshold=0.85)
harness.run(load_golden("golden.csv"))
if not harness.passes_threshold():
    for r in harness.failing_cases():
        print(f"FAIL: {r.case.input!r} → got {r.actual!r}, expected {r.case.expected!r}")
    sys.exit(1)
```

Non-zero exit makes any CI system (GitHub Actions, Argo Workflows, a Kubernetes Job) treat the eval step as a failure and block the deploy.
