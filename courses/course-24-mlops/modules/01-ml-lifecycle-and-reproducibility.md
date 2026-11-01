# The ML Lifecycle & Reproducibility

> **Module 01 · Course 24** — Every ML incident I have seen in production traces back to one of two root causes: the model that went live was not the model you think it was, or the run that produced it cannot be repeated. This module is about eliminating both failure modes before they cost you a weekend.

You already know how to ship software. ML adds a second axis of change — data — and that changes everything about how you operate it.

---

## The loop: data → train → eval → deploy → monitor → retrain

MLOps is not a linear pipeline; it is a closed feedback loop that runs continuously in production.

```
               ┌──────────────────────────────────────────────────┐
               │                                                  │
  raw data ──► │  Data ingestion & validation                     │
               │    - schema check                                │
               │    - distribution check (PSI, KS)               │
               │    - train/val/test split                        │
               └──────────────┬───────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────────────────────────┐
               │  Feature engineering & store                     │
               │    - transforms as code, versioned               │
               │    - offline store → training                    │
               │    - online store → inference                    │
               └──────────────┬───────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────────────────────────┐
               │  Training                                        │
               │    - seeded, reproducible                        │
               │    - tracked (params, metrics, artifacts)        │
               └──────────────┬───────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────────────────────────┐
               │  Evaluation                                      │
               │    - champion vs challenger                      │
               │    - slice-based metrics (not just overall AUC)  │
               └──────────────┬───────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────────────────────────┐
               │  Serving / deployment                            │
               │    - REST / gRPC endpoint                        │
               │    - canary rollout or shadow mode               │
               └──────────────┬───────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────────────────────────┐
               │  Monitoring                                      │◄──── new data
               │    - data drift, concept drift                   │
               │    - prediction distribution shift               │
               │    - latency / error rate SLOs                   │
               └──────────────┬───────────────────────────────────┘
                              │
                              │  trigger on drift or scheduled
                              └──────────────────────────────────► retrain
```

Each box is owned by code that lives in version control. If any box is manual, it is a reliability risk.

---

## Why ML is harder than software to operate

A conventional service breaks when you push bad code. An ML system breaks when:

1. **Data changes** but the model doesn't — called *concept drift* or *data drift*. The service keeps returning 200 OK; accuracy silently collapses.
2. **The training environment differs from production** — called *train/serve skew*. Your laptop normalises a feature with `mean=0.35`; prod uses `mean=0.41` from an older scaler. The model sees a distribution it never trained on.
3. **A retraining run is not reproducible** — you can't diagnose regressions because you can't recreate the model that caused them.
4. **The model is a large binary artefact** — you can't `git diff` a 200 MB pickle. Standard version control workflows break down without MLflow/DVC.
5. **Evaluation metrics are deferred** — a bug in a web app shows up in logs within seconds; a model accuracy regression shows up weeks later in business metrics, making root-cause harder.

The operational discipline that closes these gaps is the subject of this course.

---

## Reproducibility: the three things you must lock down

A training run is reproducible when the same inputs produce bit-identical outputs. Three things control this:

### 1. Seeds — RNG sources and libraries that have their own state

NumPy, Python's `random`, scikit-learn, PyTorch, and TensorFlow each maintain their own RNG state. Lock all of them:

```python
import random, os, numpy as np

SEED = 42

random.seed(SEED)
os.environ["PYTHONHASHSEED"] = str(SEED)
np.random.seed(SEED)

# PyTorch:
# import torch; torch.manual_seed(SEED); torch.cuda.manual_seed_all(SEED)
# torch.backends.cudnn.deterministic = True

# scikit-learn: pass random_state=SEED to every estimator and split
from sklearn.model_selection import train_test_split
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=SEED)
```

`random_state=SEED` in scikit-learn is the most commonly forgotten one. If a team member forgets it in `GridSearchCV`, the CV folds shuffle differently and AUC moves ±0.5% for no reason.

