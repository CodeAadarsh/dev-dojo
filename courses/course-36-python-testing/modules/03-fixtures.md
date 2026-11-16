# Fixtures — Setup, Teardown & Dependency Injection

> **Module 03 · Course 36** — Tests need a world to run in: a database connection, a temp file, a configured object, a logged-in client. Building that world inline, in every test, is how suites rot — the same ten setup lines copy-pasted into forty tests, each slightly drifted. Fixtures are pytest's answer: write the setup once, *declare* what each test needs, and pytest injects it. This is the single most important pytest feature. Get it right and your tests stay small, readable, and fast.

---

## The problem fixtures solve

Watch the duplication grow:

```python
def test_withdraw_reduces_balance():
    db = Database("sqlite:///:memory:")
    db.create_tables()
    account = Account(db, balance=100)
    account.withdraw(30)
    assert account.balance == 70
    db.close()

def test_overdraft_rejected():
    db = Database("sqlite:///:memory:")      # same 3 lines...
    db.create_tables()                        # ...again
    account = Account(db, balance=50)
    with pytest.raises(ValueError):
        account.withdraw(1000)
    db.close()                                # and the teardown, again
```

Four problems: duplication, you'll forget `db.close()` somewhere and leak, if setup changes you edit N places, and the *intent* of each test is buried under plumbing. Fixtures fix all four.

---

## Your first fixture

A fixture is a function decorated with `@pytest.fixture`. A test *requests* it by naming it as a parameter. pytest sees the parameter, runs the fixture, and passes the result in:

```python
import pytest

@pytest.fixture
def account():
    return Account(balance=100)

def test_withdraw_reduces_balance(account):   # <- requests the fixture by name
    account.withdraw(30)
    assert account.balance == 70

def test_deposit_increases_balance(account):   # <- gets its own fresh Account
    account.deposit(50)
    assert account.balance == 150
```

Two things to internalize:

1. **The parameter name must match the fixture name.** pytest wires by name — this is dependency injection.
2. **Each test gets a *fresh* result by default.** The `account` fixture runs again for every test that requests it, so `test_deposit` is not polluted by `test_withdraw`. Isolation is the default, and isolation is sacred — tests must not depend on each other or on order.

---

## Setup *and* teardown with `yield`

Most real resources need cleanup: close a connection, delete a temp dir, stop a server. Use `yield` instead of `return`. Everything before `yield` is setup; everything after is teardown, and pytest runs it *even if the test fails*:

```python
@pytest.fixture
def db():
    conn = Database("sqlite:///:memory:")   # setup
    conn.create_tables()
    yield conn                               # <- hand the value to the test
    conn.close()                             # teardown — always runs

def test_insert(db):
    db.insert({"id": 1})
    assert db.count() == 1
```

The `yield` fixture is the workhorse. Think of it as a context manager pytest drives for you: the test runs "inside" the `yield`. If the test raises, pytest still executes the teardown half — you won't leak connections on failure.

> Prefer `yield` + teardown over the older `request.addfinalizer(...)` callback style. `yield` keeps setup and teardown visually adjacent and is far easier to read.

---

## Fixtures requesting fixtures

Fixtures compose. A fixture can request other fixtures, building a dependency graph pytest resolves for you:

```python
@pytest.fixture
def db():
    conn = Database("sqlite:///:memory:")
    conn.create_tables()
    yield conn
    conn.close()

@pytest.fixture
def account(db):                 # depends on db
    return Account(db, balance=100)

def test_withdraw(account):      # asks only for account...
    account.withdraw(30)         # ...but db was built and will be torn down too
    assert account.balance == 70
```

You request the high-level thing (`account`); pytest builds the whole chain beneath it and tears it down in reverse order. This is how you keep individual tests to three lines even when the setup underneath is elaborate.

---

## Scope — how often a fixture runs

By default a fixture runs **once per test** (`scope="function"`). That's the safest default, but sometimes setup is expensive (spin up a database, load a model) and you want to share it. The `scope` argument controls lifetime:

| Scope | Created | Use for |
|-------|---------|---------|
| `function` (default) | once per test | anything mutable; the safe default |
| `class` | once per `Test*` class | shared read-only state for a group |
| `module` | once per test file | an expensive connection reused across a file |
| `package` | once per package | rarely needed |
| `session` | once per entire `pytest` run | a Docker container, a web server, a heavy model |

```python
@pytest.fixture(scope="session")
def http_server():
    server = start_server()      # expensive — do it once for the whole run
    yield server
    server.stop()
```

**The scope trade-off is isolation vs. speed.** A `session` fixture is created once and *shared*, so if one test mutates it, later tests see the mutation — order-dependent bugs. Rule of thumb: **broaden scope only for immutable or safely-resettable resources.** Keep anything a test might write to at `function` scope.

---

## `conftest.py` — fixtures shared across files

A fixture defined in a test file is visible only in that file. To share fixtures across many test files, put them in a special file named **`conftest.py`**. pytest auto-discovers it — you never import it:

```
tests/
├── conftest.py          # fixtures here are available to ALL tests below
├── test_bank.py
└── api/
    ├── conftest.py      # fixtures here are available to tests in api/ only
    └── test_endpoints.py
```

