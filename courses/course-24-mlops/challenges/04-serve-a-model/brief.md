# Serve a Model

The ML team trained an Iris classifier yesterday and dropped it in the model registry — a local pickle file. Today the serving team owns it: take the artifact, wrap it in a FastAPI service, and make it production-safe before the demo goes live.

A ticket comment reads: *"The `/predict` endpoint is wired but stubs 501. Three things to fix: load the model **once** at startup (not per-request), validate input with Pydantic so bad payloads get 422 not 500, and confirm the predictions are deterministic on our golden inputs."*

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-serve-a-model/
├── model.pkl          # trained sklearn LogisticRegression on Iris (seeded, reproducible)
├── app.py             # FastAPI skeleton — imports wired, startup stub, predict stub
├── model_state.py     # module-level singleton for the loaded model
└── tests/
    └── test_predict.py # visible sample (3 assertions); hidden harness runs at verify time
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-serve-a-model
python3 -m venv .venv && . .venv/bin/activate
pip install scikit-learn fastapi httpx pytest numpy
```

## Mission

Implement the following in `app.py`:

1. **Load the model once.** Use a FastAPI `lifespan` startup handler (or a module-level call in `model_state.py`) to deserialize `model.pkl` into the shared `model_state` object. The verify harness explicitly checks that `pickle.load` is not called more than once across ten `/predict` requests.

2. **`POST /predict` — Pydantic-validated input.** Accept a JSON body matching:

```json
{ "features": [5.1, 3.5, 1.4, 0.2] }
```

`features` must be a list of exactly **4 floats**. Reject anything else with **422**.

3. **Response shape.** Return JSON with two keys:

| Key | Type | Meaning |
|-----|------|---------|
| `prediction` | `int` | Iris class index (0, 1, or 2) |
| `model_version` | `str` | hard-coded `"1.0.0"` |

The verify harness asserts exact predictions on known inputs (the model artifact is fixed-seed, so results are deterministic).

## Why loading once matters

Deserializing a model on every request is the single most common ML serving performance bug. For a 500 MB neural network it's a 10-second latency spike per call. The correct pattern — module-level load or `lifespan` startup — runs deserialization once at cold start. The `lifespan` approach also lets you fail fast: if `model.pkl` is missing, the server refuses to start rather than returning 500 on the first real request.

## What the verify harness checks

| Check | Pass condition |
|-------|---------------|
| Valid input → 200 + correct prediction | `features` for known Iris samples → correct class index |
| Bad input → 422 | `features` with 3 elements, wrong type, or missing field |
| Model loaded once | `pickle.load` call count == 1 after 10 requests |

## Verify

```bash
bash courses/course-24-mlops/challenges/04-serve-a-model/verify.sh
```

All checks green → flag printed.
