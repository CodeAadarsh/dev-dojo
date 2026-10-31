# Retrieval-Augmented Generation

> **Module 03 · Course 11** — A language model's knowledge is frozen at training time. RAG unfreezes it: instead of asking the model to remember, you retrieve the relevant facts at query time and inject them into the context. The model's job is then synthesis — not memory. That distinction determines every architectural decision in this module, and every failure mode.

You have the pieces from the previous two modules: generation (Module 01) and vector search (Module 02). This module connects them into a production-quality pipeline and then systematically breaks it — because RAG fails in non-obvious ways that look like model quality issues but are almost always retrieval or context-assembly bugs.

Install the working dependencies:

```bash
pip install ollama httpx chromadb tiktoken rank-bm25 sentence-transformers pydantic
ollama pull llama3.2
ollama pull nomic-embed-text
```

---

## The RAG loop

The pattern in one diagram:

```
User query
    │
    ▼
┌─────────────────┐
│   Embed query   │  nomic-embed-text → 768-dim vector
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Retrieve     │  ANN search → top-k candidate chunks
│  (vector + BM25)│  + optional BM25 keyword pass
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Rerank       │  cross-encoder scores (query, chunk) pairs
│   (optional)    │  → smaller, higher-precision set
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Assemble context│  fit chunks into token budget; order matters
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Generate      │  llama3.2 — answer + cite sources
└─────────────────┘
```

Each stage is independently tunable and independently breakable. That independence is the point: when the final answer is wrong, you can bisect — wrong retrieval? wrong reranking? wrong generation with correct context? Each stage has its own eval signal.

---

## Chunking strategies

The chunk is the unit of retrieval. A chunk that is too short loses context; one that is too long dilutes the semantic signal (the embedding averages across many unrelated sentences) and eats your token budget.

### Fixed-size character chunking

Simplest. Good baseline for homogeneous prose. Overlapping windows prevent a sentence from being split at a chunk boundary:

```python
def chunk_fixed(text: str, size: int = 512, overlap: int = 64) -> list[str]:
    chunks, start = [], 0
    while start < len(text):
        chunk = text[start : start + size].strip()
        if chunk:
            chunks.append(chunk)
        start += size - overlap
    return chunks
```

### Recursive character splitting

Tries to split on paragraph breaks first, then sentences, then words, then characters — only falling back when a chunk is still too large. This preserves semantic units better than fixed-size splitting:

```python
def chunk_recursive(
    text: str,
    chunk_size: int = 512,
    overlap: int = 64,
    separators: list[str] | None = None,
) -> list[str]:
    separators = separators or ["\n\n", "\n", ". ", " ", ""]
    chunks: list[str] = []

    def split(segment: str, sep_idx: int = 0) -> None:
        if len(segment) <= chunk_size:
            s = segment.strip()
            if s:
                chunks.append(s)
            return
        sep = separators[sep_idx] if sep_idx < len(separators) else ""
        parts = segment.split(sep) if sep else list(segment)

        current = ""
        for part in parts:
            candidate = (current + sep + part) if current else part
            if len(candidate) <= chunk_size:
                current = candidate
            else:
                if current.strip():
                    chunks.append(current.strip())
                    # carry overlap from the end of the previous chunk
                    tail = current[-overlap:] if overlap and len(current) > overlap else ""
                    current = (tail + sep + part).strip() if tail else part.strip()
                else:
                    split(part, sep_idx + 1)
                    current = ""
        if current.strip():
            chunks.append(current.strip())

    split(text)
    return chunks
```

### Sentence-window chunking

Embed a single sentence for high-precision retrieval, but return the surrounding window (±2 sentences) to the LLM for context:

```python
import re

def sentence_chunks(text: str, window: int = 3) -> list[dict]:
    """Each chunk: one sentence for embedding, window sentences for context."""
    sentences = [s.strip() for s in re.split(r'(?<=[.!?])\s+', text) if s.strip()]
    result = []
    for i, sent in enumerate(sentences):
        start = max(0, i - window // 2)
        end = min(len(sentences), i + window // 2 + 1)
        result.append({
            "embed_text": sent,
            "context_text": " ".join(sentences[start:end]),
        })
    return result
```

