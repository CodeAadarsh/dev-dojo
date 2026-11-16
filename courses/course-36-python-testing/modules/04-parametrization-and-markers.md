# Parametrization & Markers

> **Module 04 · Course 36** — You just wrote a test for one input. But real correctness lives at the *edges*: zero, empty, negative, the boundary, the Unicode name, the leap day. Copy-pasting a test seven times with different numbers is how you end up with seven tests that drifted apart. Parametrization runs **one** test body against a **table** of inputs — concise, exhaustive, and each case reported separately. Then markers let you label, skip, and conditionally expect-fail tests. Together they turn a handful of tests into thorough coverage.

---

## `@pytest.mark.parametrize` — one test, many cases

The core tool. You give it a list of argument names and a list of value tuples; pytest runs the test once per tuple:

```python
import pytest

@pytest.mark.parametrize("value, expected", [
    (0,   "zero"),
    (1,   "one"),
    (-1,  "negative"),
    (100, "big"),
])
def test_classify(value, expected):
    assert classify(value) == expected
```

pytest expands this into **four separate tests**. Run with `-v` and you see each one:

```
test_classify[0-zero] PASSED
test_classify[1-one] PASSED
test_classify[-1-negative] PASSED
test_classify[100-big] PASSED
```

This is the whole point: a failure in the `-1` case is reported as `test_classify[-1-negative] FAILED` — you know *exactly* which input broke, and the other three still run. Contrast a hand-written loop inside one test, which stops at the first failing iteration and hides the rest.

**The mental shift:** when you catch yourself about to copy a test and change one literal, parametrize instead.

---

## Readable case IDs

Those `[...]` labels are auto-generated and get ugly with complex objects (`test_x[value1-expected1]`). Name cases explicitly with `ids=`:

```python
@pytest.mark.parametrize(
    "raw, parsed",
    [
        ("1h",    3600),
        ("30m",   1800),
        ("1h30m", 5400),
        ("0s",    0),
    ],
    ids=["one-hour", "thirty-min", "mixed", "zero"],
)
def test_parse_duration(raw, parsed):
    assert parse_duration(raw) == parsed
```

Now a failure reads `test_parse_duration[mixed]` — self-documenting. Good IDs turn your test output into a spec you can read.

---

## Stacking parametrize — the cross product

Apply the decorator twice and pytest runs the **Cartesian product** of the two tables:

```python
@pytest.mark.parametrize("x", [1, 2, 3])
@pytest.mark.parametrize("y", [10, 20])
def test_pairs(x, y):
    assert add(x, y) == x + y
```

That's `3 × 2 = 6` tests — every `x` with every `y`. Useful for "this behavior must hold across all combinations of these axes." Be careful: products explode fast (`5 × 5 × 5 = 125`). Stack only truly independent axes.

---

## Parametrizing for edge cases (the real skill)

Parametrization's value isn't variety for its own sake — it's **systematic edge coverage**. For any function, enumerate the categories of input that could behave differently and put one row per category:

```python
@pytest.mark.parametrize("n, expected", [
    (0,           1),            # boundary: 0! == 1
    (1,           1),            # smallest positive
    (5,           120),          # ordinary case
    (13,          6227020800),   # large-ish, checks no overflow weirdness
])
def test_factorial(n, expected):
    assert factorial(n) == expected

@pytest.mark.parametrize("bad", [-1, -5, 2.5, "3"])
def test_factorial_rejects_bad_input(bad):
    with pytest.raises((ValueError, TypeError)):
        factorial(bad)
```

Notice the two tables: valid inputs with expected outputs, and invalid inputs that must raise. The second table is where bugs hide — most code is under-tested on its failure paths.

> A test suite's quality is largely "did you think of the edge?" Parametrization makes adding a newly-discovered edge a one-line change, so you actually do it.

---

## Parametrizing fixtures

You can also parametrize a *fixture*, so every test using it runs once per param. This is how you run an entire suite against multiple backends (e.g., SQLite and Postgres) without touching the tests:

```python
@pytest.fixture(params=["sqlite", "postgres"])
def db(request):
    backend = request.param           # the current parameter value
    conn = connect(backend)
    yield conn
    conn.close()

def test_insert(db):                  # runs twice: [sqlite] and [postgres]
    db.insert({"id": 1})
    assert db.count() == 1
```

`request.param` is how the fixture reads its current value. Every test that requests `db` is now multiplied across both backends automatically.

---

## Markers — labeling tests

A **marker** tags a test with metadata. You've already used one implicitly (`parametrize` is a marker). The built-in ones you'll use constantly:

### `skip` — never run this (for now)

