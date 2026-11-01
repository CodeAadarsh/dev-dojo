# Solution — Serve a Model

Complete implementation of `model_state.py` and `app.py`.

## `model_state.py`

```python
import pickle

_model = None


def load(path: str) -> None:
    global _model
    with open(path, "rb") as f:
        _model = pickle.load(f)


def predict(features):
    if _model is None:
        raise RuntimeError("model not loaded — call load() at startup")
    import numpy as np
    return int(_model.predict([features])[0])
```

## `app.py`

```python
import os
from contextlib import asynccontextmanager
from typing import List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, field_validator
import model_state

MODEL_PATH = os.path.join(os.path.dirname(__file__), "model.pkl")
MODEL_VERSION = "1.0.0"


@asynccontextmanager
async def lifespan(app: FastAPI):
    model_state.load(MODEL_PATH)
    yield


app = FastAPI(lifespan=lifespan)


class PredictRequest(BaseModel):
    features: List[float]

    @field_validator("features")
    @classmethod
    def must_be_four(cls, v):
        if len(v) != 4:
            raise ValueError("features must have exactly 4 elements")
        return v


class PredictResponse(BaseModel):
    prediction: int
    model_version: str


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    pred = model_state.predict(req.features)
    return PredictResponse(prediction=pred, model_version=MODEL_VERSION)
```

## Why each piece matters

**`lifespan` startup hook.** The `@asynccontextmanager` approach replaced the older `on_event("startup")` in FastAPI 0.93+. Code before the `yield` runs at cold start; code after runs on shutdown. Calling `model_state.load()` here means deserialization happens exactly once — the process either starts healthy or fails immediately, never silently.

**`@field_validator("features")`.** Pydantic v2 validators run before the endpoint body executes. A 4-element validation in the validator means the framework returns a structured `422 Unprocessable Entity` with a JSON error body — never a raw Python exception. That 422 is what clients (and the harness) assert on malformed input.

**Module-level `_model = None` in `model_state.py`.** The singleton is the only global mutable state in the service. Keeping it in a separate module avoids circular imports and makes the load-once invariant auditable in one place: `grep _model model_state.py` shows every write.

**`int(_model.predict([features])[0])`.** `sklearn.predict` returns a numpy array; indexing gives a numpy `int64`, which is not JSON-serializable. Wrapping with `int()` coerces it to a Python int — Pydantic and `json.dumps` both handle that correctly. Forgetting this step raises a `TypeError` on the first real request, caught only in production.

## Apply and verify

```bash
cd ~/.kube-dojo-work/04-serve-a-model
# Replace model_state.py and app.py with the solutions above, then:
.venv/bin/pytest tests/ -v
bash courses/course-24-mlops/challenges/04-serve-a-model/verify.sh
```