### Choosing chunk size

```
Chunk size   | Embedding precision | Context richness | Token budget use
─────────────|─────────────────────|──────────────────|─────────────────
128 chars    | High (focused)      | Low (fragments)  | Cheap
512 chars    | Good (default)      | Medium           | Moderate
1024 chars   | Moderate (diluted)  | High             | Expensive
```

Rule of thumb: **512 chars / 100 tokens is a safe default**; tune by measuring retrieval recall on a sample of real user queries. Overlap of 10–15% prevents sentences at chunk boundaries from being missed.

---

## Retrieval and reranking

### Dense retrieval (vector search)

The approach from Module 02. Handles paraphrase and semantic variants well. Misses exact keyword matches when the model hasn't learned the exact term (rare product IDs, code tokens, error codes).

```python
import ollama, chromadb

ollama_client = ollama.Client()
chroma_client = chromadb.PersistentClient(path=".chroma")
collection = chroma_client.get_collection("knowledge")

def dense_retrieve(query: str, n: int = 10) -> list[dict]:
    q_vec = ollama_client.embeddings(model="nomic-embed-text", prompt=query).embedding
    results = collection.query(
        query_embeddings=[q_vec],
        n_results=n,
        include=["documents", "metadatas", "distances"],
    )
    return [
        {
            "text": doc,
            "source": meta.get("source", ""),
            "score": round(1 - dist, 4),
        }
        for doc, meta, dist in zip(
            results["documents"][0],
            results["metadatas"][0],
            results["distances"][0],
        )
    ]
```

### BM25 (sparse retrieval)

BM25 is keyword-frequency-based — it catches exact matches that dense retrieval misses. Especially useful for code snippets, error codes, UUIDs, and technical terms.

```python
from rank_bm25 import BM25Okapi

class BM25Index:
    def __init__(self, documents: list[str], ids: list[str]):
        tokenized = [doc.lower().split() for doc in documents]
        self.bm25 = BM25Okapi(tokenized)
        self.documents = documents
        self.ids = ids

    def search(self, query: str, n: int = 10) -> list[dict]:
        scores = self.bm25.get_scores(query.lower().split())
        top_indices = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)[:n]
        return [
            {"text": self.documents[i], "id": self.ids[i], "score": float(scores[i])}
            for i in top_indices
            if scores[i] > 0
        ]
```

### Hybrid retrieval with RRF

Combine dense + sparse results using **Reciprocal Rank Fusion** — no score normalization needed because it uses only the rank position:

```python
def rrf_fuse(
    result_sets: list[list[dict]],
    id_key: str = "text",
    k: int = 60,
) -> list[dict]:
    """Reciprocal Rank Fusion over multiple ranked lists."""
    scores: dict[str, float] = {}
    by_id: dict[str, dict] = {}

    for results in result_sets:
        for rank, doc in enumerate(results):
            uid = doc[id_key]
            scores[uid] = scores.get(uid, 0) + 1 / (k + rank + 1)
            by_id[uid] = doc

    ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return [by_id[uid] for uid, _ in ranked]
```

### Cross-encoder reranking

A **bi-encoder** (what you use for dense retrieval) encodes query and document independently — fast, but semantic signal is coarse. A **cross-encoder** sees the (query, document) pair together — slow, but produces precise relevance scores. Use it to rescore the top-20 candidates down to the top-5 you'll actually send to the LLM:

```python
# pip install sentence-transformers
# This runs locally — no API key needed
from sentence_transformers import CrossEncoder

_reranker: CrossEncoder | None = None

def get_reranker() -> CrossEncoder:
    global _reranker
    if _reranker is None:
        # Small model — ~80 MB, runs on CPU in ~50 ms per batch
        _reranker = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")
    return _reranker

def rerank(query: str, chunks: list[dict], top_n: int = 5) -> list[dict]:
    reranker = get_reranker()
    pairs = [(query, chunk["text"]) for chunk in chunks]
    scores = reranker.predict(pairs)
    ranked = sorted(zip(scores, chunks), key=lambda x: x[0], reverse=True)
    return [chunk for _, chunk in ranked[:top_n]]
```

