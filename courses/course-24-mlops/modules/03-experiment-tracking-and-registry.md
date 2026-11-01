# Experiment Tracking & the Model Registry

> **Module 03 · Course 24** — If you can't answer "what model is in production right now and what training run produced it", you don't have an ML system — you have a black box that occasionally gets replaced by a slightly different black box. Experiment tracking and a model registry are how you fix that.

---

## The problem: untracked experiments compound into unmanageable debt

Without tracking, a typical team runs through this lifecycle:

```
Week 1:  model_v1.pkl       ← trained locally, emailed to the team
Week 3:  model_v2_fixed.pkl ← "I improved it" — improved how?
Week 6:  model_final.pkl    ← no, THIS is the final one
Week 8:  model_final2.pkl   ← ...
Week 10: prod deployment     ← which of these four is in prod?
         rollback needed     ← which one do we roll back to?
```

Experiment tracking gives every training run a permanent, addressable record. The model registry gives the model binary the same.

---

## Experiment tracking with MLflow

MLflow is the de facto open-source experiment tracker. It exposes four concepts:

| Concept | What it is |
|---------|-----------|
| **Experiment** | A named collection of related runs (e.g. "churn-model-q3-2024") |
| **Run** | One training execution with a fixed start/end time and a unique `run_id` |
| **Params** | Key-value pairs that are fixed before the run (hyperparameters, feature list) |
| **Metrics** | Numeric values logged during or after training (loss, AUC, F1); can be logged with a `step` for epoch-level curves |
| **Tags** | Free-form metadata (git SHA, author, dataset version) |
| **Artifacts** | Files stored alongside the run (model binary, plots, encoders, feature importance) |

### Minimal tracking loop

```python
import mlflow
import mlflow.sklearn
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import roc_auc_score
import subprocess, json, hashlib

def get_git_sha():
    return subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()

def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

mlflow.set_experiment("churn-model-q3-2024")

params = {
    "n_estimators": 300,
    "max_depth": 5,
    "learning_rate": 0.05,
    "subsample": 0.8,
    "random_state": 42,
}

with mlflow.start_run() as run:
    mlflow.set_tag("git_sha", get_git_sha())
    mlflow.set_tag("dataset_sha256", file_sha256("data/train.parquet"))
    mlflow.set_tag("feature_set_version", "v3")
    mlflow.log_params(params)

    model = GradientBoostingClassifier(**params)
    model.fit(X_train, y_train)

    for i, (loss,) in enumerate(zip(model.train_score_)):
        mlflow.log_metric("train_loss", loss, step=i)

    val_auc = roc_auc_score(y_val, model.predict_proba(X_val)[:, 1])
    mlflow.log_metric("val_auc", val_auc)

    mlflow.sklearn.log_model(
        model,
        artifact_path="model",
        registered_model_name="churn-classifier",  # auto-registers in the registry
    )

    print(f"Run ID: {run.info.run_id}")
    print(f"Val AUC: {val_auc:.4f}")
```

After this runs, `mlflow ui` shows the full history. Every column is sortable; clicking a run shows the exact params, metric curves, and a download link to the model artefact.

### What to log per run — a complete checklist

```python
# params (set once; log_params takes a dict)
mlflow.log_params({
    "n_estimators": 300,
    "max_depth": 5,
    "feature_list": "v3",       # version string, not the full list (keep it short)
    "train_cutoff": "2024-09-01",
    "seed": 42,
})

# tags (free-form metadata)
mlflow.set_tags({
    "git_sha": get_git_sha(),
    "dataset_sha256": file_sha256("data/train.parquet"),
    "author": "aadarsh",
    "run_type": "hyperparam_sweep",
})

# metrics (log per epoch for curves, final for summary)
mlflow.log_metric("val_auc", val_auc)
mlflow.log_metric("val_f1",  val_f1)
mlflow.log_metric("val_brier", brier_score)

# artifacts (log the full file, not just a number)
mlflow.log_artifact("reports/feature_importance.png")
mlflow.log_artifact("reports/confusion_matrix.png")
mlflow.log_artifact("model/scaler.pkl")          # log the scaler separately too
```

---

## The model registry: versions, stages, and lineage

The MLflow Model Registry is a catalog that sits on top of the tracking server. A model registered in the registry has:

```
Model: churn-classifier
  ├── Version 1  ←── run_id: abc123, git_sha: d4e5f6, val_auc: 0.88, stage: Archived
  ├── Version 2  ←── run_id: def456, git_sha: a1b2c3, val_auc: 0.91, stage: Production
  └── Version 3  ←── run_id: ghi789, git_sha: b2c3d4, val_auc: 0.90, stage: Staging
```

Stages are a lightweight governance gate. The four built-in MLflow stages:

| Stage | Meaning |
|-------|---------|
| `None` | just registered, not promoted anywhere |
| `Staging` | passed offline eval; ready for shadow-mode or A/B in serving |
| `Production` | the currently live model |
| `Archived` | superseded; kept for rollback lineage |

### Promoting a model

```python
client = mlflow.tracking.MlflowClient()

# Promote version 3 to Staging for shadow evaluation
client.transition_model_version_stage(
    name="churn-classifier",
    version=3,
    stage="Staging",
    archive_existing_versions=False,  # keep v2 in Production during shadow eval
)

# After shadow eval passes: promote v3 to Production, archive v2 automatically
client.transition_model_version_stage(
    name="churn-classifier",
    version=3,
    stage="Production",
    archive_existing_versions=True,
)
```

