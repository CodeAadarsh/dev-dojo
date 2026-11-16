#!/usr/bin/env bash
# Verifier for "Fixtures & Teardown".
# Requires your test file to use a fixture + tmp_path, pass on the correct
# store, and fail on every mutant. Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-fixtures-and-teardown"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{fixtures_kill_duplication}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_store.py" ] || fail "test_store.py not found — run setup.sh and write your tests first"

# Structural requirement: this is a fixtures challenge.
grep -q "@pytest.fixture" "$WORK/test_store.py" || \
    fail "your test file must define a fixture (@pytest.fixture) — that's the point of this challenge"
grep -q "tmp_path" "$WORK/test_store.py" || \
    fail "your fixture must use the built-in tmp_path so each test gets its own file"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_store.py" "$TMP/test_store.py"

emit() {
    case "$1" in
    correct)
cat > "$TMP/store.py" << 'PYEOF'
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
        data = self._read(); data[key] = value; self._write(data)
    def get(self, key):
        return self._read().get(key)
    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]; self._write(data)
    def keys(self):
        return sorted(self._read().keys())
PYEOF
        ;;
    set_replaces)   # set replaces the whole store instead of updating
cat > "$TMP/store.py" << 'PYEOF'
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
        self._write({key: value})
    def get(self, key):
        return self._read().get(key)
    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]; self._write(data)
    def keys(self):
        return sorted(self._read().keys())
PYEOF
        ;;
    get_missing_raises)   # get of a missing key raises instead of returning None
cat > "$TMP/store.py" << 'PYEOF'
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
        data = self._read(); data[key] = value; self._write(data)
    def get(self, key):
        return self._read()[key]
    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]; self._write(data)
    def keys(self):
        return sorted(self._read().keys())
PYEOF
        ;;
    delete_silent)   # delete of a missing key does NOT raise
cat > "$TMP/store.py" << 'PYEOF'
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
        data = self._read(); data[key] = value; self._write(data)
    def get(self, key):
        return self._read().get(key)
    def delete(self, key):
        data = self._read()
        data.pop(key, None); self._write(data)
    def keys(self):
        return sorted(self._read().keys())
PYEOF
        ;;
    keys_unsorted)   # keys() returns insertion order, not sorted
cat > "$TMP/store.py" << 'PYEOF'
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
        data = self._read(); data[key] = value; self._write(data)
    def get(self, key):
        return self._read().get(key)
    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]; self._write(data)
    def keys(self):
        return list(self._read().keys())
PYEOF
        ;;
    delete_no_persist)   # delete removes in memory but never writes back
cat > "$TMP/store.py" << 'PYEOF'
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
        data = self._read(); data[key] = value; self._write(data)
    def get(self, key):
        return self._read().get(key)
    def delete(self, key):
        data = self._read()
        if key not in data:
            raise KeyError(key)
        del data[key]
    def keys(self):
        return sorted(self._read().keys())
PYEOF
        ;;
    esac
}

run() {
    rm -rf "$TMP/__pycache__"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_store.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct store. They must pass on correct code first."
    echo "─────────────────────────────────────────────"
    sed -n '1,40p' "$TMP/_out.txt"
    exit 1
fi

MUTANTS="set_replaces:set() replacing the whole store instead of adding a key
get_missing_raises:get() of a missing key raising instead of returning None
delete_silent:delete() of a missing key NOT raising KeyError
keys_unsorted:keys() returning insertion order instead of sorted
delete_no_persist:delete() removing a key but not persisting the removal"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your suite still PASSES with this bug: $desc"
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "some planted bugs slipped through — strengthen your tests and retry"

echo
echo "All checks passed — fixture in place, every planted bug caught. Submit this flag:"
echo
echo "    $FLAG"
