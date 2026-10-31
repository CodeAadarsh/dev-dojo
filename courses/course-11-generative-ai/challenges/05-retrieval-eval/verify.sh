#!/usr/bin/env bash
# Verifier for "Retrieval Evaluation".
# Runs a hidden pytest that computes recall@3 and asserts >= 0.80.
set -uo pipefail

SLUG="05-retrieval-eval"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{recall_at_k_measures_retrieval_quality}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                      || fail "work dir $WORK missing — run setup.sh first"
[ -f "$WORK/retriever.py" ]         || fail "retriever.py not found in $WORK"
[ -f "$WORK/eval_harness.py" ]      || fail "eval_harness.py missing — run setup.sh first"
[ -f "$WORK/corpus_embs.json" ]     || fail "corpus_embs.json missing — run setup.sh first"
[ -f "$WORK/eval_set.json" ]        || fail "eval_set.json missing — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — run: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install numpy pytest"
fi

TMPDIR_SUITE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_hidden.py" << 'PYEOF'
"""Hidden verifier suite — do not edit."""
import sys
import os

WORK = os.path.expanduser("~/.kube-dojo-work/05-retrieval-eval")
sys.path.insert(0, WORK)

import json
import pytest
from retriever import retrieve
from eval_harness import compute_recall_at_k


@pytest.fixture(scope="module")
def fixtures():
    with open(os.path.join(WORK, "corpus_embs.json")) as f:
        corpus_embs = json.load(f)
    with open(os.path.join(WORK, "eval_set.json")) as f:
        eval_set = json.load(f)
    return corpus_embs, eval_set


def test_retrieve_returns_exactly_k_results(fixtures):
    corpus_embs, eval_set = fixtures
    result = retrieve(eval_set[0]["query_emb"], corpus_embs, k=3)
    assert len(result) == 3, \
        f"retrieve must return exactly k=3 indices, got {len(result)}"


def test_retrieve_indices_are_in_range(fixtures):
    corpus_embs, eval_set = fixtures
    n = len(corpus_embs)
    for item in eval_set:
        result = retrieve(item["query_emb"], corpus_embs, k=3)
        for idx in result:
            assert 0 <= idx < n, \
                f"index {idx} out of range [0, {n}) for qid {item['qid']}"


def test_recall_at_3_meets_threshold(fixtures):
    corpus_embs, eval_set = fixtures
    recall = compute_recall_at_k(retrieve, corpus_embs, eval_set, k=3)
    assert recall >= 0.80, (
        f"recall@3 = {recall:.2f} ({int(recall * len(eval_set))}/{len(eval_set)}), "
        "need >= 0.80. Hint: are you using cosine similarity rather than dot product?"
    )


def test_recall_at_1_sanity(fixtures):
    """A correct cosine implementation should score >= 0.60 at k=1 on this set."""
    corpus_embs, eval_set = fixtures
    recall = compute_recall_at_k(retrieve, corpus_embs, eval_set, k=1)
    assert recall >= 0.60, (
        f"recall@1 = {recall:.2f}, expected >= 0.60. "
        "The similarity scores may be wrong — check your cosine formula."
    )
PYEOF

cd "$WORK"
"$PYTEST" "$TMPDIR_SUITE/test_hidden.py" -v --tb=short \
    || fail "one or more checks failed — run 'python eval_harness.py' to see your current recall scores"

echo
echo "All retrieval eval checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
