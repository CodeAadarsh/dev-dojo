#!/usr/bin/env bash
# Plants the "Serve a Model" starter project.
# Idempotent — re-running overwrites source files but does not touch .venv.
set -euo pipefail

SLUG="04-serve-a-model"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── train & serialize the model artifact ────────────────────────────────────
python3 - << 'PYEOF'
import pickle, os, sys
try:
    from sklearn.datasets import load_iris
    from sklearn.linear_model import LogisticRegression
    import numpy as np
except ImportError:
    print("ERROR: scikit-learn or numpy not installed. Run: pip install scikit-learn numpy")
    sys.exit(1)

work = os.path.expanduser("~/.kube-dojo-work/04-serve-a-model")
out  = os.path.join(work, "model.pkl")

iris = load_iris()
X, y = iris.data, iris.target
clf = LogisticRegression(random_state=42, max_iter=200)
clf.fit(X, y)

with open(out, "wb") as f:
    pickle.dump(clf, f)
print(f"model artifact written to {out}")
PYEOF

# ── model_state.py ───────────────────────────────────────────────────────────
cat > "$WORK/model_state.py" << 'PYEOF'
# model_state.py — module-level singleton for the loaded model.
# Call load() once at server startup; predict() raises if called before load().

_model = None


def load(path: str) -> None:
    """Deserialize the model artifact from *path* and store it here."""
    global _model
    # TODO: deserialize model.pkl into _model using pickle
    raise NotImplementedError("load() not implemented")


def predict(features):
    """Return the model's prediction (int) for *features* (list[float])."""
    if _model is None:
        raise RuntimeError("model not loaded — call load() at startup")
    # TODO: call _model.predict([features]) and return the class index as int
    raise NotImplementedError("predict() not implemented")
PYEOF

# ── app.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
# app.py — model-serving skeleton.
# Complete the three TODOs:
#   1. lifespan: load the model once at startup
#   2. PredictRequest: Pydantic model that validates exactly 4 floats
#   3. /predict: call model_state.predict, return prediction + model_version
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import model_state

MODEL_PATH = os.path.join(os.path.dirname(__file__), "model.pkl")
MODEL_VERSION = "1.0.0"


@asynccontextmanager
async def lifespan(app: FastAPI):
    # TODO: call model_state.load(MODEL_PATH) here so the model is loaded once
    yield


app = FastAPI(lifespan=lifespan)


class PredictRequest(BaseModel):
    # TODO: define the 'features' field — a list of exactly 4 floats.
    # Hint: use a plain List[float] for now and validate length in the endpoint.
    pass


class PredictResponse(BaseModel):
    prediction: int
    model_version: str


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    # TODO: validate len(req.features) == 4, return 422 if not;
    #       call model_state.predict(req.features), return PredictResponse.
    raise HTTPException(status_code=501, detail="not implemented")
PYEOF

# ── visible sample test ──────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_predict.py" << 'PYEOF'
# Visible sample tests — run these locally to check your progress.
# The verifier runs a superset (including the load-once assertion).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from app import app

client = TestClient(app)

# Known Iris sample: setosa (class 0)
SETOSA = {"features": [5.1, 3.5, 1.4, 0.2]}
# Known Iris sample: versicolor (class 1)
VERSICOLOR = {"features": [7.0, 3.2, 4.7, 1.4]}
# Known Iris sample: virginica (class 2)
VIRGINICA = {"features": [6.3, 3.3, 6.0, 2.5]}


def test_setosa_prediction():
    r = client.post("/predict", json=SETOSA)
    assert r.status_code == 200, f"expected 200, got {r.status_code}"
    assert r.json()["prediction"] == 0


def test_bad_input_length_returns_422():
    r = client.post("/predict", json={"features": [1.0, 2.0, 3.0]})
    assert r.status_code == 422, f"expected 422 for 3-element features, got {r.status_code}"


def test_response_has_model_version():
    r = client.post("/predict", json=VERSICOLOR)
    assert r.status_code == 200
    assert r.json()["model_version"] == "1.0.0"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : complete the three TODOs in app.py and model_state.py so"
echo "                 the verifier harness passes (correct predictions, 422 on"
echo "                 bad input, model loaded exactly once)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install scikit-learn fastapi httpx pytest numpy"
echo
echo "Run sample tests: cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag   : bash courses/course-24-mlops/challenges/04-serve-a-model/verify.sh"
