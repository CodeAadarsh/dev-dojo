#!/usr/bin/env bash
# Plants the "RBAC + ABAC Policy Engine" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-rbac-abac"
mkdir -p "$WORK/tests"

# ── policy.py skeleton ────────────────────────────────────────────────────────
cat > "$WORK/policy.py" << 'PYEOF'
# policy.py — implement a combined RBAC + ABAC authorize() function.
# The data model is pre-populated; only authorize() needs to be written.

ROLES = {
    "admin":    {"read", "write", "delete", "edit"},
    "editor":   {"read", "write", "edit"},
    "viewer":   {"read"},
    "owner":    {"read", "edit"},   # only on own resources (ABAC gate applies)
}

USERS = {
    "alice":   {"role": "admin"},
    "bob":     {"role": "editor"},
    "carol":   {"role": "viewer"},
    "dave":    {"role": "owner"},
    "eve":     {"role": "owner"},
}

RESOURCES = {
    "order:1":  {"owner": "dave"},
    "order:2":  {"owner": "eve"},
    "report:1": {"owner": "alice"},
}


def authorize(user: str, action: str, resource: str) -> bool:
    """
    Return True if user is permitted to perform action on resource.

    Evaluation order:
    1. Unknown user or resource -> False.
    2. RBAC: user's role must include action in its permission set.
    3. ABAC ownership gate (only for the 'owner' role + action == 'edit'):
       user must be the resource's owner attribute.
    4. All checks pass -> True.
    """
    raise NotImplementedError("implement authorize()")
PYEOF

# ── tests/test_policy_sample.py (visible sample) ─────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_policy_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from policy import authorize


def test_admin_read_allowed():
    assert authorize("alice", "read", "order:1") is True


def test_viewer_write_denied():
    assert authorize("carol", "write", "order:1") is False


def test_owner_edit_own_resource():
    assert authorize("dave", "edit", "order:1") is True


def test_owner_edit_other_resource_denied():
    # IDOR attempt: dave cannot edit order:2 (owned by eve)
    assert authorize("dave", "edit", "order:2") is False
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement authorize() in policy.py"
echo "                 so the full hidden pytest suite passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-16-security-auth/challenges/05-rbac-abac/verify.sh"
