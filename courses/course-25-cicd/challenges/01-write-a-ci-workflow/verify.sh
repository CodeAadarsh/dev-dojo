#!/usr/bin/env bash
# Verifier for "Write a CI Workflow".
# Parses .github/workflows/ci.yml with python3+pyyaml and asserts required
# structure. Prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-write-a-ci-workflow"
FLAG='KUBE{ci_workflow_triggers_gated}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"

WF="$WORK/.github/workflows/ci.yml"
[ -f "$WF" ] || fail "workflow file not found at .github/workflows/ci.yml — create it inside $WORK"

python3 - "$WF" << 'PYEOF'
import yaml, sys

path = sys.argv[1]
try:
    with open(path) as f:
        d = yaml.safe_load(f)
except Exception as e:
    print(f"✗ YAML parse error: {e}")
    sys.exit(1)

if not isinstance(d, dict):
    print("✗ workflow is not a YAML mapping at the top level")
    sys.exit(1)

# 'on' is parsed as boolean True by PyYAML (YAML 1.1)
on_val = d.get(True) or d.get('on') or {}
if isinstance(on_val, str):
    on_val = {on_val: None}
elif isinstance(on_val, list):
    on_val = {k: None for k in on_val}

if 'push' not in on_val:
    print("✗ 'on:' must include a 'push' trigger")
    sys.exit(1)

if 'pull_request' not in on_val:
    print("✗ 'on:' must include a 'pull_request' trigger")
    sys.exit(1)

jobs = d.get('jobs') or {}
if not jobs:
    print("✗ workflow has no jobs")
    sys.exit(1)

all_steps = []
for job_name, job in jobs.items():
    if isinstance(job, dict):
        all_steps.extend(job.get('steps') or [])

if len(all_steps) < 4:
    print(f"✗ job must have at least 4 steps (found {len(all_steps)}); need checkout, setup, lint, test")
    sys.exit(1)

def step_uses(s):
    return (s.get('uses') or '')

def step_name(s):
    return (s.get('name') or '').lower()

def step_run(s):
    return (s.get('run') or '').lower()

has_checkout = any('actions/checkout' in step_uses(s) for s in all_steps)
if not has_checkout:
    print("✗ no checkout step found — add a step with 'uses: actions/checkout@v4'")
    sys.exit(1)

has_setup = any(
    step_uses(s).startswith('actions/setup-') or 'setup' in step_name(s)
    for s in all_steps
)
if not has_setup:
    print("✗ no setup step found — add 'actions/setup-python@v5' or a step named 'setup *'")
    sys.exit(1)

has_lint = any(
    'lint' in step_name(s) or
    any(tool in step_run(s) for tool in ['ruff', 'flake8', 'pylint', 'black --check'])
    for s in all_steps
)
if not has_lint:
    print("✗ no lint step found — add a step named 'Lint' or running ruff/flake8/pylint")
    sys.exit(1)

has_test = any(
    'test' in step_name(s) or 'pytest' in step_run(s)
    for s in all_steps
)
if not has_test:
    print("✗ no test step found — add a step named 'Test' or running pytest")
    sys.exit(1)

print("ok: triggers, jobs, and steps all verified")
PYEOF

PARSE_EXIT=$?
[ "$PARSE_EXIT" -eq 0 ] || fail "workflow structure check failed — see errors above"

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
