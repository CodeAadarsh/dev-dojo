#!/usr/bin/env bash
# Verifier for "Serve a Model".
# Runs a hidden pytest harness; prints the flag only when all checks pass.
set -uo pipefail

SLUG="04-serve-a-model"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{model_serving_loaded_once}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]           || fail "work directory missing — run setup.sh first"
[ -f "$WORK/app.py" ]    || fail "app.py not found — run setup.sh first"
[ -f "$WORK/model.pkl" ] || fail "model.pkl not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYTHON="$WORK/.venv/bin/python3"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYTHON="python3"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install scikit-learn fastapi httpx pytest numpy"
fi

# ── write the hidden harness to a temp dir ──────────────────────────────────
TMPDIR_HARNESS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HARNESS"' EXIT

cat > "$TMPDIR_HARNESS/test_verify.py" << 'PYEOF'
# Hidden verifier harness — do not distribute.
import sys, os, unittest.mock as mock, importlib
sys.path.insert(0, os.environ["WORK"])

# Reload to ensure the lifespan fires through TestClient
import app as _app_module
importlib.reload(_app_module)
from fastapi.testclient import TestClient

# Patch pickle.load to count calls BEFORE the app starts
import pickle as _pickle
_load_count = 0
_orig_load = _pickle.load

def _counting_load(f, **kw):
    global _load_count
    _load_count += 1
    return _orig_load(f, **kw)

with mock.patch("pickle.load", side_effect=_counting_load):
    importlib.reload(_app_module)
    client = TestClient(_app_module.app)
    # Make 10 predict requests
    SETOSA     = {"features": [5.1, 3.5, 1.4, 0.2]}
    VERSICOLOR = {"features": [7.0, 3.2, 4.7, 1.4]}
    VIRGINICA  = {"features": [6.3, 3.3, 6.0, 2.5]}

    for _ in range(10):
        client.post("/predict", json=SETOSA)


def test_setosa():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json=SETOSA)
    assert r.status_code == 200, f"expected 200 for setosa, got {r.status_code}"
    assert r.json()["prediction"] == 0, f"expected class 0, got {r.json()['prediction']}"


def test_versicolor():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json=VERSICOLOR)
    assert r.status_code == 200
    assert r.json()["prediction"] == 1, f"expected class 1, got {r.json()['prediction']}"


def test_virginica():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json=VIRGINICA)
    assert r.status_code == 200
    assert r.json()["prediction"] == 2, f"expected class 2, got {r.json()['prediction']}"


def test_model_version():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json=SETOSA)
    assert r.status_code == 200
    assert r.json().get("model_version") == "1.0.0", \
        f"expected model_version '1.0.0', got {r.json().get('model_version')}"


def test_bad_length_422():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json={"features": [1.0, 2.0, 3.0]})
    assert r.status_code == 422, f"3-element features must return 422, got {r.status_code}"


def test_missing_field_422():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json={})
    assert r.status_code == 422, f"missing features must return 422, got {r.status_code}"


def test_wrong_type_422():
    client2 = TestClient(_app_module.app)
    r = client2.post("/predict", json={"features": "notalist"})
    assert r.status_code == 422, f"non-list features must return 422, got {r.status_code}"


def test_model_loaded_once():
    assert _load_count == 1, \
        f"model must be loaded exactly once across 10 requests, got pickle.load called {_load_count} times"
PYEOF

export WORK="$WORK"
if $PYTEST "$TMPDIR_HARNESS/test_verify.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "verifier has failures — fix your implementation and retry"
fi
