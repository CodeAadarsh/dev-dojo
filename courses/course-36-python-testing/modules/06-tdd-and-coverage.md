# Test-Driven Development & Coverage

> **Module 06 · Course 36** — So far you've written tests *after* the code. TDD flips the order: write a failing test first, make it pass, clean up — repeat. It sounds backwards and feels slow for about a day, then it changes how you design code. This module teaches the red-green-refactor loop as a practical discipline (not a religion), then covers **coverage**: how to measure which lines your tests exercise, why branch coverage matters more than line coverage, and the crucial lesson that *100% coverage does not mean correct*.

---

## The red-green-refactor loop

TDD is three steps, repeated in tight cycles of a few minutes:

1. **Red** — write one small test for behavior that doesn't exist yet. Run it. It **fails** (or won't even import). Good — a test that's never been red proves nothing.
2. **Green** — write the *minimum* code to make it pass. Not the elegant version — the dumbest thing that goes green. Even hardcoding is allowed here.
3. **Refactor** — now that you're green, improve the code *and* the test, running the suite after each change. The green bar is your safety net.

Then loop: next test, next slice of behavior.

```
   ┌──────────────────────────────────────────┐
   │                                            │
   ▼                                            │
 RED  ──►  write a failing test                 │
   │                                            │
   ▼                                            │
 GREEN ──► minimum code to pass                 │
   │                                            │
   ▼                                            │
 REFACTOR ─► clean up, suite stays green ───────┘
```

---

## Why "minimum code" and "must be red first"?

Two rules that feel pedantic but carry the whole value:

**The test must fail first.** If you write a test and it passes immediately, you've learned nothing — maybe the behavior already existed, maybe the test is broken and can *never* fail. Seeing red proves the test actually exercises the thing and that your next step is what makes it pass. A test you've never seen fail is not a test; it's a hope.

**Write the minimum to pass.** This forces each test to earn its keep. If `return 1` makes the test green, the test was too weak — it didn't pin down the real behavior. So you add another test that `return 1` *can't* satisfy, forcing real logic. This back-and-forth (sometimes called "triangulation") is how TDD drives you to general code through specific examples.

---

## A worked TDD cycle

Let's build a `fizzbuzz(n)` with TDD. Watch the tests lead.

**Cycle 1 — red:**
```python
def test_returns_number_as_string():
    assert fizzbuzz(1) == "1"
```
Fails: `fizzbuzz` doesn't exist. **Green** — minimum:
```python
def fizzbuzz(n):
    return str(n)
```
Passes. `fizzbuzz(2)` would too — but we don't write that code yet.

**Cycle 2 — red:**
```python
def test_multiples_of_three_say_fizz():
    assert fizzbuzz(3) == "Fizz"
```
Fails (`"3"` != `"Fizz"`). **Green:**
```python
def fizzbuzz(n):
    if n % 3 == 0:
        return "Fizz"
    return str(n)
```

**Cycle 3 — red:** `assert fizzbuzz(5) == "Buzz"`. **Green:** add `if n % 5 == 0: return "Buzz"`.

**Cycle 4 — red:** `assert fizzbuzz(15) == "FizzBuzz"`. This one *forces* a refactor — the naive `if`s return `"Fizz"` for 15. **Green + refactor:**
```python
def fizzbuzz(n):
    out = ""
    if n % 3 == 0:
        out += "Fizz"
    if n % 5 == 0:
        out += "Buzz"
    return out or str(n)
```
Run the whole suite: all green. Notice you now have four tests documenting every rule, written *as* you designed the function — and the design (build-up string) emerged from the 15 case, not from guessing up front.

---

## What TDD actually gives you

- **Testable design, for free.** You can't write a test first for code that's hard to test, so you don't write hard-to-test code. Dependencies get injected (so they're mockable), functions get smaller, side effects get pushed to the edges.
- **A spec that exists before the code.** The test *is* the requirement, made executable.
- **Permission to refactor.** Green suite = safety net. You restructure fearlessly.
- **No dead code.** Every line exists to pass a test, so you don't gold-plate.

It is not a law. For exploratory spikes, throwaway scripts, or when you genuinely don't yet know the shape, writing tests after is fine. TDD is a tool for *building behavior you can specify*. Reach for it there.

---

## Coverage — measuring what your tests touch

**Coverage** tells you which lines/branches of your code ran during the test suite. The tool is `coverage.py`, usually driven through the pytest plugin `pytest-cov`:

```bash
pip install pytest-cov
pytest --cov=myproject                    # report coverage for the myproject package
pytest --cov=myproject --cov-report=term-missing   # show WHICH lines are uncovered
pytest --cov=myproject --cov-report=html  # browsable report in htmlcov/index.html
```

