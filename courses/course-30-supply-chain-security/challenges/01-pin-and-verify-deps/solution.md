# Solution — Pin and Verify Dependencies

## Complete `checker.py`

```python
import hashlib
import re
import os


def find_unpinned(requirements_text: str) -> list:
    unpinned = []
    for line in requirements_text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        # Exact pin: name==version (and nothing else like extras)
        if re.match(r'^[A-Za-z0-9_.-]+==[^\s]+', line):
            continue
        # Everything else — bare name, >=, ~=, !=, no specifier
        name = re.split(r'[>=<!~\s\[]', line)[0].strip()
        if name:
            unpinned.append(name)
    return unpinned


def verify_hashes(lockfile: dict, artifacts_dir: str) -> list:
    tampered = []
    for entry in lockfile.get("packages", []):
        name    = entry["name"]
        version = entry["version"]
        expected_hash = entry["sha256"]
        path = os.path.join(artifacts_dir, f"{name}-{version}.whl")
        try:
            with open(path, "rb") as f:
                actual_hash = hashlib.sha256(f.read()).hexdigest()
        except FileNotFoundError:
            tampered.append(name)
            continue
        if actual_hash != expected_hash:
            tampered.append(name)
    return tampered
```

## Fix `requirements.in`

The lockfile tells you `click` is at version `8.1.7`:

```
# Direct runtime dependencies
requests==2.31.0
flask==3.0.0
click==8.1.7
```

## Why each piece is correct

**`find_unpinned` — regex for exact pin.**  
`re.match(r'^[A-Za-z0-9_.-]+==[^\s]+'` matches any line that starts with a package name followed by `==` and a non-whitespace version. If it matches, the dep is pinned — skip it. Everything else goes into `unpinned`. Splitting on `[>=<!~\s\[]` extracts just the package name from lines like `urllib3>=1.26` or `click[extra]`.

**Why `==` only.** `>=2.31.0` allows pip to resolve 3.0.0 tomorrow. `~=2.31.0` pins the major but allows minor bumps. For a reproducible build, `==` is the only correct specifier.

**`verify_hashes` — read as bytes, compute sha256.**  
Always read in binary mode (`"rb"`) before hashing. Text-mode reads apply platform-specific newline translation and encoding, which changes the bytes and thus the hash. A `FileNotFoundError` is treated as tampered (the file was deleted or renamed — that's also an integrity failure).

**The tamper in the setup.** `setup.sh` writes `pkg-flask-3.0.0` to the flask artifact, records the sha256 of that string in the lockfile, then overwrites the file with `pkg-flask-3.0.0-TAMPERED`. Your `verify_hashes` computes the hash of the new content — it won't match the recorded hash → `["flask"]`.

## Attacker's view

An attacker who compromises an artifact repository replaces a `.whl` with a backdoored version. The lockfile on the developer's machine still holds the pre-compromise hash. `pip install --require-hashes -r requirements.txt` would catch this automatically. Without hash pinning, the attack is invisible.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-pin-and-verify-deps
.venv/bin/pytest tests/ -v
bash courses/course-30-supply-chain-security/challenges/01-pin-and-verify-deps/verify.sh
```
