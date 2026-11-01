# Solution — Pipeline Gates

Three changes. Apply them in any order; all three are required for verify.sh to pass.

## 1. Fix `app.py`

```python
def add(a: float, b: float) -> float:
    return a + b           # was: return a - b


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))  # unchanged
```

## 2. Fix `Makefile` — remove the swallowed failure + add `ci` target

```makefile
.PHONY: lint test build ci

lint:
	python3 -m py_compile app.py
	@echo "lint ok"

test:
	pytest tests/ -q

build:
	mkdir -p dist
	cp app.py dist/app.py
	@echo "build ok — dist/app.py"

ci: lint test build
```

The two changes to the Makefile:
- Remove `|| true` from `test:` so pytest's exit code propagates.
- Add `ci: lint test build` — a target whose only body is its prerequisite list. Make runs each prerequisite in order and stops on the first non-zero exit.

## Why each piece matters

**`return a - b` → `return a + b`.**
The bug is obvious in hindsight, but it was undetectable in CI because the gate swallowed the failure. The post-incident fix requires both: correct the source *and* fix the gate. Fixing only the source restores the current green run but leaves the gate broken for the next regression.

**Removing `|| true`.**
`|| true` is shell short-circuit OR: "run the left side; if it fails, run `true` (which always exits 0) instead." The net effect is that the recipe always exits 0 regardless of what `pytest` reports. GNU Make tracks exit codes per recipe line; a zero exit means "step passed." So `make test` reports success, `make ci` (when you add it) reports success, and the broken commit gets a green status.

The minimal fix is removing `|| true`. You do not need to add `set -e` or `exit $?` — Make already propagates non-zero exits by default for every recipe line. The `|| true` was the only thing blocking that default.

**`ci: lint test build` with no recipe body.**
In GNU Make, a target can consist entirely of prerequisites with no recipe body. When Make reaches `ci`, it checks each prerequisite in order: builds (runs) `lint`, checks its exit code, then `test`, then `build`. If any prerequisite recipe exits non-zero, Make stops and exits non-zero. This gives you a sequential gate chain with exactly one line.

**Why lint before test?**
`py_compile` is near-instant. A syntax error in `app.py` makes pytest fail with an `ImportError` — a confusing failure message that hides the real problem. Linting first means the first failure you see is always at the right level of abstraction.

## Verify

```bash
cd ~/.kube-dojo-work/02-pipeline-gates
make ci                  # should exit 0 end-to-end
bash courses/course-25-cicd/challenges/02-pipeline-gates/verify.sh
```

## Attacker's view

A pipeline that always returns green is a perfect cover for a supply-chain attack: a compromised dependency that adds malicious code will pass CI if the test gate is broken. The `|| true` pattern is sometimes introduced intentionally by an attacker who has CI write access — it's the pipeline equivalent of deleting the smoke detectors before starting the fire.
