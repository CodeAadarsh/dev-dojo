# Property-Based Testing & Async Tests

> **Module 07 · Course 36** — Example-based tests check the inputs *you thought of*. But bugs hide in the inputs you didn't: the empty string, the emoji, the integer one past the boundary, the list that's already sorted. **Property-based testing** flips the burden — you state a *property* that must hold for *all* inputs, and the library (Hypothesis) generates hundreds of cases trying to break it, then shrinks any failure to the smallest example. The second half of this module covers testing **async** code, since so much modern Python (FastAPI, aiohttp, asyncio services) is `async def`.

---

## The limit of example-based tests

You test `sorted_merge(a, b)` with a few hand-picked lists. It passes. Did you try:

- Both lists empty? One empty?
- Lists with duplicates across both?
- A list that's already the answer?
- Negative numbers, huge numbers?
- 10,000 elements?

You can't enumerate them all, and the ones you forget are exactly where bugs live. Property-based testing asks a different question: **what must be true of the output no matter the input?**

For `sorted_merge`, properties include: the result is sorted; its length equals `len(a) + len(b)`; it contains exactly the multiset of both inputs. Those hold for *every* valid input — so let a machine throw thousands at them.

---

## Hypothesis — generating inputs

```bash
pip install hypothesis
```

You write a normal test, decorate it with `@given`, and declare the *shape* of inputs with **strategies**. Hypothesis fills in the values:

```python
from hypothesis import given, strategies as st

@given(st.lists(st.integers()), st.lists(st.integers()))
def test_merge_length_is_sum(a, b):
    a.sort(); b.sort()
    result = sorted_merge(a, b)
    assert len(result) == len(a) + len(b)

@given(st.lists(st.integers()), st.lists(st.integers()))
def test_merge_is_sorted(a, b):
    a.sort(); b.sort()
    result = sorted_merge(a, b)
    assert result == sorted(result)

@given(st.lists(st.integers()), st.lists(st.integers()))
def test_merge_preserves_elements(a, b):
    a.sort(); b.sort()
    from collections import Counter
    assert Counter(sorted_merge(a, b)) == Counter(a + b)
```

Each `@given` test runs ~100 times by default with different generated inputs (empty lists, singletons, huge lists, all-equal, negatives — Hypothesis is *deliberately* mean). You wrote three asserts; Hypothesis wrote the hundreds of inputs.

---

## Strategies — describing inputs

Strategies are the building blocks. The common ones:

```python
st.integers()                       # any int, biased toward nasty values (0, -1, maxint)
st.integers(min_value=0, max_value=100)
st.floats(allow_nan=False, allow_infinity=False)
st.text()                           # Unicode strings — including emoji, control chars
st.lists(st.integers(), min_size=1)
st.dictionaries(st.text(), st.integers())
st.booleans()
st.sampled_from(["GET", "POST", "PUT"])
st.one_of(st.none(), st.integers())
st.tuples(st.integers(), st.text())
```

Compose them: `st.lists(st.tuples(st.text(), st.integers()))` generates lists of (name, score) pairs. Build domain objects with `st.builds`:

```python
st.builds(User, name=st.text(min_size=1), age=st.integers(0, 120))
```

---

## Shrinking — the killer feature

When Hypothesis finds a failing input, it doesn't hand you the random 4,000-element monster that broke it. It **shrinks**: repeatedly simplifies the input while keeping it failing, until it's the *minimal* reproducer. You get output like:

```
Falsifying example: test_merge_is_sorted(
    a=[0], b=[-1],
)
```

That tiny example is worth gold — it tells you the bug triggers when `b`'s element is smaller than `a`'s, instantly pointing at the merge comparison. Shrinking turns "it crashed on some huge random thing" into "it fails on `[0]` and `[-1]`."

Hypothesis also **remembers** failing examples in a local database and replays them first on the next run, so once it finds a bug, it keeps checking that exact case until you fix it.

---

## Finding properties (the hard part)

The skill is identifying properties. Common patterns:

