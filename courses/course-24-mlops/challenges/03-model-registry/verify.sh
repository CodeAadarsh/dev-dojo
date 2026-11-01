#!/usr/bin/env bash
# Verifier for "Model Registry".
# Writes a hidden pytest harness into $WORK/_judge/, runs it, prints the flag
# only when all five tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-model-registry"
FLAG='KUBE{model_registry_versioned}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/registry.py" ] || fail "registry.py not found — run setup.sh first"

mkdir -p "$WORK/_judge"

# ── hidden test harness ──────────────────────────────────────────────────────
cat > "$WORK/_judge/test_registry.py" << 'PYEOF'
import sys
import os
import importlib.util
import tempfile

import numpy as np
from sklearn.datasets import make_classification
from sklearn.linear_model import LogisticRegression

WORK = os.environ["DOJO_WORK"]
sys.path.insert(0, WORK)


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "registry_mod", os.path.join(WORK, "registry.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = _load_module()

X, y = make_classification(n_samples=100, n_features=5, random_state=42)


def _make_model(seed: int):
    m = LogisticRegression(random_state=seed, max_iter=300)
    m.fit(X, y)
    return m


def test_register_and_list():
    with tempfile.TemporaryDirectory() as td:
        reg = mod.ModelRegistry(td)
        reg.register("clf", "1", _make_model(1), {"accuracy": 0.85})
        reg.register("clf", "2", _make_model(2), {"accuracy": 0.88})
        versions = reg.list_versions("clf")
        assert len(versions) == 2, (
            f"list_versions should return 2 entries, got {len(versions)}"
        )
        ver_strs = [v["version"] for v in versions]
        assert "1" in ver_strs and "2" in ver_strs, (
            f"expected versions '1' and '2', got {ver_strs}"
        )


def test_metadata_round_trip():
    with tempfile.TemporaryDirectory() as td:
        reg = mod.ModelRegistry(td)
        reg.register("clf", "1", _make_model(1), {"accuracy": 0.85, "framework": "sklearn"})
        # Fresh instance — must read from disk
        reg2 = mod.ModelRegistry(td)
        versions = reg2.list_versions("clf")
        v1 = next(v for v in versions if v["version"] == "1")
        assert v1["metadata"].get("accuracy") == 0.85, (
            "metadata['accuracy'] not preserved through disk round-trip"
        )
        assert v1["metadata"].get("framework") == "sklearn", (
            "metadata['framework'] not preserved"
        )


def test_load_by_version():
    with tempfile.TemporaryDirectory() as td:
        reg = mod.ModelRegistry(td)
        m1 = _make_model(1)
        m2 = _make_model(2)
        reg.register("clf", "1", m1, {})
        reg.register("clf", "2", m2, {})
        loaded = reg.load("clf", "1")
        assert np.array_equal(m1.predict(X), loaded.predict(X)), (
            "load('clf','1') returned the wrong model"
        )


def test_promote_and_load_alias():
    with tempfile.TemporaryDirectory() as td:
        reg = mod.ModelRegistry(td)
        m1 = _make_model(1)
        m2 = _make_model(2)
        reg.register("clf", "1", m1, {"accuracy": 0.85})
        reg.register("clf", "2", m2, {"accuracy": 0.88})
        reg.promote("clf", "2", alias="production")
        # Fresh instance to confirm persistence
        reg2 = mod.ModelRegistry(td)
        prod = reg2.load("clf", "production")
        assert np.array_equal(m2.predict(X), prod.predict(X)), (
            "load('clf','production') returned the wrong version — "
            "promote should persist the alias so a fresh registry instance resolves it"
        )


def test_duplicate_version_raises():
    with tempfile.TemporaryDirectory() as td:
        reg = mod.ModelRegistry(td)
        reg.register("clf", "1", _make_model(1), {})
        try:
            reg.register("clf", "1", _make_model(1), {})
            raise AssertionError(
                "register() must raise ValueError for a duplicate (name, version)"
            )
        except ValueError:
            pass
PYEOF

# ── locate pytest ────────────────────────────────────────────────────────────
cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install scikit-learn numpy pytest"
fi

# ── run ──────────────────────────────────────────────────────────────────────
if DOJO_WORK="$WORK" $PYTEST _judge/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
