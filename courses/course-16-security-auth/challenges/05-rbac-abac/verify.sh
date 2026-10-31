#!/usr/bin/env bash
# Verifier for "RBAC + ABAC Policy Engine".
# Runs the hidden pytest suite; prints the flag only when every check passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-rbac-abac"
FLAG='KUBE{rbac_abac_defense_in_depth}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/policy.py" ] || fail "policy.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# ── hidden test suite written inline ─────────────────────────────────────────
HIDDEN_TESTS=$(cat << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from policy import authorize


# ── RBAC: admin ──────────────────────────────────────────────────────────────

def test_admin_read_allowed():
    assert authorize("alice", "read", "order:1") is True

def test_admin_delete_allowed():
    assert authorize("alice", "delete", "order:1") is True

def test_admin_edit_others_resource_allowed():
    # admin bypasses ownership gate — full trust
    assert authorize("alice", "edit", "order:1") is True

def test_admin_edit_own_resource_allowed():
    assert authorize("alice", "edit", "report:1") is True


# ── RBAC: editor ─────────────────────────────────────────────────────────────

def test_editor_write_allowed():
    assert authorize("bob", "write", "order:1") is True

def test_editor_edit_allowed_any_resource():
    # editors are not subject to the ownership ABAC gate
    assert authorize("bob", "edit", "order:1") is True

def test_editor_edit_other_owner_resource():
    assert authorize("bob", "edit", "report:1") is True

def test_editor_delete_denied():
    assert authorize("bob", "delete", "order:1") is False


# ── RBAC: viewer ─────────────────────────────────────────────────────────────

def test_viewer_read_allowed():
    assert authorize("carol", "read", "report:1") is True

def test_viewer_write_denied():
    assert authorize("carol", "write", "order:1") is False

def test_viewer_delete_denied():
    assert authorize("carol", "delete", "order:1") is False

def test_viewer_edit_denied():
    assert authorize("carol", "edit", "order:1") is False


# ── ABAC: owner role ─────────────────────────────────────────────────────────

def test_owner_read_own():
    assert authorize("dave", "read", "order:1") is True

def test_owner_edit_own():
    assert authorize("dave", "edit", "order:1") is True

def test_owner_edit_other_denied():
    # IDOR: dave cannot edit order:2 owned by eve
    assert authorize("dave", "edit", "order:2") is False

def test_owner_read_other_denied():
    # owner role does NOT have cross-user read either
    assert authorize("dave", "read", "order:2") is False

def test_eve_edit_own():
    assert authorize("eve", "edit", "order:2") is True

def test_eve_edit_dave_order_denied():
    assert authorize("eve", "edit", "order:1") is False


# ── unknown user / resource ──────────────────────────────────────────────────

def test_unknown_user_denied():
    assert authorize("mallory", "read", "order:1") is False

def test_unknown_resource_denied():
    assert authorize("dave", "read", "order:999") is False

def test_unknown_user_and_resource_denied():
    assert authorize("ghost", "write", "nonexistent") is False
PYEOF
)

HIDDEN_FILE="$WORK/tests/_hidden_policy_suite.py"
printf '%s\n' "$HIDDEN_TESTS" > "$HIDDEN_FILE"

if $PYTEST "$HIDDEN_FILE" -q 2>&1; then
    rm -f "$HIDDEN_FILE"
    echo
    echo "All policy engine tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -f "$HIDDEN_FILE"
    fail "test suite has failures — fix your authorize() and retry"
fi
