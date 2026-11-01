# Solution — Prompt Registry

## The complete implementation

```python
# registry.py
from typing import List, Dict, Any


class PromptTemplate:
    def __init__(self, name: str, version: int, template: str) -> None:
        self.name = name
        self.version = version
        self.template = template

    def render(self, **kwargs: Any) -> str:
        return self.template.format(**kwargs)


class PromptRegistry:
    def __init__(self) -> None:
        self._store: Dict[str, Dict[int, PromptTemplate]] = {}
        self._production: Dict[str, int] = {}
        self._provenance: Dict[str, List[Dict[str, Any]]] = {}

    def register(self, name: str, version: int, template: str) -> PromptTemplate:
        t = PromptTemplate(name, version, template)
        self._store.setdefault(name, {})[version] = t
        return t

    def get(self, name: str, version: int) -> PromptTemplate:
        if name not in self._store or version not in self._store[name]:
            raise KeyError(f"{name}@v{version} not registered")
        return self._store[name][version]

    def promote(self, name: str, version: int) -> None:
        if name not in self._store or version not in self._store[name]:
            raise KeyError(f"{name}@v{version} not registered")
        self._production[name] = version

    def get_production(self, name: str) -> PromptTemplate:
        if name not in self._production:
            raise KeyError(f"no production version set for {name!r}")
        return self._store[name][self._production[name]]

    def record_usage(self, name: str, version: int, output: str) -> None:
        self._provenance.setdefault(name, []).append(
            {"version": version, "output": output}
        )

    def get_provenance(self, name: str) -> List[Dict[str, Any]]:
        return self._provenance.get(name, [])
```

## Why each piece works

**`render`** delegates to `str.format(**kwargs)`. This is intentionally simple — in production you'd use Jinja2 for conditionals and loops, but `str.format` is enough for parameterised templates and has zero dependencies.

**`_store` as nested dict** (`name → version → template`) gives O(1) lookup by both axes. An alternative is a flat dict keyed by `(name, version)` tuples — equally valid, slightly less readable.

**`setdefault` on register** avoids a `if name not in self._store: self._store[name] = {}` guard, keeping registration a two-liner. Same pattern for `_provenance`.

**`promote` validates before writing** — if you promote a version that was never registered you'd silently store a dangling pointer and `get_production` would crash on the inner lookup. The guard surfaces the bug at the call site instead.

**`get_provenance` returns `[]` for unknown names** — a read-only query that raises on a missing name would be surprising; returning an empty list follows the principle of least astonishment for "has this name ever been used?"

## The ops angle

This implementation is purely in-memory. A production registry would persist to a database and add:

- **Immutability** — registered versions are never mutated; you only add new ones
- **Atomic promotion** — CAS or a distributed lock so two writers can't promote simultaneously
- **Diffs** — store a hash of `template` to detect accidental collisions between versions
- **Rollback** — `demote(name)` snaps production back to the previous version (maintain a stack)
