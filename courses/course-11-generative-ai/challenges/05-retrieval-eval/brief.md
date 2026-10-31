# Retrieval Evaluation

The ML team shipped a RAG system and is about to declare it "production ready." The tech lead's code review has one blocker: *"there is no offline eval. We have a labeled eval set with ground-truth relevant doc IDs for 30 queries. I need recall@3 >= 0.80 before this merges. The current stub always returns the first k docs by index — it's at 0.0."*

This challenge makes that workflow concrete at a small scale: 5 queries, 8 documents, labeled ground-truth, threshold check.

## What recall@k measures

For each query in the eval set you know which document IDs are relevant (ground truth). You run your retriever, take the top-k results, and check whether at least one relevant ID appears in those k results.

```
recall@k = (queries where ≥1 relevant ID is in top-k) / total_queries
```

For a dataset where each query has exactly one relevant document, recall@3 = 1.0 means your retriever always places the correct doc in its top 3. Lower values indicate the retriever is confused by irrelevant documents.

## Why recall@k, not precision or NDCG

- **Recall@k** answers *"did we find the right thing at all?"* — the most important question for RAG, because the LLM can only answer from documents it receives.
- **Precision@k** penalises irrelevant docs in the top k, useful when you're presenting results to a human who skims the list.
- **NDCG** captures ranking quality within the top-k, important when you want the best result first.

For RAG specifically, recall@k is the primary signal: getting the relevant chunk into the context window is necessary; perfect ranking within the top-k is secondary.

## Work directory layout

`setup.sh` plants the following in `~/.kube-dojo-work/05-retrieval-eval/`:

```
corpus.json       # 8 documents on distinct topics
eval_set.json     # 5 {qid, query_emb, relevant_ids} objects
corpus_embs.json  # 8 precomputed 8-dim embeddings (one per document)
retriever.py      # retrieve(query_emb, corpus_embs, k) skeleton — implement this
eval_harness.py   # compute_recall_at_k() helper + __main__ runner (do not edit)
sample_test.py    # two lightweight checks you can run locally
```

## Mission

Implement `retrieve` in `retriever.py`:

```python
def retrieve(query_emb: list, corpus_embs: list, k: int) -> list:
    """
    Return the indices of the top-k corpus embeddings most similar to query_emb.
    Ordered highest-similarity first.
    """
```

The current stub returns `list(range(k))` (always the first k docs by index).
With the provided eval set, that gives recall@3 = 0.0 because the relevant documents are not among the first three.

Your implementation must achieve **recall@3 >= 0.80** on the five labeled queries.

## Target state (what verify.sh checks)

```
recall@3 computed over 5 queries >= 0.80
```

No LLM is required. The embeddings are already precomputed and stored in `corpus_embs.json`.

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-retrieval-eval
python3 -m venv .venv && . .venv/bin/activate
pip install numpy pytest
```

## Run during development

```bash
cd ~/.kube-dojo-work/05-retrieval-eval
python eval_harness.py            # prints recall@3 for your current retriever
.venv/bin/pytest sample_test.py -v
```

## Verify

```bash
bash courses/course-11-generative-ai/challenges/05-retrieval-eval/verify.sh
```
