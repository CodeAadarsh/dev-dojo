# Solution — Reproducible Training

## Complete `train.py`

```python
import numpy as np
import pickle
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score

SEED = 42
THRESHOLD = 0.80


def make_dataset():
    """Seeded dataset — do not modify this function."""
    X, y = make_classification(
        n_samples=1000,
        n_features=20,
        n_informative=10,
        n_redundant=5,
        random_state=SEED,
    )
    return X, y


def train() -> float:
    X, y = make_dataset()

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=SEED
    )

    model = RandomForestClassifier(n_estimators=100, random_state=SEED, n_jobs=1)
    model.fit(X_train, y_train)

    acc = float(accuracy_score(y_test, model.predict(X_test)))
    with open("model.pkl", "wb") as fh:
        pickle.dump(model, fh)
    return acc
```

## Why each line is required

**`random_state=SEED` on `train_test_split`.**
Without it, the split indices are re-sampled from `os.urandom` on every call. The test set changes, your reported accuracy is from a different fold each run, and the model sees a different training set — all three hurt reproducibility.

**`random_state=SEED` on `RandomForestClassifier`.**
A random forest bootstraps samples and randomly subsets features at each split. Both operations draw from an internal RNG seeded by `random_state`. Two `RandomForestClassifier(n_estimators=100)` calls without a fixed seed grow different trees — same inputs, different predictions.

**`n_jobs=1`.**
Scikit-learn's parallel tree building (`n_jobs=-1`) dispatches work to multiple threads and then accumulates results. The order of floating-point additions is non-deterministic across threads, producing tiny weight differences that cascade into different split decisions. `n_jobs=1` eliminates the race at the cost of single-core speed — the right trade-off for a training job whose output must be bit-reproducible.

**`float(accuracy_score(...))`.**
`accuracy_score` returns a numpy float64. The verifier checks `isinstance(result, float)`. Python's `float()` converts numpy scalars cleanly; relying on implicit coercion is fragile.

**`pickle.dump` in `open("model.pkl", "wb")`.**
The path is relative — `verify.sh` `cd`s to `$WORK` before running, so `"model.pkl"` resolves to `$WORK/model.pkl`. `"wb"` is mandatory: `pickle` writes binary; opening in text mode (`"w"`) causes a cryptic `TypeError`.

## Alternative: LogisticRegression

```python
from sklearn.linear_model import LogisticRegression

model = LogisticRegression(random_state=SEED, max_iter=500, solver="lbfgs")
```

`LogisticRegression` with `solver="lbfgs"` is deterministic by design on a single thread and comfortably clears the 0.80 threshold on this dataset. It has no bootstrap or feature-subsampling randomness, so `random_state` only affects the initialisation of the optimiser's internal shuffle — still worth setting for full determinism.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-reproducible-training
# replace train.py with the solution above, then:
python3 -c 'from train import train; print(train())'
bash courses/course-24-mlops/challenges/01-reproducible-training/verify.sh
```
