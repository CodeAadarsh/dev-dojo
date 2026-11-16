# pytest Fundamentals — Assertions, Structure & Selection

> **Module 02 · Course 36** — You can write a passing test now. This module makes you *fluent*: how pytest's plain-`assert` magic actually works, how to assert on every kind of value (not just `==`), how to compare floats without getting burned, how to organize tests as a suite grows, and how to run exactly the subset you care about. These are the controls you'll touch every single day.

---

## Why `assert` alone is enough (assert rewriting)

In most languages you need a library of assertion helpers: `assertEqual`, `assertTrue`, `assertGreater`. pytest throws all that out. You use Python's own `assert` and pytest makes the failure readable.

The trick is **assert rewriting**. Before running your test file, pytest rewrites the bytecode of every `assert` so that when one fails, it introspects the expression and prints the sub-values. That's why this:

```python
def test_rewrite_demo():
    left = [1, 2, 3]
    right = [1, 2, 4]
    assert left == right
```

fails with a *diff*, not just "False":

```
E       assert [1, 2, 3] == [1, 2, 4]
E         At index 2 diff: 3 != 4
E         Full diff:
E         - [1, 2, 3]
E         + [1, 2, 4]
```

You get this for free on lists, dicts, sets, strings — pytest knows how to diff them. The practical upshot: **write the most natural boolean expression and let pytest explain the failure.** You almost never need a helper function.

> Assert rewriting only happens in *test modules* pytest collects, and in any module you explicitly register with `pytest.register_assert_rewrite`. An `assert` buried in your application code is just a normal assert — no diff.

---

## The vocabulary of assertions

Everything is still `assert`, but the *expression* changes with what you're checking:

```python
assert result == 5                 # equality
assert result != 0                 # inequality
assert result > 3                  # ordering
assert item in collection          # membership
assert "error" in message          # substring (str) or membership
assert isinstance(obj, Account)    # type
assert obj is None                 # identity (use 'is' for None/True/False)
assert not errors                  # emptiness — empty list/dict/str is falsy
assert len(rows) == 10             # size
assert all(x > 0 for x in values)  # a property over every element
assert sorted(result) == [1, 2, 3] # order-independent compare
```

Note the last two patterns — `all(...)` and sorting before comparing — they let you assert on *shape* and *properties* instead of pinning every value. But beware: `assert all(x > 0 for x in values)` gives a useless failure message (just `assert False`) because the generator hides the offending element. When you need a readable failure, loop or parametrize (Module 04) instead.

### Identity vs equality

`==` asks "are these equal?"; `is` asks "are these the exact same object?". For `None`, `True`, `False`, always use `is` — there's exactly one `None` object:

```python
assert value is None        # correct
assert value == None        # works but style-wrong; linters flag it
```

---

## Comparing floats: never use `==`

Floating-point math is not exact. This *fails*:

```python
def test_float_naive():
    assert 0.1 + 0.2 == 0.3     # FAILS: 0.1 + 0.2 == 0.30000000000000004
```

`0.1 + 0.2` is `0.30000000000000004` in IEEE-754 double precision. Comparing floats with `==` is a bug. pytest ships the fix — `pytest.approx`:

```python
import pytest

def test_float_approx():
    assert 0.1 + 0.2 == pytest.approx(0.3)
```

`approx` compares within a small relative tolerance. It also works element-wise on lists and dicts:

```python
assert [0.1 + 0.2, 0.2 + 0.4] == pytest.approx([0.3, 0.6])
assert {"x": 0.1 + 0.2} == pytest.approx({"x": 0.3})
```

You can tighten or loosen the tolerance: `pytest.approx(0.3, abs=1e-9)` (absolute) or `rel=1e-6` (relative). **Rule: any time floats are involved in the expected value, reach for `approx`.**

---

## Asserting on exceptions, properly

Module 01 introduced `pytest.raises`. There's more to it, and you'll use all of it:

```python
import pytest

# 1. Just assert the type
with pytest.raises(ValueError):
    int("not a number")

# 2. Capture the exception and inspect it
with pytest.raises(ValueError) as exc_info:
    int("not a number")
assert "invalid literal" in str(exc_info.value)

# 3. Assert on the message with a regex (match=)
with pytest.raises(ValueError, match=r"invalid literal.*'not a number'"):
    int("not a number")
```

`match` is a **regex searched** against the string of the exception (not a full-match, not a plain substring — regex `.search`). Metacharacters like `(`, `.`, `$` must be escaped. Pinning the message matters: a function can raise `ValueError` for ten different reasons, and you usually want to prove it raised for the *right* one.

### Asserting on warnings

The sibling for warnings is `pytest.warns`:

```python
import warnings, pytest

def test_emits_deprecation():
    with pytest.warns(DeprecationWarning, match="use new_api"):
        old_api()
```

---

## Organizing tests as the suite grows