### Loading by stage — the serving contract

The serving layer should load by stage name, not by run ID or version number. This decouples deployments:

```python
import mlflow.pyfunc

# always loads whatever is currently tagged "Production"
model = mlflow.pyfunc.load_model("models:/churn-classifier/Production")

# for audit / rollback: load a specific version
model_v2 = mlflow.pyfunc.load_model("models:/churn-classifier/2")
```

When you promote a new version to Production, the serving layer picks it up on its next model reload — no redeploy needed. The run ID, git SHA, and dataset hash stored in that version's tags answer "what exactly is in prod" without looking at anything else.

---

## Comparing models: the discipline of champion/challenger

Never promote a model based on a single metric. The champion/challenger comparison matrix:

| Metric | Champion (v2) | Challenger (v3) | Winner |
|--------|--------------|----------------|--------|
| Val AUC | 0.910 | 0.907 | v2 |
| Val F1 (thresh=0.5) | 0.843 | 0.851 | v3 |
| Val Brier | 0.098 | 0.094 | v3 |
| P99 inference latency | 12 ms | 9 ms | v3 |
| Model size | 18 MB | 8 MB | v3 |
| Precision on high-value cohort | 0.72 | 0.79 | v3 |

On a single metric, v2 wins. On everything else, v3 wins. The right answer depends on which metric aligns with the business objective — and that decision should be documented in the registry as a comment on the promotion event, not buried in someone's notebook.

```python
# Add a promotion rationale comment to the registry version
client.update_model_version(
    name="churn-classifier",
    version=3,
    description=(
        "Promoted over v2 despite marginally lower AUC (0.907 vs 0.910) "
        "because F1 on high-value cohort is +7pp and model size is -56%. "
        "Shadow eval on 2024-10-01 traffic showed prediction distribution match. "
        "git_sha=b2c3d4, dataset_sha=e3f4a5."
    ),
)
```

---

## Debugging Experiment Tracking & the Model Registry

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| MLflow run shows no metrics | `mlflow.log_metric` was called outside `with mlflow.start_run():` block, or run ended before the `log_metric` call | Always use the context manager; put all log calls inside the `with` block |
| Two runs show identical params but different metrics | One param was changed in code but not re-logged (or logged by a different name) | Use `mlflow.log_params(vars(args))` from an `argparse.Namespace` — logs every CLI param atomically |
| 'Which model is in prod?' has no definitive answer | Models deployed by copying `.pkl` files, not using the registry | Add a mandatory registry promotion step to the CI/CD pipeline; serving code loads by stage |
| Model rollback fails because the old version is gone | Models deleted from storage after promotion (common with a local `mlruns/` directory) | Point MLflow tracking server at an S3/GCS backend; never run `mlflow gc` in production |
| `mlflow.pyfunc.load_model` raises `MlflowException: RESOURCE_DOES_NOT_EXIST` | Tracking server URI not set in the serving environment | Set `MLFLOW_TRACKING_URI` env var; verify with `mlflow.get_tracking_uri()` |
| Challenger model is promoted but performs worse in prod than in shadow | Shadow eval period was too short or traffic was not representative | Require 48h shadow eval with ≥10K predictions; report prediction distribution (PSI) as a promotion gate |
| Experiment names proliferate; can't find historical runs | No naming convention enforced | Enforce `{team}-{model}-{quarter}` naming convention in the CI runner that triggers training |

> **War story.** At a previous team, we had a model "deployed to production" for a content ranking service. One day a senior engineer asked a simple question: "Can you show me the training run that produced the model currently in prod?" We could not. The model had been serialised locally, renamed several times, and rsync'd to an S3 path. The MLflow tracking server existed but no one had been logging to it consistently. When the model started degrading and we needed to retrain from the same checkpoint, we had no record of which hyperparameters had been used, what data had been used, or even which version of the feature engineering code was current at train time. The investigation took three days. We found the right parameters by reading a stale comment in a Slack thread. After that, the team adopted a rule: no model may be deployed unless the serving code loads it from the registry by stage name, and every registry promotion requires the training run ID. Two lines of policy, zero more lost weekends.

---

## Checkpoint

You are ready for the challenges in this course when you can, without looking anything up:

1. Name the five MLflow concepts (Experiment, Run, Params, Metrics, Tags, Artifacts) and give one example of what you would log in each.
2. Write the five lines that constitute the minimal tracking loop: set experiment, start run, log params dict, log a metric, log the model artefact with a registered model name.
3. Explain the four MLflow model registry stages and in which order a model moves through them from training to production rollback.
4. Write the two `client.transition_model_version_stage` calls required to promote a challenger to Production while archiving the current champion.
5. Write the `mlflow.pyfunc.load_model` call that loads the current Production model by stage name, and explain why this is preferable to loading by version number.
6. Describe the "which model is in prod?" failure mode and name the two process changes that prevent it.
7. Given a run comparison table with AUC, F1, latency, and cohort precision, articulate how you decide which model to promote and where to record that decision.
8. List three reasons an MLflow run might show no metrics, and give the fix for each.

➡ Next up: **Model Serving** — getting predictions out at latency SLOs, at scale, without OOM.
