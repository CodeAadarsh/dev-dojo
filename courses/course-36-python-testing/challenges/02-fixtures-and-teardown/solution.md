# Solution — Fixtures & Teardown

A factory fixture gives each test a fresh store (and access to the path for the persistence test). `tmp_path` handles cleanup for free.

```python
# test_store.py
import pytest
from store import KeyValueStore


@pytest.fixture
def store_path(tmp_path):
    return tmp_path / "db.json"

@pytest.fixture
def store(store_path):
    return KeyValueStore(store_path)


def test_new_store_is_empty(store):
    assert store.keys() == []

def test_set_then_get(store):
    store.set("a", 1)
    assert store.get("a") == 1

def test_multiple_keys_all_persist(store):
    store.set("a", 1)
    store.set("b", 2)
    assert store.get("a") == 1          # catches 'set replaces whole store'
    assert store.get("b") == 2
    assert store.keys() == ["a", "b"]

def test_overwrite_replaces_only_that_value(store):
    store.set("a", 1)
    store.set("a", 99)
    assert store.get("a") == 99

def test_get_missing_returns_none(store):
    assert store.get("nope") is None    # catches 'get missing raises'

def test_delete_removes_key(store):
    store.set("a", 1)
    store.delete("a")
    assert store.get("a") is None       # catches 'delete does not persist'

def test_delete_missing_raises(store):
    with pytest.raises(KeyError):
        store.delete("ghost")           # catches 'delete silent'

def test_keys_are_sorted(store):
    store.set("c", 3)                   # insert out of order on purpose
    store.set("a", 1)
    store.set("b", 2)
    assert store.keys() == ["a", "b", "c"]   # catches 'keys unsorted'

def test_persistence_across_instances(store_path):
    first = KeyValueStore(store_path)
    first.set("k", "v")
    second = KeyValueStore(store_path)  # same path, new object
    assert second.get("k") == "v"
```

## Why the fixtures

- **`store_path`** isolates the path on `tmp_path` so no two tests collide and nothing leaks to your real filesystem. pytest deletes the temp dir afterward — that *is* your teardown, for free.
- **`store`** depends on `store_path` (fixtures composing) so most tests get a ready store in one line.
- The **persistence** test requests `store_path` directly because it needs to build *two* store objects on the same path — you can't do that with a single shared `store` instance.

## The lessons

1. **`tmp_path` is teardown without `yield`.** For filesystem tests you rarely need an explicit cleanup block — pytest manages the temp directory's lifecycle. (When you own a resource pytest doesn't, like a socket or a DB connection, *then* you reach for `yield` + explicit teardown.)
2. **Isolation is the fixture's job.** Because each test gets a fresh path, they can run in any order, in parallel, repeatedly — no shared state. That's the property that makes a suite trustworthy.
3. **Insert out of order to test ordering.** `test_keys_are_sorted` would pass against the unsorted mutant if you inserted `a, b, c` in order (insertion order == sorted order). Inserting `c, a, b` is what makes the assertion able to *fail* on the bug.
