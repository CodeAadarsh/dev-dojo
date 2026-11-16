# Mocking & Test Doubles

> **Module 05 · Course 36** — Real code talks to things you can't or shouldn't touch in a test: a payment API, the system clock, a database, the filesystem, `random`. A test that hits a live API is slow, flaky, and might charge a credit card. The answer is a **test double** — a stand-in you control. This module teaches the whole family (stub, mock, fake, spy), Python's `unittest.mock`, the one rule everyone gets wrong (*where* to patch), and — most importantly — **when not to mock at all**, because over-mocking produces tests that pass while the system is broken.

---

## The boundary idea

Split your code in two:

- **Logic** — pure computation: given inputs, produce outputs. Decisions, calculations, transformations.
- **Boundaries** — talking to the outside world: network, disk, clock, randomness, environment.

You mock **boundaries**, not logic. The goal is to replace the unpredictable outside world with something deterministic, run your real logic against it, and assert on what your logic did. If you find yourself mocking your own business logic, the design is wrong or you're testing the mock instead of the code.

---

## The test double family

| Double | What it does | Example |
|--------|--------------|---------|
| **Stub** | Returns canned answers to calls | a fake `get_price()` that always returns `100` |
| **Mock** | A stub that also *records* calls so you can assert on them | assert `send_email` was called once with the right address |
| **Spy** | Wraps the real object, records calls, still calls through | verify logging happened without suppressing it |
| **Fake** | A working but simplified implementation | in-memory dict standing in for a database |

In Python, `unittest.mock.Mock`/`MagicMock` covers stub + mock + spy. A **fake** you usually write yourself (an in-memory repo). Don't obsess over the vocabulary — but know that "mock" colloquially means all of these, while precisely it means "a double you assert calls on."

---

## `unittest.mock` — the basics

A `Mock` is an object that accepts any attribute access and any call, inventing children on the fly:

```python
from unittest.mock import Mock

m = Mock()
m.anything                 # returns a new Mock, no error
m.method(1, 2)             # returns a Mock, records the call

# Control what it returns:
m.get_price.return_value = 100
assert m.get_price("BTC") == 100          # returns 100 regardless of args

# Make it raise:
m.charge.side_effect = ConnectionError("down")

# Return different values on successive calls:
m.next_id.side_effect = [1, 2, 3]

# Assert how it was called:
m.get_price.assert_called_once()
m.get_price.assert_called_once_with("BTC")
assert m.get_price.call_count == 1
```

`return_value` sets the canned answer. `side_effect` is more powerful: an exception (raised), a list (consumed one per call), or a function (called with the same args — for computed responses). The `assert_called_*` family turns a mock into a spy.

`MagicMock` is a `Mock` that also supports *magic methods* (`__len__`, `__iter__`, `__enter__`, etc.) — use it when the thing you're replacing is used as a context manager, iterated, or indexed.

---

## The one rule: patch where it's *used*, not where it's defined

This trips up everyone. `mock.patch` replaces a name in a namespace. You must patch the name **in the module that looks it up**, not in the module where the function is defined.

Suppose:

```python
# weather.py
import requests

def get_temperature(city):
    resp = requests.get(f"https://api.example.com/{city}")
    return resp.json()["temp"]
```

`weather.py` did `import requests`, so inside `weather` the name is `weather.requests`. To mock it:

```python
from unittest.mock import patch

def test_get_temperature():
    with patch("weather.requests") as mock_requests:          # <- weather.requests, NOT requests.requests
        mock_requests.get.return_value.json.return_value = {"temp": 21}
        assert get_temperature("london") == 21
        mock_requests.get.assert_called_once_with("https://api.example.com/london")
```

If the code had done `from requests import get`, the name inside `weather` would be `weather.get`, and you'd patch `"weather.get"`. **The target string is always `<module under test>.<name as that module refers to it>`.** Memorize this; "patch where it's used" is the single most common mocking bug.

---

## `patch` as decorator, context manager, or via `monkeypatch`

Three equivalent styles:

```python
# As a context manager (scoped, explicit):
with patch("weather.requests") as mock_requests:
    ...

# As a decorator (injected as an argument — note bottom-up order with multiple):
@patch("weather.requests")
def test_it(mock_requests):
    ...

# Via pytest's monkeypatch fixture (no string target — patch the attribute directly):
def test_it(monkeypatch):
    fake = Mock()
    fake.get.return_value.json.return_value = {"temp": 21}
    monkeypatch.setattr("weather.requests", fake)
```

With `@patch`, stacked decorators inject **bottom-up**: the decorator closest to the function is the *first* parameter. `monkeypatch` (the pytest fixture from Module 03) auto-undoes after the test and reads naturally — many pytest users prefer it over `unittest.mock.patch` for simple attribute replacement.

---

## `autospec` — mocks that respect the real signature

A plain `Mock` accepts *any* call — `m.get_price(1, 2, 3, nonsense=True)` happily returns a mock. That means a test can pass against a call that would crash in production (wrong arguments). `autospec` makes the mock mirror the real object's signature and attributes:

```python
with patch("weather.requests", autospec=True) as mock_requests:
    mock_requests.get(1, 2, 3)      # raises TypeError — real requests.get doesn't take that
```