**Retrieval budget:** retrieve 20 candidates via hybrid search → rerank to top 5 → send 5 to LLM. The cross-encoder step costs ~50–100 ms on CPU for 20 pairs, which is cheap relative to LLM generation time.

---

## Context assembly and token budget

### Token budget management

The LLM has a fixed context window. Your context assembly step must fit within it without truncating mid-sentence:

```python
import tiktoken

enc = tiktoken.get_encoding("cl100k_base")

def assemble_context(
    chunks: list[dict],
    max_context_tokens: int = 2000,
) -> tuple[str, list[str]]:
    """
    Returns (assembled_context_string, list_of_source_names).
    Stops adding chunks once the token budget is spent.
    """
    parts: list[str] = []
    sources: list[str] = []
    used = 0

    for chunk in chunks:
        text = f"[Source: {chunk['source']}]\n{chunk['text']}"
        tokens = len(enc.encode(text))
        if used + tokens > max_context_tokens:
            break
        parts.append(text)
        if chunk["source"] not in sources:
            sources.append(chunk["source"])
        used += tokens

    return "\n\n---\n\n".join(parts), sources
```

### Chunk ordering — the lost-in-the-middle problem

Research (and practical experience) shows that LLMs have **position bias**: they attend most strongly to tokens near the beginning and end of the context, and under-attend to tokens in the middle. When your most relevant chunk lands in the middle of a long context window, the answer quality drops.

Three orderings to consider:

```
Strategy              | Order                        | When to use
──────────────────────|──────────────────────────────|─────────────────────
Descending score      | highest score first           | Naive default — loses middle chunks
Sandwich              | best → rest → second-best     | Multi-hop questions
Chronological         | document order within source  | Narrative or sequential documents
```

Sandwich ordering (works best for synthesis tasks):

```python
def sandwich_order(chunks: list[dict]) -> list[dict]:
    """
    Place the most relevant chunk first, second most relevant last,
    rest in the middle. Mitigates lost-in-the-middle attention bias.
    """
    if len(chunks) <= 2:
        return chunks
    best = chunks[0]
    second = chunks[-1]
    middle = chunks[1:-1]
    return [best] + middle + [second]
```

---

## Citations

Surface citations to the user so they can verify the answer. Two patterns:

**Source-list citations** (simple):

```python
def build_prompt(query: str, context: str, sources: list[str]) -> str:
    return (
        f"Answer the question using ONLY the following context. "
        f"If the answer is not in the context, say: \"I don't have enough context.\"\n\n"
        f"Context:\n\n{context}\n\n"
        f"Question: {query}"
    )
```

After generation, append the source list to the response:

```python
result = {
    "answer": generated_text,
    "sources": sources,  # ["runbook.md", "incident-2024-03.md"]
}
```

**Inline citations** (more precise — tell the model to cite):

```python
SYSTEM = """Answer the question using ONLY the provided context.
Cite your sources inline using [Source: filename] tags.
If the answer is not in the context, say "I don't have enough context."
Do not invent facts."""
```

The model will produce: `The pod was evicted due to node memory pressure [Source: runbook.md].`

Parse sources from the answer:

```python
import re

def extract_cited_sources(answer: str) -> list[str]:
    return list(set(re.findall(r'\[Source: ([^\]]+)\]', answer)))
```

---

## Full pipeline

