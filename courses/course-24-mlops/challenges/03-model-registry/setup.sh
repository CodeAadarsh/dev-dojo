#!/usr/bin/env bash
# Plants the "Model Registry" starter into the work directory.
# Idempotent — re-running overwrites registry.py but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-model-registry"
mkdir -p "$WORK"

# ── registry.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/registry.py" << 'PYEOF'
# registry.py — model registry skeleton
# Implement the four methods of ModelRegistry.
# All state must be persisted to disk so a fresh ModelRegistry(root_dir) can
# load what a previous instance saved.
import json
import pickle
from pathlib import Path


class ModelRegistry:
    """
    File-backed model registry.

    Suggested on-disk layout (you may choose any layout that passes the tests):
      <root_dir>/<name>/<version>/model.pkl      — pickled model artifact
      <root_dir>/<name>/<version>/metadata.json  — arbitrary metadata dict
      <root_dir>/<name>/aliases.json             — {"production": "2", ...}
    """

    def __init__(self, root_dir: str):
        self.root = Path(root_dir)
        self.root.mkdir(parents=True, exist_ok=True)

    def register(self, name: str, version: str, model, metadata: dict) -> None:
        """
        Persist model + metadata under name/version.
        Raise ValueError if the (name, version) pair already exists.
        """
        raise NotImplementedError("implement register()")

    def list_versions(self, name: str) -> list:
        """
        Return a list of dicts sorted by version string, each containing at minimum:
          {"version": str, "metadata": dict}
        Raise KeyError if name has no registered versions.
        """
        raise NotImplementedError("implement list_versions()")

    def promote(self, name: str, version: str, alias: str = "production") -> None:
        """
        Assign alias to an existing version of name.
        Raise KeyError if version does not exist under name.
        """
        raise NotImplementedError("implement promote()")

    def load(self, name: str, alias_or_version: str):
        """
        Load and return the model object identified by alias_or_version.
        alias_or_version may be a version string ("1", "2") or an alias ("production").
        Raise KeyError if not found.
        """
        raise NotImplementedError("implement load()")
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the four methods of ModelRegistry in registry.py"
echo "                 so all five verifier checks pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install scikit-learn numpy pytest"
echo
echo "Quick smoke-test while developing:"
echo "  cd $WORK && python3 -c \\"
echo "    'import tempfile, pickle; from registry import ModelRegistry"
echo "     import tempfile; td=tempfile.mkdtemp()"
echo "     r=ModelRegistry(td); r.register(\"m\",\"1\",object(),{\"acc\":0.9})"
echo "     print(r.list_versions(\"m\"))'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-24-mlops/challenges/03-model-registry/verify.sh"