A one-file project keeps tests next to code. A real project separates them. The common layout:

```
myproject/
├── src/
│   └── myproject/
│       ├── __init__.py
│       └── bank.py
├── tests/
│   ├── test_bank.py
│   └── test_statements.py
├── pyproject.toml
└── pytest.ini          (or config inside pyproject.toml)
```

Group related tests into `Test*` classes when they share a theme (not just to group — in Module 03 classes become a natural scope for fixtures):

```python
class TestWithdraw:
    def test_reduces_balance(self):
        ...
    def test_rejects_overdraft(self):
        ...

class TestDeposit:
    def test_increases_balance(self):
        ...
```

Remember: a pytest test class must **not** define `__init__`. pytest instantiates it for you; an `__init__` makes pytest skip the class with a warning.

### Configuration lives in one place

Put pytest config in `pyproject.toml` so options aren't retyped on every run:

```toml
[tool.pytest.ini_options]
addopts = "-ra -q"          # always show a summary of non-passing + quiet
testpaths = ["tests"]        # where to look
pythonpath = ["src"]         # so `import myproject` works with a src/ layout
```

`pythonpath = ["src"]` is the clean modern fix for the `ModuleNotFoundError` you hit in Module 01 with a `src/` layout.

---

## Selecting exactly what to run

As the suite grows, running everything each time gets slow. Control it:

```bash
pytest tests/test_bank.py                 # one file
pytest tests/test_bank.py::TestWithdraw    # one class
pytest tests/test_bank.py::TestWithdraw::test_reduces_balance   # one method
pytest -k "withdraw and not overdraft"     # keyword expression over test names
pytest -m slow                             # by marker (Module 04)
```

And control *how* it runs:

```bash
pytest -x               # stop after the first failure
pytest --maxfail=2      # stop after 2 failures
pytest --lf             # "last failed" — rerun only tests that failed last time
pytest --ff             # "failed first" — run last failures first, then the rest
pytest -q               # quiet
pytest -v               # verbose (names + outcomes)
pytest -s               # don't capture stdout (let your prints show)
pytest --tb=short       # shorter tracebacks; --tb=line for one line each
pytest -ra              # summary of all non-passing tests at the end
```

The workflow that saves the most time: run the full suite, something fails, then loop on `pytest --lf -x` until green, then run the full suite once more to be sure.

---

## What pytest captures for you

By default pytest **captures stdout/stderr** — your `print`s don't show unless the test fails (then it shows them in a captured-output section) or you pass `-s`. This keeps passing runs clean. To assert on what a function printed, don't use `-s`; use the `capsys` fixture (Module 03):

```python
def test_prints_greeting(capsys):
    print("hello")
    captured = capsys.readouterr()
    assert captured.out == "hello\n"
```

---

## Debugging

- **`assert 0.1 + 0.2 == 0.3` fails and you're baffled.** Floats aren't exact. Use `pytest.approx`. This is not a pytest quirk — it's IEEE-754.
- **`pytest.raises` passes when you expected a failure.** The code *did* raise — but maybe the wrong exception subclass. `pytest.raises(Exception)` catches almost everything; narrow it to the specific type. Also check your `match` regex isn't accidentally matching nothing because you forgot it's a regex (escape `.`, `(`, `$`).
- **`match=` never matches even though the message looks right.** `match` is `re.search`, so regex metacharacters are live. A message like `cost is $5 (too high)` needs `match=r"cost is \$5 \(too high\)"`.
- **My `print` output vanished.** pytest captures stdout. Use `-s` to see it live, or `capsys` to assert on it. Don't litter code with prints to debug a test — read the assert diff instead.
- **A whole test class is skipped.** You gave the class an `__init__`. Remove it; use fixtures for setup.
- **`import myproject` fails from `tests/`.** Set `pythonpath = ["src"]` in config, or install your package in editable mode with `pip install -e .`.
- **Weak assert passed a broken function.** `assert result` (truthy) hides bugs. Assert the exact value or shape.

---

## Checkpoint

You can now:

- Explain assert rewriting in one line: *pytest rewrites asserts so a failure prints the actual sub-values.*
- Pick the right assertion expression for equality, membership, type, identity, size, and "every element satisfies X."
- Compare floats with `pytest.approx` and know *why* `==` is wrong.
- Use `pytest.raises` three ways: type-only, capture-and-inspect, and `match=` regex.
- Lay out `src/` + `tests/`, group with `Test*` classes, and put options in `pyproject.toml`.
- Drive a red→green loop with `--lf -x`, filter with `-k`, and read short tracebacks.

Self-test: why does `assert items` make a weaker test than `assert len(items) == 3`, and when is each actually the right choice? (Answer: truthiness only proves "non-empty"; the length pins the count. Use truthiness only when "non-empty" is genuinely the whole contract.) Next: **fixtures** — how to set up and tear down the world your tests need, without copy-paste.
