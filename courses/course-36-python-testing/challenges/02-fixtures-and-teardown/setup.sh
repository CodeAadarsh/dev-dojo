#!/usr/bin/env bash
# Plants the "Fixtures & Teardown" exercise.
set -euo pipefail

SLUG="02-fixtures-and-teardown"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/store.py" << 'PYEOF'
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
PYEOF

if [ ! -f "$WORK/test_store.py" ]; then
cat > "$WORK/test_store.py" << 'PYEOF'
import pytest
from store import KeyValueStore


# A factory fixture: returns a function that builds a store on a path under
# tmp_path. Each test gets its own file, so tests never pollute each other.
@pytest.fixture
def make_store(tmp_path):
    def _make(name="db.json"):
        return KeyValueStore(tmp_path / name)
    return _make


# Example — fill in the rest to cover the whole spec.
def test_set_then_get(make_store):
    store = make_store()
    store.set("a", 1)
    assert store.get("a") == 1


# TODO: cover the spec:
#   - new store is empty (keys() == [])
#   - multiple keys all persist (set updates, does not replace)
#   - overwriting a key replaces only that value
#   - get of a missing key returns None
#   - delete removes a key; delete of a missing key raises KeyError
#   - keys() is sorted (insert out of order to prove it)
#   - persistence: a second store on the SAME path sees the data
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  store.py       — the code under test (read it; do NOT modify it)"
echo "  test_store.py  — write your tests here (a fixture starter is included)"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo "Iterate:         cd $WORK && .venv/bin/pytest -v"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