```python
@pytest.mark.skip(reason="endpoint not implemented yet")
def test_future_feature():
    ...
```

### `skipif` — run only under certain conditions

```python
import sys

@pytest.mark.skipif(sys.version_info < (3, 11), reason="needs 3.11 syntax")
def test_new_syntax():
    ...
```

### `xfail` — "I expect this to fail"

For known bugs or not-yet-implemented behavior you want *tracked*, not hidden:

```python
@pytest.mark.xfail(reason="bug #4521, off-by-one in pagination")
def test_pagination_last_page():
    assert last_page(items=100, per_page=10) == 10
```

An `xfail` test that fails is reported as `xfailed` (expected — suite stays green). If it *passes*, it's reported as `xpassed` — a signal the bug got fixed and you should remove the marker. Add `strict=True` to make an unexpected pass *fail* the suite, forcing cleanup:

```python
@pytest.mark.xfail(strict=True, reason="should fail until #4521 lands")
```

**`skip` vs `xfail`:** `skip` doesn't run the code at all (use when it can't run — missing dependency, wrong OS). `xfail` *runs* it and expects failure (use for known bugs — so you learn the moment it starts passing).

### Custom markers — categorize your suite

Define your own labels to slice the suite. Register them in config so pytest doesn't warn:

```toml
# pyproject.toml
[tool.pytest.ini_options]
markers = [
    "slow: tests that take more than a second",
    "integration: hits a real external service",
]
```

```python
@pytest.mark.slow
@pytest.mark.integration
def test_full_sync():
    ...
```

Then run subsets with `-m`:

```bash
pytest -m "not slow"              # skip slow tests during rapid iteration
pytest -m integration            # only integration tests
pytest -m "slow and not integration"
```

This is how a CI pipeline runs fast unit tests on every push and the slow integration suite nightly — same code, different `-m` selector.

---

## Combining parametrize with markers

You can mark an individual parametrized case with `pytest.param`:

```python
@pytest.mark.parametrize("value, expected", [
    (2, 4),
    (3, 9),
    pytest.param(10, 100, marks=pytest.mark.slow),
    pytest.param(0, 0, marks=pytest.mark.xfail(reason="zero case buggy")),
])
def test_square(value, expected):
    assert square(value) == expected
```

Now the `10` case is tagged `slow` and the `0` case is expected to fail — all within one table.

---

## Debugging

- **`parametrize` runs but all cases share one name like `test_x[0]`.** You only gave positional values; add `ids=` for readable labels, or pytest will derive them from the values.
- **"got an unexpected keyword argument" / signature mismatch.** The parameter names in the decorator string must exactly match (and be in the same order as) the test function's parameters — plus any fixtures.
- **Fixture + parametrize ordering confusion.** Fixtures and parametrize params are both just function parameters; pytest fills them by name regardless of order. But a parametrized *fixture* multiplies every test using it — if your suite suddenly doubled, a fixture got `params=`.
- **`PytestUnknownMarkWarning: Unknown mark`.** You used a custom marker without registering it in `markers = [...]`. Register it; unregistered marks are easy to typo (`@pytest.mark.slwo` silently does nothing).
- **`xfail` test keeps passing but suite stays green and nobody notices.** That's `xpass`. Use `strict=True` so an unexpected pass fails the build and forces you to delete the stale marker.
- **`skip` hides a test forever.** Prefer `xfail` for "known broken" so you're alerted when it's fixed; reserve `skip` for "genuinely cannot run here."
- **Cartesian product exploded into hundreds of tests.** You stacked `parametrize` decorators. Each stack multiplies. Collapse to a single table of the specific combinations you care about if the full product isn't meaningful.

---

## Checkpoint

You can now:

- Replace copy-pasted tests with a single `@pytest.mark.parametrize` table, and read the per-case results.
- Write readable `ids=` so failures name themselves.
- Systematically enumerate edge cases (boundaries, empties, invalids) as parametrize rows — including a table of inputs that must `raise`.
- Parametrize a *fixture* to run a whole suite across multiple backends.
- Choose correctly between `skip` (don't run) and `xfail` (run, expect failure), and use `strict=True` to catch silent fixes.
- Define, register, and select custom markers with `-m` for fast-vs-slow CI slicing.

Self-test: you find a bug where `parse_duration("")` crashes instead of raising a clean error. Do you write a `skip`, an `xfail`, or a parametrized case — and why? (An `xfail(strict=True)` row via `pytest.param("", None, marks=...)`, or a `pytest.raises` case if you fix it now. `skip` would hide it; `xfail` tracks it and tells you when it's fixed.) Next: **mocking** — testing code that talks to the network, the clock, and the database, without any of them.
