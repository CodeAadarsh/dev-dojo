# RAG Citation

Your team is building an internal Q&A assistant over the SRE wiki. The first user complaint is already in: *"the bot answers about incident response but never cites where in the wiki it found the information — so nobody trusts it."* Correct citation requires correct **retrieval**: the right chunk, not a random one from a vaguely related section.

This challenge makes that concrete. There is a knowledge base (`knowledge_base.txt`) in your work directory. Embedded inside exactly one chunk of that file is a flag of the form `FLAG=KUBE{...}`. Retrieve the correct chunk for the question below and read the flag out of it.

## The question

```
What are the five sections of an effective blameless post-incident review?
```

## Mission

Implement a pipeline in `solution.py` that:

1. **Chunks** `knowledge_base.txt` into overlapping or non-overlapping text segments (paragraph-level chunking works; so does fixed-size with overlap).
2. **Scores** each chunk against the question using any similarity measure — TF-IDF, keyword overlap, cosine similarity over simple bag-of-words vectors, or real embeddings via Ollama if you want.
3. **Returns** the top-1 chunk as a string.

When your retrieval is correct, the top-1 chunk will contain the flag. Print or inspect it to extract `FLAG=KUBE{...}`.

The function signature the starter code provides:

```python
def retrieve(question: str, chunks: list[str]) -> str:
    """Return the single most relevant chunk for the given question."""
    ...
```

## What counts as correct

The correct chunk is the **only** one that substantively discusses blameless postmortems and their five-section structure. Any retrieval approach that scores semantic or lexical similarity correctly will find it — the signal is strong. You do not need an LLM or a GPU; a simple TF-IDF or even keyword intersection scorer is sufficient.

## Hints for extraction

Once you have the top-1 chunk, look for `FLAG=` in the text:

```python
import re
match = re.search(r'FLAG=(KUBE\{[^}]+\})', top_chunk)
if match:
    print(match.group(1))
```

Submit the flag string (e.g. `KUBE{...}`) in the platform.

## Why this matters

RAG without correct citation is guessing with extra steps. Every production RAG system needs a retrieval layer you can audit: given question X, which chunk was used? When the answer is wrong, the first debugging step is always "did we retrieve the right chunk?" This challenge builds that muscle. The difference between a useful assistant and a hallucination machine is often just the quality of this one function.
