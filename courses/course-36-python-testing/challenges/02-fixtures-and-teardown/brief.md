# Fixtures & Teardown

## The setup

You've got a `KeyValueStore` — a tiny persistent dictionary backed by a JSON file on disk. Because it touches the filesystem, testing it naively is a mess: every test needs a file path, every test could leave a file behind, and two tests sharing a path would pollute each other.

This is exactly what **fixtures** are for. Your mission is to test the store *properly*: a fixture using the built-in `tmp_path` that hands each test its own fresh, isolated store, with no manual cleanup. Then your assertions have to be strong enough to catch every planted bug.

## The code under test

`setup.sh` plants `store.py`:

```python
import json, os

class KeyValueStore:
    def __init__(self, path):
        self.path = str(path)
        if not os.path.exists(self.path):
            self._write({})

    def _read(self):
        with open(self.path) as f:
            return json.load(f)

    def _write(self, data):
        with open(self.path, "w") as f:
            json.dump(data, f)

    def set(self, key, value):
        data = self._read()
        data[key] = value
        self._write(data)

    def get(self, key):
        return self._read().get(key)

    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]
        self._write(data)

    def keys(self):
        return sorted(self._read().keys())
```

## The spec

1. A new store on a fresh path starts **empty** (`keys() == []`).
2. `set(k, v)` then `get(k)` returns `v`.
3. Setting **multiple** keys keeps all of them — `set` updates, it does not replace the whole store.
4. Overwriting an existing key with `set` replaces just that key's value.
5. `get` of a missing key returns `None`.
6. `delete(k)` removes the key; `get(k)` is then `None`.
7. `delete` of a **missing** key raises `KeyError`.
8. `keys()` returns all keys **sorted**.
9. **Persistence**: a second `KeyValueStore` pointed at the same path sees previously-written data.

## Your mission — and the rules

Write tests in `test_store.py`. You **must**:

- Define a **fixture** (`@pytest.fixture`) that builds a store on a path under **`tmp_path`** and returns it, so each test gets its own fresh file. The verifier checks that your test file uses both `@pytest.fixture` and `tmp_path`.
- Cover every rule above with specific assertions.

For the "persistence" rule you'll need two store objects on the *same* path — a good reason for your fixture to hand back the `tmp_path` (or the path) as well as, or instead of, the store. A factory fixture (returns a function that builds a store) is one clean way.

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/02-fixtures-and-teardown/setup.sh
# write tests in ~/.kube-dojo-work/02-fixtures-and-teardown/test_store.py
bash courses/course-36-python-testing/challenges/02-fixtures-and-teardown/verify.sh
```
