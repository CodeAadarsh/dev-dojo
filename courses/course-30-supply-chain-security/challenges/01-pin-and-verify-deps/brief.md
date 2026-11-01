# Pin and Verify Dependencies

The security team flagged a PR comment: *"This `requirements.in` has bare package names with no version specifier — reproducible builds are impossible and any future `pip install` could pull a different (compromised) version. Also, CI just alerted that a wheel in our artifact cache doesn't match its recorded hash — someone may have swapped it."*

Two distinct supply-chain risks in one ticket. Fix both.

## Context

`setup.sh` plants a work directory with everything in place:

```
~/.kube-dojo-work/01-pin-and-verify-deps/
├── requirements.in      # three deps; one is not pinned with ==
├── lockfile.json        # sha256 of each dep's expected .whl content
├── artifacts/           # fake .whl files (one has been tampered)
├── checker.py           # your implementation target
└── tests/
    └── test_checker.py  # visible sanity harness; run this to check your progress
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-pin-and-verify-deps
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Open `checker.py` and implement **two functions**:

### 1. `find_unpinned(requirements_text: str) -> list`

Parse `requirements_text` (the file content of a `requirements.in`).  
Return the package names of every dep that is **not** pinned with an exact `==version` specifier.  
Ignore blank lines and comment lines (`#`).

> Exact pinning (`==`) is the only specifier that guarantees reproducibility. `>=`, `~=`, and bare names all leave the resolved version up to the resolver at install time.

### 2. `verify_hashes(lockfile: dict, artifacts_dir: str) -> list`

`lockfile` has the shape `{"packages": [{"name": ..., "version": ..., "sha256": ...}, ...]}`.  
`artifacts_dir` contains files named `<name>-<version>.whl`.  
For each entry, read the file, compute its sha256, and compare to the lockfile record.  
Return the package names where the hash does **not** match (tampered artifacts).

### 3. Pin the offender

After `find_unpinned` tells you which dep is bare, edit `requirements.in` and add the correct `==version` pin.  
The lockfile tells you the version to use.

## What the verifier checks

| Check | What it tests |
|-------|---------------|
| `find_unpinned` unit tests | detects bare names and range specifiers as unpinned; ignores `==` pins; ignores comments |
| `verify_hashes` unit tests | detects a file whose sha256 doesn't match the lockfile; passes on clean artifacts |
| `requirements.in` state | no unpinned deps remain in your work copy |

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/01-pin-and-verify-deps/verify.sh
```

## Real-world tool

In production you use `pip-compile` (pip-tools) to compile `requirements.in` → `requirements.txt` with exact pins, and `pip install --require-hashes -r requirements.txt` to enforce hash verification on every install. This challenge implements the same two checks by hand so you understand what the tools are actually doing.
