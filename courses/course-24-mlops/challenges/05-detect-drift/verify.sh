#!/usr/bin/env bash
# Verifier for "Detect Drift".
# Runs a hidden pytest harness; prints the flag only when all checks pass.
set -uo pipefail

SLUG="05-detect-drift"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{drift_detected_psi_threshold}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]               || fail "work directory missing — run setup.sh first"
[ -f "$WORK/drift.py" ]      || fail "drift.py not found — run setup.sh first"
[ -f "$WORK/reference.npy" ] || fail "reference.npy not found — run setup.sh first"
[ -f "$WORK/drifted.npy" ]   || fail "drifted.npy not found — run setup.sh first"
[ -f "$WORK/no_drift.npy" ]  || fail "no_drift.npy not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYTHON="$WORK/.venv/bin/python3"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYTHON="python3"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install scikit-learn pytest numpy scipy pandas"
fi

TMPDIR_HARNESS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HARNESS"' EXIT

cat > "$TMPDIR_HARNESS/test_verify.py" << 'PYEOF'
# Hidden verifier harness — do not distribute.
import sys, os
sys.path.insert(0, os.environ["WORK"])

import numpy as np
from drift import detect

WORK = os.environ["WORK"]
reference = np.load(os.path.join(WORK, "reference.npy"))
no_drift  = np.load(os.path.join(WORK, "no_drift.npy"))
drifted   = np.load(os.path.join(WORK, "drifted.npy"))

# Compute reference PSI scores using the canonical implementation.
# The learner must produce values within 15% of these.
def _ref_psi(ref, cur, bins=10):
    n_features = ref.shape[1]
    total = 0.0
    for i in range(n_features):
        lo  = min(ref[:, i].min(), cur[:, i].min())
        hi  = max(ref[:, i].max(), cur[:, i].max())
        edges = np.linspace(lo, hi, bins + 1)
        p_ref = np.histogram(ref[:, i], bins=edges)[0] / len(ref)
        p_cur = np.histogram(cur[:, i], bins=edges)[0] / len(cur)
        # avoid log(0)
        p_ref = np.where(p_ref == 0, 1e-6, p_ref)
        p_cur = np.where(p_cur == 0, 1e-6, p_cur)
        total += float(np.sum((p_cur - p_ref) * np.log(p_cur / p_ref)))
    return total

# reference KS scores
def _ref_ks(ref, cur):
    from scipy.stats import ks_2samp
    return max(ks_2samp(ref[:, i], cur[:, i]).statistic for i in range(ref.shape[1]))

REF_PSI_NODRIFT  = _ref_psi(reference, no_drift)
REF_PSI_DRIFTED  = _ref_psi(reference, drifted)
REF_KS_NODRIFT   = _ref_ks(reference, no_drift)
REF_KS_DRIFTED   = _ref_ks(reference, drifted)


def _result_nd():
    return detect(reference, no_drift, threshold=0.2)


def _result_d():
    return detect(reference, drifted, threshold=0.2)


def test_returns_dict_shape():
    r = _result_nd()
    assert isinstance(r, dict), "detect() must return a dict"
    assert "score" in r and "drift" in r, "dict must have 'score' and 'drift' keys"
    assert isinstance(r["score"], float), "'score' must be a float"
    assert isinstance(r["drift"], bool),  "'drift' must be a bool"


def test_no_drift_flagged_false():
    r = _result_nd()
    assert r["drift"] is False, \
        f"stable traffic must not trigger drift (score={r['score']:.4f})"


def test_drifted_flagged_true():
    r = _result_d()
    assert r["drift"] is True, \
        f"shifted traffic must trigger drift (score={r['score']:.4f})"


def test_no_drift_score_accuracy():
    r = _result_nd()
    score = r["score"]
    # accept if close to PSI reference OR close to KS reference
    psi_ok = abs(score - REF_PSI_NODRIFT) / max(abs(REF_PSI_NODRIFT), 1e-6) < 0.15
    ks_ok  = abs(score - REF_KS_NODRIFT)  / max(abs(REF_KS_NODRIFT),  1e-6) < 0.15
    assert psi_ok or ks_ok, \
        (f"no-drift score {score:.4f} is not within 15% of PSI reference "
         f"({REF_PSI_NODRIFT:.4f}) or KS reference ({REF_KS_NODRIFT:.4f})")


def test_drifted_score_accuracy():
    r = _result_d()
    score = r["score"]
    psi_ok = abs(score - REF_PSI_DRIFTED) / max(abs(REF_PSI_DRIFTED), 1e-6) < 0.15
    ks_ok  = abs(score - REF_KS_DRIFTED)  / max(abs(REF_KS_DRIFTED),  1e-6) < 0.15
    assert psi_ok or ks_ok, \
        (f"drifted score {score:.4f} is not within 15% of PSI reference "
         f"({REF_PSI_DRIFTED:.4f}) or KS reference ({REF_KS_DRIFTED:.4f})")


def test_threshold_respected():
    # If we raise the threshold above the drifted score, drift should be False.
    r_high = detect(reference, drifted, threshold=999.0)
    assert r_high["drift"] is False, \
        "with threshold=999 even drifted sample must return drift=False"
PYEOF

export WORK="$WORK"
if $PYTEST "$TMPDIR_HARNESS/test_verify.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "verifier has failures — fix your implementation and retry"
fi