```python
import ollama
import chromadb
from pathlib import Path

EMBED_MODEL = "nomic-embed-text"
GEN_MODEL = "llama3.2"

ollama_client = ollama.Client()
chroma_client = chromadb.PersistentClient(path=".chroma")
collection = chroma_client.get_or_create_collection(
    "knowledge", metadata={"hnsw:space": "cosine"}
)

SYSTEM = (
    "Answer using ONLY the provided context. "
    "Cite sources inline as [Source: filename]. "
    "If the context is insufficient, say so explicitly. "
    "Do not invent facts not present in the context."
)


def embed(text: str) -> list[float]:
    return ollama_client.embeddings(model=EMBED_MODEL, prompt=text).embedding


def retrieve(query: str, n: int = 10) -> list[dict]:
    q_vec = embed(query)
    results = collection.query(
        query_embeddings=[q_vec],
        n_results=n,
        include=["documents", "metadatas", "distances"],
    )
    return [
        {"text": doc, "source": meta.get("source", "unknown"), "score": 1 - dist}
        for doc, meta, dist in zip(
            results["documents"][0],
            results["metadatas"][0],
            results["distances"][0],
        )
    ]


def rag_answer(query: str) -> dict:
    # Retrieve
    candidates = retrieve(query, n=10)

    # Rerank (optional — skip if sentence-transformers not installed)
    try:
        ranked = rerank(query, candidates, top_n=5)
    except Exception:
        ranked = candidates[:5]

    # Assemble context with token budget
    ranked = sandwich_order(ranked)
    context, sources = assemble_context(ranked, max_context_tokens=2000)

    if not context:
        return {"answer": "No relevant context found.", "sources": []}

    # Generate
    resp = ollama_client.chat(
        model=GEN_MODEL,
        messages=[
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"Context:\n\n{context}\n\nQuestion: {query}"},
        ],
        options={"temperature": 0.1},
    )

    return {
        "answer": resp.message.content,
        "sources": sources,
    }
```

---

## When RAG beats fine-tuning

Both RAG and fine-tuning can improve LLM answers on domain-specific data. They solve different problems:

| Dimension | RAG | Fine-tuning |
|-----------|-----|-------------|
| Knowledge updates | Add to vector store — instant | Retrain — hours to days |
| Factual accuracy | High — cites actual documents | Lower — model memorization drifts |
| Reasoning style | Unchanged (base model) | Can be changed (tone, format, persona) |
| Cost | Per-query retrieval | Upfront training cost |
| Hallucination | Reduced — answer grounded in context | Potentially increased for rare facts |
| When it wins | Frequently-updated corpus, need citations, compliance | Fixed corpus, specialized output format, low-latency (no retrieval hop) |

**Decision heuristic:**
- Documents change more than once a month → **RAG**
- You need to cite sources for compliance → **RAG**
- You need a very specific output style (structured JSON, a particular persona) → **fine-tuning**
- You need sub-100 ms latency and can pre-compute → **fine-tuning** or caching
- Both → **RAG + fine-tuned model** (the model learns to follow format; RAG provides the facts)

Fine-tuning on dynamic data is almost always a mistake — you'll re-train continuously and the model will still hallucinate on documents it wasn't trained on. RAG is the right default until proven otherwise.

---

## Debugging RAG

The diagnostic ladder: wrong answer → is it a retrieval problem or a generation problem? Bisect by injecting the correct answer directly into the context and re-running:

```python
# Bypass retrieval — inject the answer directly to isolate generation quality
resp = ollama_client.chat(
    model=GEN_MODEL,
    messages=[
        {"role": "system", "content": SYSTEM},
        {
            "role": "user",
            "content": (
                "Context:\n\n[Source: test]\nThe pod was evicted due to node memory pressure.\n\n"
                f"Question: {query}"
            ),
        },
    ],
    options={"temperature": 0.1},
)
print(resp.message.content)
```

If this gives the right answer, the generation model is fine — your retrieval is broken. If it still gives the wrong answer, the generation model is ignoring the context (lost-in-the-middle, instruction-following failure, or model too small).

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Retrieved chunks are topically unrelated | Chunk size too large (embedding diluted); wrong embedding model for domain | Reduce chunk size to 256–512 chars; evaluate with domain-specific embedding model |
| Correct fact is in the corpus but not retrieved | Vocabulary mismatch between query and document phrasing | Add BM25 hybrid retrieval; paraphrase the query with LLM before embedding |
| Correct chunk is retrieved but answer ignores it | Lost-in-the-middle: chunk is in the middle of a long context | Use sandwich ordering; reduce retrieved context to 3–5 chunks |
| LLM answers from its training data, ignores context | System prompt not strong enough; or model too small to follow grounding instructions | Add "Do not use knowledge outside the context" more forcefully; upgrade model size |
| Hallucination despite correct context in window | Model paraphrases incorrectly or adds stale details | Lower temperature (0.0–0.1); use structured output to force citation of exact quotes |
| Recall is good but precision is low (too many irrelevant chunks reaching LLM) | Top-k retrieval is set too large; no reranking | Reduce to n=20 with reranking to top-5; add metadata filters |
| RAG works on short documents, fails on long books | Chunk overlap insufficient; single-hop retrieval misses cross-section facts | Increase overlap to 20%; implement multi-hop retrieval (second query using first answer) |