- **Round-trip / inverse.** `decode(encode(x)) == x`. `json.loads(json.dumps(x)) == x`. Parsing/serialization pairs are the richest source — and where real bugs cluster.
- **Invariants.** Output is always sorted; a balance is never negative; length is preserved.
- **Idempotence.** `f(f(x)) == f(x)` — normalizing, deduping, `abs`.
- **Commutativity / symmetry.** `merge(a, b) == merge(b, a)` (as multisets).
- **Oracle (compare to a simpler, trusted implementation).** Your fast version must equal a slow obviously-correct one for all inputs. (This is exactly the pattern from the Data Science course's vectorization challenge.)
- **Metamorphic.** Adding an element increases length by exactly one; sorting then reversing equals reverse-sorting.

```python
@given(st.text())
def test_encode_round_trips(s):
    assert decode(encode(s)) == s          # round-trip

@given(st.lists(st.integers()))
def test_dedupe_is_idempotent(xs):
    once = dedupe(xs)
    assert dedupe(once) == once            # idempotence
```

---

## Controlling Hypothesis

```python
from hypothesis import given, settings, example, assume, strategies as st

@settings(max_examples=500)                # run more cases for a critical function
@given(st.integers())
def test_thorough(n): ...

@given(st.integers())
@example(0)                                # ALWAYS test this specific case too
@example(-1)
def test_with_pinned_cases(n): ...

@given(st.integers())
def test_with_assumption(n):
    assume(n != 0)                         # discard inputs that don't meet a precondition
    assert 100 // n == 100 // n
```

- `@settings(max_examples=N)` tunes how hard it tries.
- `@example(...)` pins a case you *know* matters (regression you already fixed) so it's always checked alongside the random ones.
- `assume(cond)` tells Hypothesis to skip generated inputs that violate a precondition (use sparingly — heavy filtering makes generation slow; prefer a tighter strategy).

> Combine both worlds: keep a few hand-written example tests for readability (they document intent), and add property tests for coverage of the input space. They're complementary, not rivals.

---

## Testing async code

Modern Python services are full of `async def`. A coroutine doesn't run when you call it — it returns a coroutine object. So a plain test can't just `await` without an event loop. The standard solution is the **`pytest-asyncio`** plugin:

```bash
pip install pytest-asyncio
```

```python
import pytest

@pytest.mark.asyncio
async def test_fetch_returns_data():
    result = await fetch_user(1)
    assert result["id"] == 1
```

Mark the test `@pytest.mark.asyncio` (or set `asyncio_mode = "auto"` in config to make every `async def` test run automatically) and pytest-asyncio runs it inside an event loop. You then `await` coroutines normally.

### Async fixtures

Fixtures can be async too:

```python
@pytest.fixture
async def client():
    c = await create_async_client()
    yield c
    await c.aclose()
```

### Mocking in async code

A regular `Mock` returns a value, but async code `await`s the result — and you can't `await` a plain `Mock`. Use `AsyncMock` (its calls return awaitables):

```python
from unittest.mock import AsyncMock

async def test_service_calls_repo():
    repo = AsyncMock()
    repo.get.return_value = {"id": 1}
    service = UserService(repo)
    assert await service.get_user(1) == {"id": 1}
    repo.get.assert_awaited_once_with(1)      # note: assert_awaited_*, not assert_called_*
```

`AsyncMock` gives you `assert_awaited`, `assert_awaited_once_with`, etc. — the async-aware cousins of the call asserts from Module 05.

### Property-based + async

They compose: Hypothesis generates inputs, pytest-asyncio runs the coroutine. (Use Hypothesis's `@given` on an async test with the appropriate executor; for most cases, run the async call via `asyncio.run` inside a sync property test to keep it simple.)

---

## Debugging

- **`@given` test fails with a weird input you'd never write.** That's the feature — Hypothesis found a real edge. Read the "Falsifying example" (already shrunk to minimal); it's a genuine bug or an overly strict property. Fix the code, or correct the property if your assumption was wrong.
- **Hypothesis is slow / `FailedHealthCheck: too slow`.** Your strategy generates expensive data or you `assume()` away most inputs. Narrow the strategy (`min_size`/`max_value`) instead of filtering, and lower `max_examples` for expensive functions.
- **`Flaky` error from Hypothesis.** A test passed then failed on the same input — usually hidden state (a global, a cache, time, randomness) leaking between runs. Make the function pure or reset state in a fixture.
- **Async test is reported as `skipped` or a coroutine warning: "coroutine was never awaited."** You forgot `@pytest.mark.asyncio` (or `asyncio_mode = "auto"`), so pytest treated the coroutine as a normal return value and never ran it.
- **`object Mock can't be used in await expression`.** You used `Mock` where the code `await`s. Switch to `AsyncMock`.
- **`assert_called_once` on an AsyncMock passes trivially.** For awaited calls, use `assert_awaited_once_with`; `assert_called_*` checks the call but `assert_awaited_*` checks it was actually awaited.
- **Event loop errors ("attached to a different loop").** Mixing loop-scoped resources across tests. Let pytest-asyncio manage the loop; don't create your own with `asyncio.new_event_loop()` inside tests.

---

## Checkpoint

You can now:

- Explain the difference between example-based and property-based testing, and why the latter finds bugs you didn't imagine.
- Write `@given` tests with strategies, and compose strategies for domain data.
- Identify properties: round-trip, invariant, idempotence, commutativity, oracle, metamorphic.
- Use shrinking output to get a minimal reproducer, and `@example`/`assume`/`@settings` to steer Hypothesis.
- Run async tests with `pytest-asyncio` and write async fixtures.
- Mock async dependencies with `AsyncMock` and assert with `assert_awaited_*`.

Self-test: you have a `compress()`/`decompress()` pair. Name two properties you'd hand Hypothesis. (Round-trip: `decompress(compress(x)) == x`; and a size invariant or "compress is deterministic." The round-trip alone catches a huge class of bugs.) Next, the capstone module: **testing real systems** — APIs with a test client, databases with rollback isolation, and wiring pytest into CI.