`conftest.py` files nest: a test sees fixtures from every `conftest.py` from the rootdir down to its own folder. This is *the* place for your project's shared fixtures (a configured client, a seeded database, test settings). It's also where you register plugins, hooks, and custom markers.

---

## Built-in fixtures you get for free

pytest ships fixtures you request by name without defining anything:

- **`tmp_path`** — a unique, empty `pathlib.Path` directory per test, auto-cleaned. Use it instead of writing to real paths or `/tmp` by hand:

  ```python
  def test_writes_file(tmp_path):
      target = tmp_path / "out.txt"
      save_report(target, data)
      assert target.read_text() == "expected\n"
  ```

- **`capsys`** — capture stdout/stderr to assert on printed output:

  ```python
  def test_prints(capsys):
      greet("Ada")
      assert capsys.readouterr().out == "Hello, Ada\n"
  ```

- **`monkeypatch`** — temporarily set/replace attributes, env vars, dict items, or `chdir`, auto-undone after the test (we lean on this hard in Module 05):

  ```python
  def test_reads_env(monkeypatch):
      monkeypatch.setenv("API_KEY", "test-key")
      assert load_config().api_key == "test-key"
  ```

- **`caplog`** — capture and assert on log records.
- **`request`** — metadata about the running test; powers parametrized fixtures (Module 04).

These cover the boring-but-essential needs — temp files, env vars, captured output — without you hand-rolling cleanup.

---

## `autouse` — fixtures that run without being requested

Set `autouse=True` and a fixture runs for every test in its scope without being named. Use it sparingly, for cross-cutting setup like resetting global state or freezing a seed:

```python
@pytest.fixture(autouse=True)
def reset_registry():
    Registry.clear()      # before each test
    yield
    Registry.clear()      # after each test
```

Powerful, but invisible — a reader of a single test can't see that `reset_registry` ran. Reserve `autouse` for things that genuinely must apply everywhere; prefer explicit requests otherwise.

---

## Factory fixtures — when a test needs *several*

A plain `account` fixture gives one account. When a test needs three, or needs to control the starting balance, return a *function* (a factory):

```python
@pytest.fixture
def make_account(db):
    created = []
    def _make(balance=0):
        acct = Account(db, balance=balance)
        created.append(acct)
        return acct
    yield _make
    for acct in created:        # teardown knows about all of them
        acct.delete()

def test_transfer(make_account):
    src = make_account(balance=100)
    dst = make_account(balance=0)
    transfer(src, dst, 40)
    assert (src.balance, dst.balance) == (60, 40)
```

The factory pattern gives the test control over its data while the fixture still owns cleanup.

---

## Debugging

- **`fixture 'account' not found`.** The parameter name doesn't match a fixture name, or the fixture lives in a file that isn't `conftest.py` and isn't in the same module. Move shared fixtures to `conftest.py`.
- **Teardown didn't run / resources leaked.** You used `return` instead of `yield`. Only `yield` fixtures have a teardown phase. Also: code *after* `yield` is skipped only if the *setup* (before `yield`) raised — put the `yield` right after setup succeeds.
- **Tests pass alone but fail when run together (or in a different order).** Classic shared-state bug: a fixture with `scope` broader than `function` is being mutated. Narrow the scope, or reset state in the fixture. Run `pytest -p no:randomly` or inspect order; order-dependence is always a bug.
- **A `session`/`module` fixture seems to run multiple times.** It runs once per scope-instance: `module` runs once per *file*. If you have it in `conftest.py` and expected once per whole run, you wanted `scope="session"`.
- **`tmp_path` files are gone when I look.** pytest cleans them after the test (it keeps the last few runs under a base temp dir). That's the point — don't rely on them persisting.
- **`autouse` fixture isn't firing.** Check its scope and placement — an `autouse` fixture in a module only applies to that module. Put it in `conftest.py` for project-wide reach.
- **Fixture does expensive work every test and the suite is slow.** Consider widening scope to `module`/`session` — but only if the resource is safe to share. If not, the cost is the price of isolation.

---

## Checkpoint

You can now:

- Explain a fixture in one line: *setup declared once and injected into any test that names it, with teardown after `yield`.*
- Write a `yield` fixture and know its teardown runs even when the test fails.
- Compose fixtures (a fixture requesting another) and predict teardown order (reverse).
- Choose a scope deliberately, trading isolation for speed, and know which resources are safe to widen.
- Put shared fixtures in `conftest.py` and explain its nesting/auto-discovery.
- Reach for `tmp_path`, `capsys`, and `monkeypatch` instead of hand-rolling temp files, output capture, and env patching.
- Write a factory fixture for tests that need multiple or parameterized objects.

Self-test: a colleague makes their `db` fixture `scope="session"` to speed up the suite, and suddenly one test fails only when the full suite runs. What's your first hypothesis? (Shared mutable DB state leaking across tests — the session-scoped connection carries writes from earlier tests. Fix: reset/rollback per test, or narrow the scope.) Next: **parametrization** — running one test against a table of inputs, and markers to skip, xfail, and categorize.
