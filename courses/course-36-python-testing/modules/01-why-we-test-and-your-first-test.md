# Why We Test & Your First Test

> **Module 01 · Course 36** — Before any framework, before pytest, before fixtures and mocks, you need one idea in your bones: **a test is just code that checks other code did what you claimed.** That's it. If you can write an `if` statement, you can write a test. This module takes you from "I've never written a test" to a green test suite you ran yourself — slowly, in plain language. Everything after this builds on it.

You already write Python. You write a function, run it, eyeball the output, and move on. That "eyeball it" step is a test — you just threw it away instead of saving it. This course is about saving it, so the computer re-checks your work every time, forever, in under a second.

---

## What problem does testing actually solve?

Picture the loop you do now without tests:

1. Write a function.
2. Run it in a REPL or add a `print`, look at the output.
3. Looks right → delete the print, move on.
4. Two weeks later you change something nearby.
5. The first function quietly breaks. You don't notice. Your user does.

Step 5 is the whole problem. Code you wrote in the past has no guardrails. The moment a codebase is bigger than your head can hold, "I'll just be careful" stops working. Tests are the memory you don't have: they remember, precisely, what "working" meant — and they shout the instant it stops being true.

A good test suite buys you three things:

- **Confidence to change code.** You refactor, run the tests, and either they stay green (safe) or one goes red and tells you exactly what you broke. This is the big one. Untested code is code you're afraid to touch.
- **A spec that can't lie.** Comments and docs drift out of date. A passing test is executable truth — it *proves* the behavior is still there.
- **A design tool.** Code that's hard to test is usually hard to use. The friction you feel writing a test is real feedback about the code.

> You are not testing to find bugs today (though you will). You are testing so that *future you*, six months from now, half-remembering how this works, can change it without fear.

---

## A test is an assertion

The atom of testing is the **assertion**: a statement you claim is true, that the computer checks for you. Python has a built-in keyword for it: `assert`.

```python
assert 2 + 2 == 4          # nothing happens — the claim is true
assert 2 + 2 == 5          # AssertionError — the claim is false
```

`assert <condition>` does nothing if the condition is truthy, and raises `AssertionError` if it's falsy. A test, at its core, is a function that calls your code and asserts something about the result.

Say you wrote this function:

```python
# calc.py
def add(a, b):
    return a + b
```

Here is a complete, real test for it — no framework, just Python:

```python
# test_calc.py
from calc import add

def test_add_two_positives():
    result = add(2, 3)
    assert result == 5
```

That's a test. A plain function, named starting with `test_`, that calls your code and asserts. If `add` ever stops returning 5 for `add(2, 3)`, the `assert` fails and you hear about it.

---

## Enter pytest: the thing that runs your tests

You *could* run test functions by hand, but you'd have to call each one, catch the errors, and print a report. That bookkeeping is exactly what a **test runner** does for you. The standard one in the Python world is **pytest**.

Install it once:

```bash
python3 -m venv .venv          # make an isolated environment (recommended)
source .venv/bin/activate      # on Windows: .venv\Scripts\activate
pip install pytest
```

Now, from the folder containing `calc.py` and `test_calc.py`, just run:

```bash
pytest
```

pytest **finds** your tests automatically and runs them. You'll see something like:

```
========================= test session starts =========================
collected 1 item

test_calc.py .                                                   [100%]

========================== 1 passed in 0.01s ==========================
```

That single green dot (`.`) is one passing test. Make the function wrong on purpose — change `add` to `return a - b` — and run again:

```
test_calc.py F                                                   [100%]

=============================== FAILURES ===============================
_________________________ test_add_two_positives ______________________

    def test_add_two_positives():
        result = add(2, 3)
>       assert result == 5
E       assert -1 == 5

test_calc.py:5: AssertionError
```

Read that failure top to bottom — pytest is *showing you the actual values*. It says `assert -1 == 5`: your code produced `-1`, the test expected `5`. You didn't add a single print statement; pytest reconstructed it. That magic has a name (**assert rewriting**) and we'll meet it properly in Module 02. For now, just notice: **a failing test tells you what you got vs. what you expected.**

---

## How pytest finds tests (the discovery rules)

pytest doesn't need you to register anything. It walks the directory and collects tests by **naming convention**:

| Thing | Rule |
|-------|------|
| Test files | named `test_*.py` or `*_test.py` |
| Test functions | named `test_*` |
| Test classes | named `Test*` (and **no** `__init__` method) |
| Test methods | named `test_*` inside a `Test*` class |

So this file contributes two tests:

```python
# test_strings.py
def test_upper():
    assert "hi".upper() == "HI"

class TestSplit:
    def test_default_split(self):
        assert "a b c".split() == ["a", "b", "c"]
```

Naming matters. `check_upper()` will be silently ignored — pytest only collects names starting with `test`. A very common beginner confusion is "pytest says *no tests ran*" — nine times out of ten the file or function wasn't named with the `test` prefix.

---

## The shape of every test: Arrange–Act–Assert

Almost every good test has three parts, in order. Keep them visually separate and your tests read like English:

```python
def test_withdraw_reduces_balance():
    # Arrange — set up the world the test needs
    account = Account(balance=100)

    # Act — do the one thing you're testing
    account.withdraw(30)

    # Assert — state exactly what should now be true
    assert account.balance == 70
```

- **Arrange**: build inputs and objects.
- **Act**: call the single behavior under test. Usually *one* line.
- **Assert**: check the outcome.

Two rules that will save you pain:

1. **One behavior per test.** A test named `test_withdraw_reduces_balance` should check exactly that. If you also want to check that withdrawing too much raises an error, that's a *second* test. When a test fails, its name alone should tell you what broke.
2. **Make the assert specific.** `assert account.balance` (truthy) is a weak test — it passes for `70`, `1`, or `-999`. `assert account.balance == 70` is a real claim. Vague asserts are the #1 reason a test suite is green while the code is broken.

---

## Testing that something *raises* an error

Correct behavior isn't only about return values. Sometimes the right thing to do is **fail loudly**. Withdrawing more than you have should raise, not silently return a negative balance. You test that with `pytest.raises`:

```python
import pytest

def test_overdraft_is_rejected():
    account = Account(balance=50)
    with pytest.raises(ValueError):
        account.withdraw(1000)
```

The test passes **only if** the code inside the `with` block raises `ValueError`. If it raises nothing (silently allows the overdraft), or raises a *different* error, the test fails. This is how you pin down the unhappy paths — and the unhappy paths are where real bugs live.

---

## Running just what you want

A few commands you'll use constantly:

```bash
pytest                      # run everything pytest can find
pytest test_calc.py         # one file
pytest test_calc.py::test_add_two_positives   # one specific test
pytest -v                   # verbose: one line per test with its name
pytest -q                   # quiet: less noise
pytest -k withdraw          # only tests whose name matches "withdraw"
pytest -x                   # stop at the first failure
```

`pytest -v` is the one to start with — it prints each test name and PASSED/FAILED, so you *see* your suite growing.

---

## Debugging

Things that go wrong in your first week of testing, and the fix:

- **`pytest` says "no tests ran" / "collected 0 items".** Your file or function isn't named with the `test` prefix. File must be `test_*.py`; functions must be `test_*`. Also check you're running pytest from the right directory.
- **`ModuleNotFoundError: No module named 'calc'`** when the test imports your code. pytest needs to find your module. Easiest fix for now: keep `calc.py` and `test_calc.py` in the **same directory** and run `pytest` from there. (Module 03 explains `conftest.py` and the real import story.)
- **`AssertionError` with no message and you can't tell why.** Run with `pytest -v` and read the `assert X == Y` line pytest prints — it shows the actual left/right values. You almost never need to add prints.
- **A test passes that you expected to fail.** Your assert is too weak (truthy instead of `==`), or you asserted on the wrong variable. Re-read: are you checking the thing you actually changed?
- **`assert` seems to be ignored entirely.** You may have written `assert (result == 5, "msg")` — a tuple! A non-empty tuple is always truthy, so it *always passes*. The correct form is `assert result == 5, "msg"` (comma, not parentheses).
- **Tests pass locally but you ran them in a file with a typo'd name like `tests_calc.py`.** Plural `tests_` is not the convention; use `test_`.

---

## Checkpoint

You should now be able to, without looking anything up:

- Explain in one sentence why tests matter: *they let you change code without fear, because they remember what "working" means.*
- Write a test function from scratch: name it `test_*`, Arrange, Act, Assert.
- Predict what pytest collects given a set of file/function names.
- Read a pytest failure and say what value the code produced vs. what was expected.
- Use `pytest.raises` to assert that bad input is rejected.
- Run a single test, filter by name with `-k`, and use `-v`.

Quick self-test — what does this print, and why?

```python
def test_mystery():
    assert "racecar" == "racecar"[::-1]
```

(It passes: `"racecar"` reversed is itself. If you can explain *why pytest shows nothing on a pass and a detailed diff on a failure*, you've got the mental model. Next module: what pytest's `assert` can really do, and how to make failures readable.)