### 2. Pinned dependencies — the exact `requirements.txt` matters

```
scikit-learn==1.5.2
numpy==1.26.4
pandas==2.2.2
xgboost==2.1.0
```

`scikit-learn>=1.4` is not a pin — it will resolve to different versions across environments. Use `pip freeze > requirements.txt` after verifying your run, and commit that file. Better: use a lockfile (`pip-tools`, `poetry.lock`, `uv.lock`).

```bash
# generate a full lockfile from a high-level requirements.in
pip-compile requirements.in -o requirements.txt --generate-hashes
# reproduce later:
pip install -r requirements.txt --require-hashes
```

### 3. Data + code + config versioning — what went into this run

| Artefact | Tool / technique |
|----------|-----------------|
| Code | git commit SHA — never ship a model without tagging the commit that produced it |
| Hyperparameters / config | tracked per-run in MLflow, W&B, or a plain JSONL log |
| Training data | content hash (SHA-256 of the dataset file) stored alongside the model |
| Data pipeline version | the same git commit that pinned your `transform.py` |

The minimum viable approach: log `{git_sha, data_sha256, params}` as a JSON blob inside your `model/` artefact directory before writing the model weights. One `cat model/provenance.json` tells you everything that produced it.

---

## DVC: data version control concept

DVC treats large data files and model binaries the way `git-lfs` treats blobs, but with ML-specific pipeline awareness.

```
model/
  params.yaml          ← tracked by git (small, text)
  model.pkl            ← tracked by DVC (large binary, stored in S3/GCS/local cache)
  model.pkl.dvc        ← tracked by git (pointer to the content hash in the DVC store)
```

The key idea: `model.pkl.dvc` is a small text pointer that git can diff. Checkout a branch → `dvc checkout` pulls the corresponding binary from the store. DVC also models pipeline *stages* (`dvc run`) with dependency hashes so it knows which stages are stale and skips rerunning what hasn't changed — the same principle as `make`.

You don't need DVC for this course, but you need to understand the problem it solves: **you cannot git-commit a 300 MB model, but you need every training run to be as reproducible as a git commit.**

---

## Experiment tracking

Experiment tracking is structured logging for ML runs. Instead of `print(f"AUC: {auc}")` scattered across notebooks, you write:

```python
import mlflow

with mlflow.start_run():
    mlflow.log_param("max_depth", 6)
    mlflow.log_param("learning_rate", 0.05)
    mlflow.log_param("seed", 42)

    model = train(X_train, y_train, max_depth=6, lr=0.05)
    auc = evaluate(model, X_val, y_val)

    mlflow.log_metric("val_auc", auc)
    mlflow.log_metric("val_f1", f1)
    mlflow.sklearn.log_model(model, artifact_path="model")
```

The MLflow tracking server stores: run ID, git commit, params, metrics (with step/epoch), and model artefacts. The UI lets you sort/filter runs by any metric and overlay learning curves. More importantly, every run is addressable by a run ID — `mlflow.load_model("runs:/<run_id>/model")` — so you can reproduce a specific model any time.

**What to track per run (minimum):**

| Category | Examples |
|----------|---------|
| Params | hyperparameters, feature list, preprocessing flags |
| Tags | git SHA, dataset version / hash, author, experiment name |
| Metrics | loss per epoch, train/val AUC, F1, RMSE, per-class precision |
| Artefacts | serialised model, feature importance plot, confusion matrix, scaler pickle |

Track too little and you can't compare runs. Track everything and you'll thank yourself the first time a stakeholder asks "which model was in prod on Tuesday?"

---

## 'Works in the notebook' — the most common lifecycle failure

Notebooks are great for exploration; they are terrible as deployment artefacts. The failure mode:

```
Jupyter (local):
  - data loaded with pd.read_csv('~/Downloads/customer_data_final_FINAL.csv')
  - scaler.fit_transform(X)    ← scaler fitted on the whole dataset, before split
  - model.fit(X_train)
  - print(f"AUC: {roc_auc_score(y_test, model.predict_proba(X_test)[:,1])}")
  # 0.91 ← this number is a lie; the scaler saw y_test implicitly
```

