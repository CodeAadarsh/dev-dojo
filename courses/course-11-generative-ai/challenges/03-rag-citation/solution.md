# Solution — RAG Citation

The flag is in the "Blameless Post-Incident Review" section. Any retrieval approach that scores semantic or lexical proximity correctly will surface it — below is a complete TF-IDF implementation that requires no external libraries.

## Full solution

```python
# solution.py
import math
import re


def chunk_text(text: str, max_words: int = 120, overlap: int = 20) -> list:
    # Paragraph-level split: double newline is a reliable boundary in this KB.
    # Filter empty paragraphs and short noise lines.
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks = [p for p in paragraphs if len(p.split()) > 8]
    return chunks


def _tokenise(text: str) -> list:
    return re.findall(r'[a-z]+', text.lower())


def _tf(tokens: list) -> dict:
    counts = {}
    for t in tokens:
        counts[t] = counts.get(t, 0) + 1
    total = len(tokens) or 1
    return {t: c / total for t, c in counts.items()}


def _idf(term: str, chunks: list) -> float:
    df = sum(1 for c in chunks if term in re.findall(r'[a-z]+', c.lower()))
    return math.log((len(chunks) + 1) / (df + 1)) + 1.0


def retrieve(question: str, chunks: list) -> str:
    q_tokens = _tokenise(question)
    q_terms = set(q_tokens)

    # build IDF for query terms only (enough for scoring)
    idf = {t: _idf(t, chunks) for t in q_terms}

    best_score = -1.0
    best_chunk = chunks[0]

    for chunk in chunks:
        chunk_tokens = _tokenise(chunk)
        chunk_tf = _tf(chunk_tokens)
        # score = sum of TF-IDF weights for query terms found in chunk
        score = sum(chunk_tf.get(t, 0.0) * idf[t] for t in q_terms)
        if score > best_score:
            best_score = score
            best_chunk = chunk

    return best_chunk


if __name__ == "__main__":
    with open("knowledge_base.txt") as f:
        text = f.read()

    chunks = chunk_text(text)
    print(f"Chunked into {len(chunks)} segments.")

    question = "What are the five sections of an effective blameless post-incident review?"
    top_chunk = retrieve(question, chunks)

    print("\n--- Top chunk ---")
    print(top_chunk)

    match = re.search(r'FLAG=(KUBE\{[^}]+\})', top_chunk)
    if match:
        print("\nFlag found:", match.group(1))
    else:
        print("\nFlag not found in top chunk — retrieval returned the wrong passage.")
```

## Why this works

**Paragraph chunking** is the right boundary for this knowledge base: each section under a `##` heading is a self-contained topic. A chunk that mixes two sections would dilute the signal and hurt retrieval accuracy. For a real wiki, sentence-level chunking with overlap is safer — paragraphs vary widely in length and some are very long.

**TF-IDF scoring** measures how much a query term matters in a given chunk (TF = term frequency in the chunk) adjusted by how rare it is across the corpus (IDF = inverse document frequency). Terms like "postmortem", "blameless", and "five sections" are rare in the overall knowledge base but abundant in the target chunk — exactly the signal TF-IDF is designed to amplify.

**Why query terms only for IDF**: computing IDF for the entire vocabulary is correct but expensive at scale. For retrieval scoring, only the query terms contribute to the final score, so computing IDF only for those terms is exact and fast.

## Alternative approaches

- **Keyword overlap (Jaccard similarity)**: `|query_terms ∩ chunk_terms| / |query_terms ∪ chunk_terms|`. Simpler, slightly less accurate but still correct for this KB.
- **BM25** (the standard in production search): a refined TF-IDF that saturates term frequency (a term appearing 100 times isn't 100× more relevant than one appearing once) and normalises for document length. The `rank_bm25` package implements it in pure Python.
- **Dense retrieval via embeddings**: use `sentence-transformers` or `ollama` to embed both query and chunks, then use cosine similarity (as in challenge 02). More accurate for paraphrase and synonym matching; overkill for this challenge.

## Debugging retrieval

The most useful debugging step when retrieval returns the wrong chunk:

```python
# Print all chunks with their scores
for i, chunk in enumerate(chunks):
    chunk_tokens = _tokenise(chunk)
    chunk_tf = _tf(chunk_tokens)
    score = sum(chunk_tf.get(t, 0.0) * idf[t] for t in q_terms)
    print(f"[{score:.4f}] chunk {i}: {chunk[:80]!r}")
```

If the right chunk scores lower than expected, the signal words from the query are probably not present verbatim — in that case, upgrade to BM25 or embeddings.