Prefer `autospec=True` (or `create_autospec`) for anything non-trivial. It catches the class of bug where you mock an interface, then the real interface changes, and your mocks keep passing against a signature that no longer exists.

---

## Mocking the usual suspects

### The clock

Code that calls `datetime.now()` is non-deterministic. Freeze it:

```python
# billing.py
from datetime import datetime
def invoice_id():
    return "INV-" + datetime.now().strftime("%Y%m%d")
```

```python
from unittest.mock import patch
from datetime import datetime

def test_invoice_id():
    frozen = datetime(2026, 11, 16)
    with patch("billing.datetime") as mock_dt:
        mock_dt.now.return_value = frozen
        assert invoice_id() == "INV-20261116"
```

(For heavy time-dependent code, the `freezegun` library or `time-machine` is cleaner — but the principle is the same: control the clock.)

### Randomness

```python
def test_shuffle_is_seeded(monkeypatch):
    monkeypatch.setattr("mymod.random.random", lambda: 0.5)
    ...
```

Or simpler: seed it — `random.seed(0)` in the test — when you own the call.

### The filesystem

Don't mock `open`; use the real filesystem in a temp dir via `tmp_path` (Module 03). Faster to write, and it actually tests the I/O. Mock the filesystem only when the real thing is impractical.

### The network — and forcing yourself to mock it

The best protection against an un-mocked network call isn't discipline, it's making real calls *impossible* in tests. A common pattern: a fixture that blocks sockets, so any un-mocked HTTP call raises loudly instead of silently hitting the internet:

```python
# conftest.py
import socket, pytest

@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def guard(*a, **k):
        raise RuntimeError("network access in a test — mock it!")
    monkeypatch.setattr(socket, "socket", guard)
```

Now a test that forgets to mock `requests` fails with a clear message instead of flaking in CI. (Challenge 04 uses exactly this technique against you.)

---

## When NOT to mock

This is the part most tutorials skip, and it's the most important:

- **Don't mock what you don't own, directly.** Mocking `requests` deep in a test couples the test to *how* you call the library. If the library changes, your mocks lie. Prefer wrapping third-party calls behind a thin adapter *you* own, and mock (or fake) that adapter.
- **Don't mock pure logic.** If a function just computes, call it for real. Mocking it tests nothing.
- **Don't over-specify calls.** `assert_called_once_with(exactly, these, args)` on every internal call makes the test a mirror of the implementation — it breaks on every refactor even when behavior is unchanged. Assert on *observable outcomes* (return value, the one email that got sent), not every internal step.
- **A fake often beats a mock.** An in-memory dict that behaves like your datastore gives more realistic tests than a `Mock` with twelve `return_value`s, and it doesn't rot when you refactor.

> The failure mode of mocking is a **green suite over broken code**: every boundary is mocked to return success, so the test proves your code works *against mocks you wrote*, not against reality. Mock the minimum. Keep an integration test (Module 08) that uses the real thing.

---

## Debugging

- **Patch "doesn't work" — the real function still runs.** You patched where it's *defined*, not where it's *used*. If the module under test does `import requests`, patch `"thatmodule.requests"`. If it does `from x import f`, patch `"thatmodule.f"`.
- **`AttributeError` while setting up a mock chain.** With `autospec=True`, you can only access attributes the real object has. Either the real API differs from your assumption (good — the mock caught it), or you need a plain `Mock` for a dynamic attribute.
- **`assert_called_once` passes when nothing was called.** You typo'd the method name: `m.asert_called_once()` is just a new mock child that returns truthy. Real methods are `assert_called_once`, `assert_called_once_with`, `assert_not_called`. With `autospec`/`spec`, typo'd assert methods raise — another reason to use spec.
- **`side_effect` list raised `StopIteration`.** The code called the mock more times than you supplied values. Add more, or use `return_value` for a constant.
- **Context manager mock returns a Mock instead of my value.** Set `mock.__enter__.return_value = ...` (or use `MagicMock`, which supports `__enter__`).
- **Test passes but production breaks.** You mocked too much — the bug lives in the boundary you faked out. Add an integration test that exercises the real boundary.
- **Clock patch has no effect.** You patched `datetime.datetime` globally but the module did `from datetime import datetime` — patch `"thatmodule.datetime"` instead, and set `.now.return_value`.

---

## Checkpoint

You can now:

- Separate **logic** from **boundaries** and mock only the boundaries.
- Name the test-double family (stub/mock/spy/fake) and pick the lightest one that works.
- Drive `Mock`/`MagicMock` with `return_value`, `side_effect`, and the `assert_called_*` family.
- State and apply the golden rule: **patch where the name is used**, not where it's defined.
- Use `autospec=True` to catch signature drift, and `monkeypatch` for clean attribute patching.
- Mock the clock, randomness, and network — and use a socket-blocking fixture to *force* mocking.
- Articulate when mocking is wrong: pure logic, over-specified calls, mocking libraries you don't own, and the green-suite-over-broken-code trap.

Self-test: your `weather.py` does `from requests import get` and calls `get(...)`. What exact string do you pass to `patch`? (`"weather.get"` — the name as `weather` refers to it, not `"requests.get"`.) Next: **TDD and coverage** — writing the test *first*, and measuring what your tests actually exercise (and why that number lies).