`term-missing` is the one you want day-to-day — it prints the exact uncovered line numbers:

```
Name                 Stmts   Miss  Cover   Missing
--------------------------------------------------
myproject/bank.py       40      3    92%   27-29
```

Lines 27–29 never ran. Go look: often it's an error path you forgot to test.

---

## Line coverage vs. branch coverage

Line coverage counts lines executed. But a line can run while a *branch* through it goes untested. Consider:

```python
def describe(n):
    label = "positive"
    if n < 0:
        label = "negative"
    return label
```

A single test `describe(5)` executes every line except the `label = "negative"` line — 75% line coverage. But even a test that gets *100% line coverage* can miss branches. Turn on **branch coverage** to count both directions of every `if`:

```bash
pytest --cov=myproject --cov-branch --cov-report=term-missing
```

Now coverage demands you test both the `n < 0` true *and* false paths. Branch coverage is strictly more honest than line coverage — always enable `--cov-branch`.

### Enforcing a floor in CI

Fail the build if coverage drops below a threshold:

```bash
pytest --cov=myproject --cov-branch --cov-fail-under=85
```

Exit code is non-zero if coverage is under 85%. Put this in CI so coverage can't silently erode.

---

## The big lie: coverage is not correctness

This is the lesson to carry forever. **Coverage measures what ran, not what was checked.** This test gives 100% coverage of `add` and verifies *nothing*:

```python
def test_add_covered():
    add(2, 3)        # no assert! line runs, coverage is 100%, bug-detection is 0%
```

Coverage counts the line as covered because it executed. There's no assertion, so a broken `add` sails through. High coverage with weak asserts is the most dangerous state: a green dashboard over untested behavior.

**What coverage is good for:** finding code your tests *never touch* — the un-run error handler, the dead branch. Low coverage is a reliable "you missed this." High coverage is *not* a reliable "this works."

**What actually measures test quality: mutation testing.** A mutation tester (e.g., `mutmut`, `cosmic-ray`) changes your code — flips a `<` to `<=`, a `+` to `-`, deletes a line — and reruns your tests. If your tests still pass, the mutant "survived," meaning your tests don't actually detect that bug. A surviving mutant is a hole no coverage number reveals.

```bash
pip install mutmut
mutmut run            # mutate the code, run tests against each mutant
mutmut results        # how many mutants survived (= gaps in your asserts)
```

> This is exactly how the challenges in this course grade you. The verifier *is* a mutation tester: it plants bugs in the code behind your back and your test suite has to catch each one. Coverage gets you in the room; killing mutants is the actual job.

---

## Debugging

- **Coverage says a line is uncovered but I'm sure I tested it.** You're measuring the wrong package (`--cov=wrongname`), or an import-time side effect ran the line before measurement, or the line runs only under a branch you didn't hit. Use `--cov-report=term-missing` and read the exact line numbers.
- **Coverage is 100% but a bug shipped.** Classic coverage-isn't-correctness. Your asserts are too weak or missing. Add assertions that pin the *value*, and run a mutation tester to find the gaps.
- **`--cov-fail-under` fails in CI but passes locally.** Different test selection (you ran a subset locally) or an environment-specific branch. Measure the full suite locally: `pytest --cov=pkg --cov-branch` with no `-k`/`-m` filters.
- **TDD test passes on the first run.** It never went red — so it proves nothing. Make sure you ran it *before* writing the implementation; if it passed, the behavior already existed or the test can't fail (bad assert).
- **TDD feels impossibly slow.** You're writing tests that are too big. Shrink the step: test the smallest observable behavior, not the whole feature. Cycles should be minutes, not hours.
- **Coverage plugin not found.** `pip install pytest-cov`; it's a separate package from pytest.

---

## Checkpoint

You can now:

- Run the red-green-refactor loop and explain why the test *must* be red first and why you write *minimum* code to pass.
- Drive a feature from examples via triangulation (the FizzBuzz `15` case forcing a real refactor).
- State what TDD buys (testable design, executable spec, fearless refactor) and when to skip it (spikes, throwaway).
- Measure coverage with `pytest --cov`, read `term-missing`, and enable `--cov-branch`.
- Enforce a floor with `--cov-fail-under` in CI.
- Explain precisely why coverage ≠ correctness, and name mutation testing as the thing that actually measures assert quality.

Self-test: your module has 100% branch coverage and a `--cov-fail-under=100` gate, yet a reviewer says the tests are worthless. How is that possible, and how would you prove them right or wrong? (The tests call everything but assert little/nothing — run a mutation tester; surviving mutants prove the gap.) Next: **property-based testing** with Hypothesis (and testing async code) — asserting on *properties* that must hold for *all* inputs, not just the examples you thought of.
