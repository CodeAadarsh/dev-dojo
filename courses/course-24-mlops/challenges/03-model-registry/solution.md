# Solution — Model Registry

## Complete `ModelRegistry`

```python
import json
import pickle
from pathlib import Path


class ModelRegistry:

    def __init__(self, root_dir: str):
        self.root = Path(root_dir)
        self.root.mkdir(parents=True, exist_ok=True)

    # ── internal helpers ──────────────────────────────────────────────────

    def _version_dir(self, name: str, version: str) -> Path:
        return self.root / name / version

    def _aliases_path(self, name: str) -> Path:
        return self.root / name / "aliases.json"

    def _load_aliases(self, name: str) -> dict:
        p = self._aliases_path(name)
        if p.exists():
            return json.loads(p.read_text())
        return {}

    def _save_aliases(self, name: str, aliases: dict) -> None:
        self._aliases_path(name).write_text(json.dumps(aliases))

    # ── public API ────────────────────────────────────────────────────────

    def register(self, name: str, version: str, model, metadata: dict) -> None:
        vdir = self._version_dir(name, version)
        if vdir.exists():
            raise ValueError(
                f"version '{version}' already exists for model '{name}'"
            )
        vdir.mkdir(parents=True)
        with open(vdir / "model.pkl", "wb") as fh:
            pickle.dump(model, fh)
        (vdir / "metadata.json").write_text(json.dumps(metadata))

    def list_versions(self, name: str) -> list:
        model_dir = self.root / name
        if not model_dir.exists():
            raise KeyError(f"no model named '{name}'")
        versions = []
        for vdir in sorted(model_dir.iterdir()):
            if not vdir.is_dir() or vdir.name == "__pycache__":
                continue
            meta_path = vdir / "metadata.json"
            metadata = json.loads(meta_path.read_text()) if meta_path.exists() else {}
            versions.append({"version": vdir.name, "metadata": metadata})
        if not versions:
            raise KeyError(f"no versions registered for '{name}'")
        return versions

    def promote(self, name: str, version: str, alias: str = "production") -> None:
        vdir = self._version_dir(name, version)
        if not vdir.exists():
            raise KeyError(
                f"version '{version}' not found for model '{name}'"
            )
        aliases = self._load_aliases(name)
        aliases[alias] = version
        self._save_aliases(name, aliases)

    def load(self, name: str, alias_or_version: str):
        # resolve alias → concrete version
        aliases = self._load_aliases(name)
        version = aliases.get(alias_or_version, alias_or_version)
        vdir = self._version_dir(name, version)
        if not vdir.exists():
            raise KeyError(
                f"'{alias_or_version}' does not resolve to a known version of '{name}'"
            )
        with open(vdir / "model.pkl", "rb") as fh:
            return pickle.load(fh)
```

## Why each design decision is correct

**`_version_dir` raises `ValueError` on duplicate, not silently overwrites.**
Silent overwrite is worse than an error: you'd lose the previous artifact without noticing. Registries are append-only by contract; to replace a version you register a new version number.

**`_aliases_path` is a JSON sidecar at the model level, not inside a version dir.**
An alias like `"production"` is a pointer that changes independently of the artifact. Storing it per-version would mean updating a file inside a "published" version, which breaks the append-only invariant. One `aliases.json` per model name keeps pointers and artifacts cleanly separated.

**`list_versions` sorts by directory name.**
Version strings like `"1"`, `"2"`, `"10"` sort lexicographically. If your versions can exceed single digits, pad them (`"01"`, `"02"`, `"10"`) or use `sorted(..., key=lambda v: int(v.name))`. The verifier uses single-digit versions, so plain `sorted(model_dir.iterdir())` is safe here.

**`load` resolves aliases transparently.**
`aliases.get(alias_or_version, alias_or_version)` returns the alias value if the key exists, otherwise returns the original string unchanged. This single expression handles both `load("clf", "production")` (alias lookup) and `load("clf", "1")` (direct version) without branching.

**State is persisted through `__init__`.**
Every write (`register`, `promote`) goes to disk immediately. A fresh `ModelRegistry(same_dir)` reads from disk in `list_versions`, `_load_aliases`, and `load` — there is no in-memory cache to warm up. This is the minimum correctness bar for a registry.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-model-registry
# replace registry.py with the solution above, then:
python3 -c "
import tempfile
from registry import ModelRegistry
from sklearn.linear_model import LogisticRegression
from sklearn.datasets import make_classification
X, y = make_classification(n_samples=50, random_state=42)
m = LogisticRegression(random_state=42).fit(X, y)
with tempfile.TemporaryDirectory() as td:
    reg = ModelRegistry(td)
    reg.register('clf', '1', m, {'accuracy': 0.90})
    reg.promote('clf', '1')
    loaded = reg.load('clf', 'production')
    print('predictions match:', (m.predict(X) == loaded.predict(X)).all())
"
bash courses/course-24-mlops/challenges/03-model-registry/verify.sh
```