Production:
```python
  # scaler loaded from where exactly?
  # 'customer_data_final_FINAL.csv' does not exist in the container
  # the model was serialised as a cell output, not an artefact
```

The fix is enforcing the lifecycle contract:
1. **Fit-then-save:** fit the scaler on `X_train` only, serialise it alongside the model.
2. **No relative paths to local files:** data lives in a store (S3, Turso, a feature store) with a versioned URI.
3. **The notebook is a scratchpad, not the source of truth** — training code lives in a `.py` module under `src/`, version-controlled, with a CLI entry point.

---

## Debugging Reproducibility & Lifecycle Issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Two runs with identical params produce different metrics | Missing seed in one of: `numpy`, `random`, estimator `random_state`, `train_test_split` | Add seeds to all four; compare `PYTHONHASHSEED` between environments |
| Metrics look great in the notebook but drop sharply in serving | Scaler or encoder was fitted on full data before split (data leakage) | Audit `fit()` calls — only `fit_transform()` on train, `transform()` on val/test |
| Model "works" locally, predicts garbage in the container | Different library versions (scikit-learn 1.4 vs 1.5 serialisation format differs) | Pin deps; log `sklearn.__version__` as a tag; use `mlflow.sklearn.log_model` which bundles the env |
| Retraining run gives lower AUC than last week's model | Data has changed (new distribution); or a code dependency was upgraded | Log data hash and git SHA per run; bisect using MLflow run history |
| Can't reproduce a run from 3 months ago | Params were not tracked; or tracked in a notebook cell that got re-run | Move training to `src/train.py`; use `mlflow.log_param` + `mlflow.log_artifact("params.json")` |
| `pickle.load` raises `AttributeError` on the serialised model | Class definition has changed since pickling; pickle encodes references, not implementations | Version the model with `mlflow.sklearn.log_model`; it stores the entire Python environment |

> **War story.** A ranking model at a past team had been running "stably" for four months. A data engineer updated the ingestion pipeline to fix a time-zone bug — UTC offset corrected by one hour — and the next weekly retrain silently produced a model 8 pp worse in offline eval. Nobody noticed for six days because we only had an overall RMSE alert, not per-segment metrics, and the degradation was concentrated in a small user cohort. The data hash we had been logging (SHA-256 of the Parquet file) was the first clue: the hash changed on the retrain date. We could then git-blame the ingestion diff and roll back the training dataset to the last known-good hash while we fixed the underlying issue. Without the data hash, we would have been debugging a model diff with no way to isolate the data change from any code change. Log the data hash. Every time. No exceptions.

---

## Checkpoint

You are ready for the challenges in this course when you can, without looking anything up:

1. Sketch the ML lifecycle loop from data through retrain, naming which stage each of: train/serve skew, data drift, and data leakage belongs to.
2. List every RNG source you must seed in a scikit-learn + NumPy training script, including the environment variable.
3. Explain why `scikit-learn>=1.4` in `requirements.txt` is not a pin, and generate a reproducible lockfile with one `pip-tools` command.
4. Describe the structure of a `.dvc` pointer file and explain what problem DVC solves that `git-lfs` alone does not.
5. Write the five `mlflow` calls that constitute a minimal, reproducible tracking loop: start run, log param, log metric, log model artefact, set a git SHA tag.
6. Identify the line in a notebook training script that causes leakage when the scaler is fitted before the train/test split, and write the corrected version.
7. Given a symptom of "two runs with identical hyperparameters produce different AUC", list in order the three seeds / env vars you check first.
8. Articulate the "works in the notebook" failure pattern and describe the three structural changes that prevent it.

➡ Next up: **Data & Feature Pipelines** — where the bugs hide before a model is ever trained.