### Evaluate retrieval quality

```python
def retrieval_precision_at_k(
    test_cases: list[dict],  # [{"query": str, "relevant_doc_ids": [str]}]
    retrieve_fn,
    k: int = 5,
) -> float:
    """Fraction of retrieved chunks that are relevant."""
    scores = []
    for case in test_cases:
        retrieved_ids = [c["source"] for c in retrieve_fn(case["query"])[:k]]
        relevant = set(case["relevant_doc_ids"])
        hits = sum(1 for r in retrieved_ids if r in relevant)
        scores.append(hits / k)
    return sum(scores) / len(scores)
```

Build a test set of 30–50 (query, relevant_doc_id) pairs by hand from your real corpus. Run it before and after every change to retrieval parameters — chunk size, overlap, n_results, reranking. Without this, you are flying blind.

### Diagnose lost-in-the-middle

```python
# Test: does answer quality degrade when relevant chunk is at position 5 vs position 1?
def position_sensitivity_test(query: str, relevant_chunk: str, filler_chunk: str) -> None:
    def answer_with_order(chunks: list[str]) -> str:
        context = "\n\n---\n\n".join(f"[Source: doc{i}]\n{c}" for i, c in enumerate(chunks))
        return ollama_client.chat(
            model=GEN_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": f"Context:\n\n{context}\n\nQuestion: {query}"},
            ],
            options={"temperature": 0.0, "seed": 42},
        ).message.content

    answer_first = answer_with_order([relevant_chunk] + [filler_chunk] * 4)
    answer_middle = answer_with_order([filler_chunk] * 2 + [relevant_chunk] + [filler_chunk] * 2)
    answer_last = answer_with_order([filler_chunk] * 4 + [relevant_chunk])

    print("First: ", answer_first[:150])
    print("Middle:", answer_middle[:150])
    print("Last:  ", answer_last[:150])
```

> **War story.** At SAP I built a RAG system over an internal runbook corpus — about 800 documents, chunk size 512 chars. Retrieval recall was 0.91 on the test set. But users kept getting incomplete answers to questions that required synthesizing two or three sections of a long runbook. The benchmark missed it because we tested single-hop questions (one answer in one chunk). The root cause was retrieval ordering: we returned 8 chunks sorted by cosine score, descending, and injected them in that order. For synthesis questions, the most relevant chunks were chunks 1, 4, and 7 — one first, one buried in the middle, one last. The LLM summarized chunks 1 and 7 well (beginning and end of context) and essentially ignored chunk 4. Switching to sandwich ordering — highest-score first, second-highest last, everything else in the middle — raised the synthesis question score from 0.62 to 0.81 on a hand-labelled 40-question eval set. Two lines of code. The harder lesson: always include multi-hop synthesis questions in your eval set from the start.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Draw the RAG loop from memory — every stage, the artifact passed between stages, and the model used at each stage.
2. Explain what chunk overlap does and derive the overlap size for a 512-char chunk with a 10% overlap budget.
3. State why a cross-encoder is more accurate than a bi-encoder for reranking, and why you cannot use it for retrieval over a 1M-doc corpus.
4. Describe the "lost-in-the-middle" failure, the position in the context where it manifests, and the mitigation.
5. Write a `sandwich_order` function from scratch.
6. Given a wrong RAG answer, describe the exact two-step diagnostic to determine whether retrieval or generation is at fault.
7. State the decision criterion for choosing RAG over fine-tuning — what single property of the knowledge source drives the decision?
8. Write the Precision@K evaluation function and explain why it matters to test with real user queries, not synthetic ones.

➡ Next: **Tool-Using Agents** — give the model access to functions it can call, build a loop that reasons and acts, and handle the failure modes that emerge when models plan across multiple steps.
